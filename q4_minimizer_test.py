#!/usr/bin/env python3
# Q4: minimizer-anchor match-finding vs full-hash. Второй инженер: minimizers
# для генома дёшевле и параллельнее. Проверяем на РЕАЛЬНОМ fastq.
# Minimizer = минимальный k-mer в скользящем окне w. Только на этих якорях строим
# индекс (в разы меньше позиций) -> дешевле, но покрытие?
import numpy as np, time, sys
path=sys.argv[1] if len(sys.argv)>1 else '/workspace/data/NA12878_1gb.fastq'
nb=int(sys.argv[2]) if len(sys.argv)>2 else 2000000
data=open(path,'rb').read(nb); n=len(data)
arr=np.frombuffer(data,dtype=np.uint8).copy()

def h(x): return (x*0x9E3779B97F4A7C15) & 0xFFFFFFFFFFFFFFFF

# k-mer хэши (k=15 стандарт для генома)
K=15
kmers=np.zeros(n,dtype=np.uint64)
for j in range(min(K,8)):  # 8 байт в uint64
    v=np.arange(n)+j<n; sh=np.zeros(n,dtype=np.uint64)
    sh[v]=arr[np.arange(n)[v]+j].astype(np.uint64); kmers=(kmers<<8)|sh

# --- ПОЛНЫЙ hash: индексируем ВСЕ позиции ---
t0=time.time()
from collections import defaultdict
full_idx=defaultdict(list)
# прокси: группируем по kmer, ищем предыдущую позицию с тем же kmer
def factorize_hash(index_positions, W=64):
    # index_positions = set позиций, которые в индексе (для minimizer — только якоря)
    tab=defaultdict(list); matches=0;covered=0;i=0
    in_idx=np.zeros(n,dtype=bool); in_idx[index_positions]=True
    while i<n:
        key=int(kmers[i]); bl=0;bs=-1
        for src in tab.get(key,[])[-W:]:
            if src>=i: continue
            l=0;lim=min(n-i,512)
            while l<lim and arr[i+l]==arr[src+l]: l+=1
            if l>bl: bl=l;bs=src
        # регистрируем текущую позицию если она в индексе
        if in_idx[i]: tab[key].append(i)
        if bl>=4 and bs>=0: matches+=1;covered+=bl;i+=bl
        else: i+=1
    return matches,covered,len(tab)

allpos=np.arange(n)
m1,c1,keys1=factorize_hash(allpos,64); t_full=time.time()-t0
print(f"ПОЛНЫЙ hash (все {n} позиций): matches={m1} покрытие={100*c1/n:.1f}% время={t_full:.1f}s")

# --- MINIMIZER: только якоря (мин k-mer в окне w) ---
for w in [5, 10, 20]:
    t0=time.time()
    # minimizer: позиция i — якорь, если kmers[i] минимален в окне [i-w, i]
    anchors=[]
    for i in range(0,n,1):
        lo=max(0,i-w); 
        if kmers[i]==kmers[lo:i+1].min(): anchors.append(i)
    anchors=np.array(anchors)
    m2,c2,keys2=factorize_hash(anchors,64); t_min=time.time()-t0
    print(f"MINIMIZER w={w}: якорей={len(anchors)} ({100*len(anchors)/n:.0f}% позиций) "
          f"matches={m2} покрытие={100*c2/n:.1f}% (vs full {100*c2/c1:.0f}%) время={t_min:.1f}s")

print("\nВЫВОД Q4: minimizer индексирует меньше позиций (дешевле индекс/память),")
print("но покрытие ниже. Trade-off: сколько memory экономим vs сколько ratio теряем.")
print("Если покрытие minimizer ~= full при малой доле якорей -> Q4 подтверждён для генома.")
