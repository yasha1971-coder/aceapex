#!/usr/bin/env python3
"""TRAIN-2 eval-window precompute (local, no GPU). For each seed's 50 held-out assemblies,
build W-window lists in ASSEMBLY coordinates for:
  (b) HLA(chr6 MHC)+KIR(chr19)+SegDup: assembly intervals whose CHM13 orthologue (via the
      assembly-vs-CHM13 release-2 PAF) falls in those loci;
  (c) SV-insertion: assembly intervals with NO CHM13 alignment (inserted vs CHM13).
Windows are fetched on the VM via panvram.Cohort.fetch(manifest, contig, qstart, W, tokens=True).
Set (a) random is built on the VM from the held-out cohort (train_small eval). Writes
train2_eval_windows.json: {seed: {b:[[manifest,contig,qstart],...], c:[...]}}.
"""
import argparse, gzip, json, os, random, sys
from collections import defaultdict
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import duel1_lib as L

# CHM13v2.0 loci (documented in RESULT). MHC/HLA on chr6, KIR/LRC on chr19.
LOCI = [("chr6", 28_000_000, 34_000_000, "MHC_HLA"),
        ("chr19", 54_000_000, 56_000_000, "KIR_LRC")]

def merge(iv):
    if not iv: return []
    iv = sorted(iv); out=[list(iv[0])]
    for s,e in iv[1:]:
        if s<=out[-1][1]: out[-1][1]=max(out[-1][1],e)
        else: out.append([s,e])
    return [(s,e) for s,e in out]
def subtract(a,b):
    out=[]; j=0
    for s,e in a:
        cur=s;k=j
        while k<len(b) and b[k][1]<=cur: k+=1
        while k<len(b) and b[k][0]<e:
            if b[k][0]>cur: out.append((cur,min(b[k][0],e)))
            cur=max(cur,b[k][1]); k+=1
        if cur<e: out.append((cur,e))
    return out

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("--holdouts",required=True); ap.add_argument("--paf",required=True)
    ap.add_argument("--cohort",required=True); ap.add_argument("--reference",required=True)
    ap.add_argument("--segdup",required=True)
    ap.add_argument("--W",type=int,default=2048); ap.add_argument("--nwin",type=int,default=1024)
    ap.add_argument("--out",required=True)
    a=ap.parse_args()
    import panvram
    H=json.load(open(a.holdouts)); U=H['union']
    # panvram: manifest -> contig lengths + PanSN prefix
    c=panvram.Cohort.open(a.cohort,device="cpu",dataset="q4k",reference=a.reference,assemblies=U)
    man_clen={}; contig2man={}; prefset=set()
    for man in U:
        clen={}
        for row in c.contigs(man):
            cn=str(row[0]); clen[cn]=row[2]
            contig2man[cn]=man          # full contig name -> manifest (r2 and y1 differ at contig level)
            p=cn.split("#"); prefset.add(f"{p[0]}#{p[1]}#")
        man_clen[man]=clen
    print(f"{len(U)} assemblies; {len(contig2man)} contigs mapped",flush=True)
    # segdup merged per chrom
    sd=defaultdict(list)
    with open(a.segdup) as fh:
        for ln in fh:
            f=ln.split("\t")
            if len(f)<3: continue
            try: sd[f[0]].append((int(f[1]),int(f[2])))
            except ValueError: continue
    sd={k:merge(v) for k,v in sd.items()}
    loci_by_chrom=defaultdict(list)
    for chrom,s,e,_ in LOCI: loci_by_chrom[chrom].append((s,e))
    for chrom in list(loci_by_chrom): loci_by_chrom[chrom]=merge(loci_by_chrom[chrom])

    # stream PAF filtered to union prefixes; collect per (manifest,contig): blocks + qcov
    prefixes=tuple(p.encode() for p in prefset)
    blocks=defaultdict(list)   # (man,contig) -> [(ts,te,strand,qs,qe,tchrom)]
    qcov=defaultdict(list)     # (man,contig) -> [(qs,qe)]
    n=0
    with gzip.open(a.paf,"rb") as fh:
        for raw in fh:
            n+=1
            if n%5_000_000==0: print(f"  {n/1e6:.0f}M PAF lines",flush=True)
            if not raw.startswith(prefixes): continue
            f=raw.rstrip(b"\n").split(b"\t")
            if len(f)<12: continue
            q=f[0].decode()
            man=contig2man.get(q)      # resolve by FULL contig name (no r2/y1 prefix collision)
            if man is None: continue
            qs=int(f[2]); qe=int(f[3]); strand=f[4].decode()
            tchrom=f[5].decode().split("#")[-1]; ts=int(f[7]); te=int(f[8])
            key=(man,q)
            blocks[key].append((ts,te,strand,qs,qe,tchrom))
            qcov[key].append((qs,qe))
    print(f"PAF streamed ({n} lines); {len(blocks)} query contigs",flush=True)

    rng=random.Random(20261115)
    def b_windows_for(man):
        out=[]
        for (m,contig),bl in blocks.items():
            if m!=man: continue
            for (ts,te,strand,qs,qe,tchrom) in bl:
                tl=te-ts; ql=qe-qs
                if tl<=0 or ql<=0: continue
                targets=[]
                for (ls,le) in loci_by_chrom.get(tchrom,[]):
                    s=max(ts,ls); e=min(te,le)
                    if s<e: targets.append((s,e))
                for (ls,le) in sd.get(tchrom,[]):
                    s=max(ts,ls); e=min(te,le)
                    if s<e: targets.append((s,e))
                if not targets: continue
                for (os_,oe) in merge(targets):
                    # proportional target->query mapping within the block (strand-aware)
                    f0=(os_-ts)/tl; f1=(oe-ts)/tl
                    if strand=='+': qa=qs+f0*ql; qb=qs+f1*ql
                    else: qa=qs+(1-f1)*ql; qb=qs+(1-f0)*ql
                    qa=int(qa); qb=int(qb)
                    if qb-qa>=a.W: out.append((contig,qa,qb))
        return out
    def c_windows_for(man):
        out=[]
        clen=man_clen[man]
        # covered per contig
        cov=defaultdict(list)
        for (m,contig),ivs in qcov.items():
            if m==man: cov[contig]=merge(ivs)
        for contig,Lc in clen.items():
            un=subtract([(0,Lc)],cov.get(contig,[]))
            for (s,e) in un:
                if e-s>=a.W: out.append((contig,s,e))
        return out

    result={}
    for lbl, holds in H['holdout'].items():
        bcand=[]; ccand=[]
        for man in holds:
            if man not in man_clen: continue
            for (contig,qa,qb) in b_windows_for(man):
                bcand.append((man,contig,qa,qb))
            for (contig,s,e) in c_windows_for(man):
                ccand.append((man,contig,s,e))
        def sample(cands):
            # weight by available length, draw nwin window starts
            if not cands: return []
            w=[max(1,(qb-qa)-a.W+1) for (_,_,qa,qb) in cands]
            tot=sum(w); picks=[]
            for _ in range(a.nwin):
                r=rng.random()*tot; acc=0; idx=0
                for i,wi in enumerate(w):
                    acc+=wi
                    if r<=acc: idx=i; break
                man,contig,qa,qb=cands[idx]
                st=rng.randint(qa,qb-a.W)
                picks.append([man,contig,st])
            return picks
        result[lbl]={"b":sample(bcand),"c":sample(ccand),
                     "n_b_cand":len(bcand),"n_c_cand":len(ccand)}
        print(f"seed {lbl}: b_cand {len(bcand)} c_cand {len(ccand)} -> {len(result[lbl]['b'])}/{len(result[lbl]['c'])} windows",flush=True)
    json.dump(dict(W=a.W,nwin=a.nwin,loci=LOCI,segdup="chm13v2.0_SD.bed (T2T CHM13v2.0)",
                   paf="hprc465vschm13.aln.paf.gz (impg release-2)",seeds=H['seeds'],windows=result),
              open(a.out,"w"))
    print("wrote",a.out,flush=True)

if __name__=="__main__": main()
