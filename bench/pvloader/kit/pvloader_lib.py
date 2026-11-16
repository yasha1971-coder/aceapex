"""PV-LOADER shared helpers. panvram is FROZEN (01f0ce11) — never imported-and-modified,
only read. Token LUT identical to examples/train_small.py (A/a=0 C=1 G=2 T=3 else=4)."""
import numpy as np

# A C G T -> 0..3 ; anything else -> 4   (uppercase + lowercase)
LUT = np.full(256, 4, dtype=np.uint8)
for i, ch in enumerate(b"ACGT"):
    LUT[ch] = i
    LUT[ch + 32] = i

def tokenize(seq_bytes):
    return LUT[np.frombuffer(seq_bytes, dtype=np.uint8)]

# assembly file-stem (FASTA) -> panvram manifest. HG00097_hap1 -> r2_HG00097_hap1_hprc_r2_v1.0.1
def stem_to_manifest(stem):
    return f"r2_{stem}_hprc_r2_v1.0.1"

def build_window_list(contigs_by_asm, n, W, seed):
    """contigs_by_asm: {asm: [(contig, length), ...]}. Returns a deterministic list of
    (asm, contig, start) of length n, seed-fixed, identical for every loader."""
    import random
    rng = random.Random(seed)
    asms = sorted(contigs_by_asm)
    flat = []  # (asm, contig, length) for contigs >= W, weighted by length
    for a in asms:
        for cn, L in contigs_by_asm[a]:
            if L > W:
                flat.append((a, cn, L))
    wsum = sum(L - W for _, _, L in flat)
    out = []
    for _ in range(n):
        r = rng.random() * wsum; acc = 0; idx = 0
        for i, (_, _, L) in enumerate(flat):
            acc += L - W
            if r <= acc:
                idx = i; break
        a, cn, L = flat[idx]
        start = rng.randint(0, L - W)
        out.append((a, cn, start))
    return out
