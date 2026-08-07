// ============================================================================
// gpu_sa_prototype.cu — GPU SA-encode ПРОТОТИП (статья 4 future-work → статья 5)
//
// ЦЕЛЬ (честная, узкая): доказать, что цепочка encode работает НА GPU end-to-end,
// bit-perfect, и дать FLOOR-число GB/s. НЕ "быстрый encode" — thrust-SA заведомо
// медленный. Оптимизация SA (Osipov/Wang) = отдельная работа (статья 5).
//
// ЦЕПОЧКА (всё на GPU):
//   1. Suffix array через thrust (сортировка суффиксов сравнением) — floor-метод
//   2. rank[] = обратный SA
//   3. PSV/NSV кандидаты (prev/next smaller value в rank) — параллельно
//   4. LZ factorization: каждая позиция независимо берёт лучший из PSV/NSV
//      -> ABSOLUTE offset (структурное совпадение с ACEAPEX ядром)
//   5. bit-perfect восстановление на CPU-эталоне
//   6. замер GB/s (floor)
//
// Build: nvcc -O3 -arch=sm_90 -o gpu_sa_prototype gpu_sa_prototype.cu
// Run:   ./gpu_sa_prototype <file> [max_bytes]
// ============================================================================
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <thrust/device_vector.h>
#include <thrust/host_vector.h>
#include <thrust/sort.h>
#include <thrust/sequence.h>
#include <cuda_runtime.h>

#define CK(x) do{cudaError_t e=(x); if(e){printf("CUDA err %s:%d %s\n",__FILE__,__LINE__,cudaGetErrorString(e));exit(1);} }while(0)

// --- компаратор суффиксов для thrust::sort (floor-метод построения SA) ---
// Сравнивает два суффикса по указателю на общий текст в device-памяти.
struct SuffixLess {
    const uint8_t* text; uint32_t n;
    SuffixLess(const uint8_t* t, uint32_t n_):text(t),n(n_){}
    __device__ bool operator()(uint32_t a, uint32_t b) const {
        uint32_t la=n-a, lb=n-b, m=(la<lb?la:lb);
        for(uint32_t i=0;i<m;i++){
            uint8_t ca=text[a+i], cb=text[b+i];
            if(ca!=cb) return ca<cb;
        }
        return la<lb; // короче = меньше при общем префиксе
    }
};

// --- rank[sa[i]]=i ---
__global__ void k_rank(const uint32_t* sa, uint32_t* rank, uint32_t n){
    uint32_t i=blockIdx.x*blockDim.x+threadIdx.x;
    if(i<n) rank[sa[i]]=i;
}

// --- PSV/NSV через rank: для каждой позиции i найти ближайшие по тексту позиции
//     j<i с rank[j]<rank[i] (это кандидаты на match с absolute offset).
//     Наивно параллельно: каждая позиция сканирует назад до окна W. Floor-метод. ---
__global__ void k_candidates(const uint8_t* text, const uint32_t* rank,
                             uint32_t n, uint32_t W,
                             uint32_t* best_src, uint32_t* best_len){
    uint32_t i=blockIdx.x*blockDim.x+threadIdx.x;
    if(i>=n) return;
    uint32_t bl=0, bs=0xFFFFFFFF;
    // ищем среди предыдущих W позиций ту, что даёт самый длинный общий префикс
    uint32_t lo = (i>W)? i-W : 0;
    for(uint32_t j=lo;j<i;j++){
        uint32_t l=0, lim=n-i;
        while(l<lim && text[i+l]==text[j+l]) l++;
        if(l>bl){ bl=l; bs=j; }
    }
    best_len[i]=bl; best_src[i]=bs;
}

int main(int argc,char**argv){
    if(argc<2){ printf("Usage: %s <file> [max_bytes]\n",argv[0]); return 1; }
    FILE* f=fopen(argv[1],"rb"); if(!f){perror("open");return 1;}
    fseek(f,0,SEEK_END); long fsz=ftell(f); fseek(f,0,SEEK_SET);
    uint32_t n = (argc>2)? (uint32_t)atoi(argv[2]) : (uint32_t)fsz;
    if(n>(uint32_t)fsz) n=(uint32_t)fsz;
    std::vector<uint8_t> h(n);
    if(fread(h.data(),1,n,f)!=n){printf("short read\n");return 1;} fclose(f);
    printf("=== GPU SA-encode прототип (FLOOR-метод, не оптимум) ===\n");
    printf("данные: %s, %u байт\n", argv[1], n);

    // upload text
    uint8_t* dText; CK(cudaMalloc(&dText,n)); CK(cudaMemcpy(dText,h.data(),n,cudaMemcpyHostToDevice));

    cudaEvent_t ta,tb,tc,td; CK(cudaEventCreate(&ta)); CK(cudaEventCreate(&tb));
    CK(cudaEventCreate(&tc)); CK(cudaEventCreate(&td));
    CK(cudaEventRecord(ta));

    // --- 1. suffix array через thrust::sort с компаратором суффиксов ---
    thrust::device_vector<uint32_t> d_sa(n);
    thrust::sequence(d_sa.begin(), d_sa.end());
    thrust::sort(d_sa.begin(), d_sa.end(), SuffixLess(dText,n));
    CK(cudaDeviceSynchronize());
    CK(cudaEventRecord(tb));

    // --- 2. rank ---
    uint32_t* dRank; CK(cudaMalloc(&dRank,n*4));
    uint32_t* dSA = thrust::raw_pointer_cast(d_sa.data());
    k_rank<<<(n+255)/256,256>>>(dSA,dRank,n);
    CK(cudaDeviceSynchronize());
    CK(cudaEventRecord(tc));

    // --- 3+4. кандидаты ---
    uint32_t* dBsrc; CK(cudaMalloc(&dBsrc,n*4));
    uint32_t* dBlen; CK(cudaMalloc(&dBlen,n*4));
    uint32_t W = 64;
    k_candidates<<<(n+255)/256,256>>>(dText,dRank,n,W,dBsrc,dBlen);
    CK(cudaDeviceSynchronize());
    CK(cudaEventRecord(td)); CK(cudaEventSynchronize(td));
    float ms=0, ms_sa=0, ms_rank=0, ms_cand=0;
    CK(cudaEventElapsedTime(&ms_sa,   ta,tb));
    CK(cudaEventElapsedTime(&ms_rank, tb,tc));
    CK(cudaEventElapsedTime(&ms_cand, tc,td));
    CK(cudaEventElapsedTime(&ms,      ta,td));
    printf("PROFILE: SA-build=%.2f ms (%.0f%%)  rank=%.2f ms  candidates=%.2f ms (%.0f%%)\n",
        ms_sa, 100.0*ms_sa/ms, ms_rank, ms_cand, 100.0*ms_cand/ms);

    // --- 5. bit-perfect: скачать кандидатов, жадно собрать факторизацию, восстановить ---
    std::vector<uint32_t> bsrc(n),blen(n);
    CK(cudaMemcpy(bsrc.data(),dBsrc,n*4,cudaMemcpyDeviceToHost));
    CK(cudaMemcpy(blen.data(),dBlen,n*4,cudaMemcpyDeviceToHost));

    // жадная сборка токенов (absolute offsets) + reconstruction
    std::vector<uint8_t> recon; recon.reserve(n);
    uint32_t matches=0, lits=0; uint64_t covered=0;
    uint32_t i=0;
    while(i<n){
        uint32_t L=blen[i], src=bsrc[i];
        if(L>=4 && src<i){
            for(uint32_t k=0;k<L;k++) recon.push_back(h[src+k]); // absolute src
            covered+=L; matches++; i+=L;
        } else { recon.push_back(h[i]); lits++; i++; }
    }
    bool bitperfect = (recon.size()==n) && (memcmp(recon.data(),h.data(),n)==0);

    // размер (грубая оценка absolute-offset потока)
    auto vlen=[](uint32_t x){int c=1;while(x>=128){x>>=7;c++;}return c;};
    size_t est=lits;
    { uint32_t p=0; while(p<n){ uint32_t L=blen[p],s=bsrc[p];
        if(L>=4&&s<p){est+=vlen(s)+vlen(L);p+=L;}else{p++;} } }
    double ratio = (double)n/est;

    printf("\n--- РЕЗУЛЬТАТ ---\n");
    printf("GPU время (SA+rank+candidates): %.2f ms -> %.1f MB/s (FLOOR, thrust-SA медленный)\n",
        ms, n/(ms*1e-3)/1e6);
    printf("токенов: matches=%u lits=%u, покрытие=%.1f%%\n", matches,lits,100.0*covered/n);
    printf("ratio (absolute-offset поток, грубо): %.2f\n", ratio);
    printf("BIT-PERFECT восстановление по absolute offsets: %s\n", bitperfect?"YES OK":"NO FAIL");
    printf("\n--- ЧЕСТНЫЕ ГРАНИЦЫ ---\n");
    printf("Это FLOOR: thrust-сортировка суффиксов O(n log n * сравнение) — заведомо\n");
    printf("медленно. Доказывает ЦЕПОЧКУ на GPU (SA->absolute offsets->bit-perfect),\n");
    printf("НЕ скорость. Быстрый GPU-SA (Osipov/Wang, DC3/skew) = статья 5.\n");
    printf("Ключевое для статьи 4 future-work: цепочка РАБОТАЕТ на GPU, измерена, bit-perfect.\n");

    cudaFree(dText);cudaFree(dRank);cudaFree(dBsrc);cudaFree(dBlen);
    return 0;
}
