import numpy as np
from pydivsufsort import divsufsort
import time, sys
path = sys.argv[1] if len(sys.argv)>1 else '/workspace/data/enwik9'
nbytes = int(sys.argv[2]) if len(sys.argv)>2 else 2000000
data=open(path,'rb').read(nbytes)
n=len(data); arr=np.frombuffer(data,dtype=np.uint8).copy()

def factorize(order, rank, W=64):
    matches=0; covered=0; i=0
    while i<n:
        bl=0;bs=-1;ri=rank[i]
        for d in range(-W,W+1):
            rr=ri+d
            if rr<0 or rr>=n or d==0: continue
            src=int(order[rr])
            if src>=i: continue
            l=0;lim=min(n-i,512)
            while l<lim and arr[i+l]==arr[src+l]: l+=1
            if l>bl: bl=l;bs=src
        if bl>=4 and bs>=0: matches+=1;covered+=bl;i+=bl
        else: i+=1
    return matches, covered

# ПОЛНЫЙ SA (эталон)
t0=time.time(); sa=divsufsort(arr); rank=np.empty(n,dtype=np.int64); rank[sa]=np.arange(n)
tf=time.time()-t0
m1,c1=factorize(sa,rank,64)
print(f"ПОЛНЫЙ SA: build={tf*1000:.0f}ms matches={m1} покрытие={100*c1/n:.1f}%")

# ЧАСТИЧНЫЙ radix по k байт (наш подход к Q1) — с учётом каверзы k/алфавит
for k in [4,8,12]:
    t0=time.time()
    keys=np.zeros(n,dtype=np.uint64)
    for j in range(min(k,8)):
        sh=np.zeros(n,dtype=np.uint64); v=np.arange(n)+j<n
        sh[v]=arr[np.arange(n)[v]+j].astype(np.uint64); keys=(keys<<8)|sh
    order=np.argsort(keys,kind='stable').astype(np.int64)
    prank=np.empty(n,dtype=np.int64); prank[order]=np.arange(n)
    tp=time.time()-t0
    m2,c2=factorize(order,prank,64)
    print(f"ЧАСТИЧНЫЙ k={k}: build={tp*1000:.0f}ms matches={m2} покрытие={100*c2/n:.1f}% (vs full {100*c2/c1:.0f}%)")
print("ВЫВОД: наш radix-подход к Q1. Сравни покрытие частичного с полным SA.")
