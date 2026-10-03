#!/usr/bin/env python3
"""loader_reality.py - does the window source matter for a real training step? (research, Colab Blackwell)

1) a ~100M-parameter causal transformer, bf16 autocast, context 8192, one token per byte (A C G T N, line end, other):
   step time, tokens/s and peak VRAM at batch 8 and 32 (activation checkpointing per block if the plain step runs out
   of memory; the row says which);
2) the same step fed by three window sources, the share of the step spent getting the batch:
   (a) the raw FASTA bytes resident in VRAM, windows gathered on the device;
   (b) the ACEAPEX open archive resident in VRAM, windows decoded on the device (aceapex_gpu_decompress_windows_async,
       libaceapex_gpu.so through ctypes, the torch stream) + a lookup kernel ASCII -> token;
   (c) a CPU DataLoader over pyfaidx (bases without line ends), workers 2 / 4 / 8, pinned memory, copy to the card;
   (a) and (b) get the same offsets and their windows are compared byte for byte (FASTA bytes: line ends included);
3) capacity: how many HPRC assemblies fit on 80 GiB and 96 GiB after the model's peak VRAM - as raw FASTA bytes, as
   2 bits per base, and as ACEAPEX archives (sizes of the real .open.aet files found).

Usage: python3 loader_reality.py --lib libaceapex_gpu.so --archive t2t.open.aet --fasta t2t.fa [--hprc-dir DIR] --out FILE
"""
import argparse, ctypes, datetime, glob, os, time
import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
import torch.utils.checkpoint as ckpt

W = 8192
VOCAB = 8
GiB = 1 << 30


def lut():
    t = torch.full((256,), 6, dtype=torch.long)
    for i, s in enumerate(b"ACGTN"):
        t[s] = i; t[s | 0x20] = i
    t[ord("\n")] = 5
    return t


# ------------------------------------------------------------------ model
class Block(nn.Module):
    def __init__(self, d, h):
        super().__init__(); self.h = h
        self.ln1 = nn.LayerNorm(d); self.qkv = nn.Linear(d, 3 * d); self.proj = nn.Linear(d, d)
        self.ln2 = nn.LayerNorm(d); self.fc1 = nn.Linear(d, 4 * d); self.fc2 = nn.Linear(4 * d, d)

    def forward(self, x):
        B, T, D = x.shape
        q, k, v = self.qkv(self.ln1(x)).view(B, T, 3, self.h, D // self.h).permute(2, 0, 3, 1, 4)
        a = F.scaled_dot_product_attention(q, k, v, is_causal=True).transpose(1, 2).reshape(B, T, D)
        x = x + self.proj(a)
        return x + self.fc2(F.gelu(self.fc1(self.ln2(x))))


class LM(nn.Module):
    def __init__(self, d=768, layers=13, heads=12, ctx=W, checkpoint=False):
        super().__init__(); self.checkpoint = checkpoint
        self.emb = nn.Embedding(VOCAB, d); self.pos = nn.Parameter(torch.zeros(1, ctx, d))
        self.blocks = nn.ModuleList(Block(d, heads) for _ in range(layers))
        self.ln = nn.LayerNorm(d); self.head = nn.Linear(d, VOCAB)

    def forward(self, tok):
        x = self.emb(tok) + self.pos[:, :tok.shape[1]]
        for b in self.blocks:
            x = ckpt.checkpoint(b, x, use_reentrant=False) if self.checkpoint else b(x)
        return self.head(self.ln(x))


def make_step(model, opt):
    def step(tok):
        with torch.autocast("cuda", dtype=torch.bfloat16):
            logits = model(tok[:, :-1])
            loss = F.cross_entropy(logits.reshape(-1, VOCAB).float(), tok[:, 1:].reshape(-1))
        opt.zero_grad(set_to_none=True); loss.backward(); opt.step()
        return loss
    return step


def build(batch, dev):
    """model + optimizer + one trial step; checkpointing if the plain step does not fit"""
    for use_ck in (False, True):
        torch.cuda.empty_cache(); torch.cuda.reset_peak_memory_stats()
        model = LM(checkpoint=use_ck).to(dev)
        opt = torch.optim.AdamW(model.parameters(), lr=1e-4, fused=True)
        step = make_step(model, opt)
        try:
            step(torch.randint(0, 5, (batch, W), device=dev)); torch.cuda.synchronize()
            return model, opt, step, use_ck
        except torch.OutOfMemoryError:
            del model, opt, step; torch.cuda.empty_cache()
    return None, None, None, None


# ------------------------------------------------------------------ sources
class RawSource:
    """(a) FASTA bytes in VRAM; windows by a device gather"""
    def __init__(self, fasta_bytes, dev):
        self.d = torch.from_numpy(fasta_bytes).to(dev); self.ar = torch.arange(W, device=dev)

    def windows(self, offs):                     # offs: int64 [B] on the device
        return self.d[offs[:, None] + self.ar]   # uint8 [B, W]


class AceSource:
    """(b) ACEAPEX archive in VRAM; windows decoded on the device by the library"""
    def __init__(self, lib, archive_path, max_batch, dev):
        self.L = ctypes.CDLL(lib)
        self.L.aceapex_gpu_plan_create.restype = ctypes.c_void_p
        self.L.aceapex_gpu_plan_create.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint64]
        self.L.aceapex_gpu_last_error.restype = ctypes.c_int
        self.L.aceapex_gpu_output_bytes.restype = ctypes.c_size_t
        self.L.aceapex_gpu_output_bytes.argtypes = [ctypes.c_void_p]
        self.L.aceapex_gpu_windows_temp_bytes.restype = ctypes.c_size_t
        self.L.aceapex_gpu_windows_temp_bytes.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.c_uint32]
        self.L.aceapex_gpu_decompress_windows_async.restype = ctypes.c_int
        self.L.aceapex_gpu_decompress_windows_async.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint32,
                                                               ctypes.c_uint32, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]
        self.L.aceapex_gpu_plan_destroy.argtypes = [ctypes.c_void_p]
        a = np.fromfile(archive_path, dtype=np.uint8); self.archive_bytes = a.size
        t0 = time.perf_counter()
        self.plan = self.L.aceapex_gpu_plan_create(a.ctypes.data, a.size, 0)
        self.plan_s = time.perf_counter() - t0
        if not self.plan: raise SystemExit(f"plan_create failed: {self.L.aceapex_gpu_last_error()}")
        self.orig = self.L.aceapex_gpu_output_bytes(self.plan)
        self.d_in = torch.from_numpy(a).to(dev)
        self.temp = torch.empty(self.L.aceapex_gpu_windows_temp_bytes(self.plan, max_batch, W), dtype=torch.uint8, device=dev)
        self.status = torch.zeros(1, dtype=torch.int32, device=dev)
        self.out = torch.empty((max_batch, W), dtype=torch.uint8, device=dev)

    def windows(self, offs):
        n = offs.shape[0]; out = self.out[:n]
        rc = self.L.aceapex_gpu_decompress_windows_async(self.plan, self.d_in.data_ptr(), offs.data_ptr(), n, W, out.data_ptr(),
                                                         self.temp.data_ptr(), self.status.data_ptr(), torch.cuda.current_stream().cuda_stream)
        if rc: raise SystemExit(f"windows call returned {rc}")
        return out

    def check_status(self):
        s = int(self.status.item())
        if s: raise SystemExit(f"device status {s}")


class FaidxWindows(torch.utils.data.Dataset):
    """(c) pyfaidx, random window of W bases (no line ends) from a contig chosen by length"""
    def __init__(self, fasta, n, seed):
        self.path, self.n, self.seed, self.fa = fasta, n, seed, None
        import pyfaidx
        f = pyfaidx.Fasta(fasta); self.names = [k for k in f.keys() if len(f[k]) > W]
        self.lens = np.array([len(f[k]) for k in self.names], dtype=np.int64); self.p = self.lens / self.lens.sum(); f.close()
        self.lut = lut().numpy().astype(np.int64)

    def __len__(self): return self.n

    def __getitem__(self, i):
        if self.fa is None:
            import pyfaidx; self.fa = pyfaidx.Fasta(self.path, sequence_always_upper=False, as_raw=True)
        r = np.random.default_rng(self.seed * 1_000_003 + i); k = r.choice(len(self.names), p=self.p)
        s = int(r.integers(0, self.lens[k] - W)); b = self.fa[self.names[k]][s:s + W].encode()
        return torch.from_numpy(self.lut[np.frombuffer(b, dtype=np.uint8)])


# ------------------------------------------------------------------ timing
def run_device_source(step, src, tok_lut, orig, batch, steps, seed, dev):
    g = torch.Generator(device=dev); g.manual_seed(seed)
    ev = [torch.cuda.Event(enable_timing=True) for _ in range(3)]; t_src = t_all = 0.0
    for i in range(steps + 3):
        offs = torch.randint(0, orig - W, (batch,), generator=g, device=dev, dtype=torch.int64)
        ev[0].record(); tok = tok_lut[src.windows(offs).long()]; ev[1].record(); step(tok); ev[2].record()
        torch.cuda.synchronize()
        if i >= 3: t_src += ev[0].elapsed_time(ev[1]); t_all += ev[0].elapsed_time(ev[2])
    return t_all / steps, t_src / steps


def run_loader(step, fasta, batch, workers, steps, seed, dev):
    ds = FaidxWindows(fasta, batch * (steps + 3), seed)
    dl = torch.utils.data.DataLoader(ds, batch_size=batch, num_workers=workers, pin_memory=True, persistent_workers=False, prefetch_factor=4)
    it = iter(dl); t_wait = t_all = 0.0
    for i in range(steps + 3):
        t0 = time.perf_counter(); tok = next(it).to(dev, non_blocking=True); torch.cuda.synchronize(); t1 = time.perf_counter()
        step(tok); torch.cuda.synchronize(); t2 = time.perf_counter()
        if i >= 3: t_wait += t1 - t0; t_all += t2 - t0
    del it, dl
    return t_all / steps * 1e3, t_wait / steps * 1e3


def aet_orig(path):
    with open(path, "rb") as f: h = f.read(20)
    return int.from_bytes(h[12:20], "little")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lib", required=True); ap.add_argument("--archive", required=True); ap.add_argument("--fasta", required=True)
    ap.add_argument("--hprc-dir", default=""); ap.add_argument("--out", required=True); ap.add_argument("--steps", type=int, default=10)
    a = ap.parse_args()
    dev = torch.device("cuda"); torch.backends.cuda.matmul.allow_tf32 = True
    lines = []
    def out(s=""): print(s, flush=True); lines.append(s)
    p = torch.cuda.get_device_properties(0)
    out(f"# loader_reality {datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')} | {p.name} | {p.total_memory / GiB:.1f} GiB | torch {torch.__version__} | CUDA {torch.version.cuda}")
    out(f"# archive {os.path.basename(a.archive)} {os.path.getsize(a.archive)} B, FASTA {os.path.basename(a.fasta)} {os.path.getsize(a.fasta)} B; window {W} tokens (1 token = 1 byte); {a.steps} timed steps after 3 warm-up")
    tok_lut = lut().to(dev)
    fasta_np = np.fromfile(a.fasta, dtype=np.uint8)

    # 1) model alone
    out("\n## 1. model: ~100M causal transformer, bf16 autocast, AdamW (fused), context 8192")
    out("| batch | params, M | checkpointing | step, ms | tokens/s | peak VRAM, GiB |"); out("|---|---|---|---|---|---|")
    peaks = {}
    for B in (8, 32):
        model, opt, step, ck = build(B, dev)
        if model is None: out(f"| {B} | - | - | OOM | - | - |"); continue
        nparam = sum(x.numel() for x in model.parameters()) / 1e6
        torch.cuda.reset_peak_memory_stats(); x = torch.randint(0, 5, (B, W), device=dev)
        for _ in range(3): step(x)
        torch.cuda.synchronize(); t0 = time.perf_counter()
        for _ in range(a.steps): step(x)
        torch.cuda.synchronize(); ms = (time.perf_counter() - t0) / a.steps * 1e3
        peaks[B] = torch.cuda.max_memory_allocated() / GiB
        out(f"| {B} | {nparam:.1f} | {'yes' if ck else 'no'} | {ms:.1f} | {B * W / ms * 1e3:,.0f} | {peaks[B]:.2f} |")
        del model, opt, step; torch.cuda.empty_cache()

    # 2) sources
    out("\n## 2. window sources in the training step (share = getting the batch / whole step)")
    raw = RawSource(fasta_np, dev); ace = AceSource(a.lib, a.archive, 32, dev)
    if ace.orig != fasta_np.size: raise SystemExit(f"archive original {ace.orig} B != FASTA {fasta_np.size} B")
    out(f"(a) raw bytes resident: {fasta_np.size / GiB:.2f} GiB; (b) archive resident: {ace.archive_bytes / GiB:.2f} GiB + temp {ace.temp.numel() / GiB:.2f} GiB (batch 32), host plan {ace.plan_s:.2f} s")
    g = torch.Generator(device=dev); g.manual_seed(20261003); same = 0; total = 0
    for _ in range(20):
        offs = torch.randint(0, ace.orig - W, (32,), generator=g, device=dev, dtype=torch.int64)
        same += int(torch.equal(raw.windows(offs), ace.windows(offs))); total += 1
    torch.cuda.synchronize(); ace.check_status()
    out(f"(a) == (b) byte for byte: {same} of {total} batches of 32 windows")
    out("| batch | source | step, ms | batch source, ms | share | tokens/s |"); out("|---|---|---|---|---|---|")
    for B in (8, 32):
        model, opt, step, ck = build(B, dev)
        if model is None: out(f"| {B} | all | OOM | - | - | - |"); continue
        for name, src in (("(a) raw in VRAM", raw), ("(b) aceapex in VRAM", ace)):
            tall, tsrc = run_device_source(step, src, tok_lut, ace.orig, B, a.steps, 7 + B, dev)
            out(f"| {B} | {name} | {tall:.1f} | {tsrc:.3f} | {tsrc / tall * 100:.2f} % | {B * W / tall * 1e3:,.0f} |")
        ace.check_status()
        for wk in (2, 4, 8):
            try:
                tall, twait = run_loader(step, a.fasta, B, wk, a.steps, 11 + B + wk, dev)
                out(f"| {B} | (c) pyfaidx DataLoader, {wk} workers | {tall:.1f} | {twait:.3f} | {twait / tall * 100:.2f} % | {B * W / tall * 1e3:,.0f} |")
            except Exception as e:
                out(f"| {B} | (c) pyfaidx DataLoader, {wk} workers | failed: {type(e).__name__}: {str(e)[:80]} | - | - | - |")
        del model, opt, step; torch.cuda.empty_cache()
    out("checkpointing in section 2 as in section 1 for the same batch; (c) windows are bases without line ends, (a)/(b) FASTA bytes")

    # 3) capacity
    out("\n## 3. capacity: HPRC assemblies that fit beside the model")
    aets = sorted(glob.glob(os.path.join(a.hprc_dir, "*.open.aet"))) if a.hprc_dir else []
    if not aets: out("no HPRC .open.aet found - capacity from the T2T archive instead"); aets = [a.archive]
    orig = np.array([aet_orig(x) for x in aets], dtype=np.float64); comp = np.array([os.path.getsize(x) for x in aets], dtype=np.float64)
    out(f"archives used: {len(aets)} ({', '.join(os.path.basename(x) for x in aets[:10])}{' ...' if len(aets) > 10 else ''})")
    out(f"per assembly, mean: FASTA {orig.mean() / 1e9:.3f} GB, 2 bits per byte of FASTA {orig.mean() / 4 / 1e9:.3f} GB (upper bound: line ends counted), ACEAPEX {comp.mean() / 1e9:.3f} GB (x{orig.mean() / comp.mean():.2f})")
    temp32 = ace.temp.numel() / GiB
    out("| card | batch | model peak, GiB | free for genomes, GiB | raw FASTA | 2-bit | ACEAPEX (+ window temp) |"); out("|---|---|---|---|---|---|---|")
    for cap in (80, 96):
        for B, pk in sorted(peaks.items()):
            free = cap - pk
            n_raw = int(free * GiB // orig.mean()); n_2b = int(free * GiB // (orig.mean() / 4)); n_ace = int((free - temp32) * GiB // comp.mean())
            out(f"| {cap} GiB | {B} | {pk:.2f} | {free:.2f} | {n_raw} | {n_2b} | {n_ace} |")
    out("arithmetic on measured sizes and the measured model peak; nothing else on the card (no fragmentation reserve)")
    with open(a.out, "w") as f: f.write("\n".join(lines) + "\n")
    print(f"written {a.out}")


if __name__ == "__main__":
    main()
