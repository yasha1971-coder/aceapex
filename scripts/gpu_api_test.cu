// gpu_api_test.cu - the C ABI of src/aceapex_gpu.h on a real GPU (Colab: scripts/colab_gpu_open.sh).
//   full     aceapex_gpu_decompress_async: output == original byte for byte, status 0; median time (events)
//   range    random windows (1 B .. 1 MiB) through aceapex_gpu_decompress_range_async, each == the original
//            slice (the file the CPU compressed); median time of the 16 KiB windows
//   verify   the same full decode with ACEAPEX_GPU_VERIFY_XXH3 (XXH3 of the output on the device against the
//            header): status 0 on the good archive, and the time it adds
//   corrupt  single-byte flips of the device copy of the archive, whole decode each, without and with the
//            hash check: counted as caught (status != 0), silent (status 0, output differs) or harmless (output
//            identical); a CUDA error (e.g. an illegal address) fails the test
// Build: nvcc -O3 -arch=sm_XX -Isrc -DACEAPEX_GPU_NVCOMP -I<nvcomp>/include scripts/gpu_api_test.cu src/aceapex_gpu_lib.cu -l:libnvcomp.so.5
// Usage: gpu_api_test <archive.aet> <original> [repeats=7] [ranges=200] [flips=20]
// Last line: APIROW <tab> archive bytes api_ms full ranges_ok ranges range16k_ms caught silent harmless plan_ms
//            verify_ms verify_full caught_v silent_v harmless_v
#include "aceapex_gpu.h"
#include <cuda_runtime.h>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include <vector>
#include <algorithm>
#define CK(x) do{ cudaError_t e_=(x); if(e_!=cudaSuccess){ printf("CUDA %s @%d: %s\n",#x,__LINE__,cudaGetErrorString(e_)); exit(2);} }while(0)
static std::vector<uint8_t> slurp(const char* p){ FILE* f=fopen(p,"rb"); if(!f){ perror(p); exit(1);} fseek(f,0,SEEK_END); std::vector<uint8_t> v(ftell(f)); fseek(f,0,SEEK_SET);
    if(fread(v.data(),1,v.size(),f)!=v.size()) exit(1); fclose(f); return v; }
static float med(std::vector<float> v){ if(v.empty()) return -1; std::sort(v.begin(),v.end()); return v[v.size()/2]; }
int main(int argc, char** argv){
    if(argc<3){ fprintf(stderr,"usage: %s <archive.aet> <original> [repeats] [ranges] [flips]\n",argv[0]); return 1; }
    const int reps=argc>3?atoi(argv[3]):7, NR=argc>4?atoi(argv[4]):200, NF=argc>5?atoi(argv[5]):20;
    std::vector<uint8_t> a=slurp(argv[1]), orig=slurp(argv[2]);
    auto t0=std::chrono::steady_clock::now();
    aceapex_gpu_plan* plan=aceapex_gpu_plan_create(a.data(),a.size());
    const double plan_ms=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-t0).count();
    if(!plan){ printf("plan_create failed: %d\nAPIROW\t%s\t%zu\t-1\tNOPLAN\t0\t0\t-1\t0\t0\t0\t%.1f\n",aceapex_gpu_last_error(),argv[1],a.size(),plan_ms); return 3; }
    const size_t n=aceapex_gpu_output_bytes(plan); const uint64_t RMAX=std::min<uint64_t>(n,1u<<20);
    if(n!=orig.size()){ printf("output size %zu != original %zu\n",n,orig.size()); return 3; }
    const size_t tb=aceapex_gpu_range_temp_bytes(plan,RMAX);
    printf("[api] plan %.1f ms on the host; temp %.1f MB (full %.1f MB), output %.1f MB\n",plan_ms,tb/1e6,aceapex_gpu_temp_bytes(plan)/1e6,n/1e6);
    uint8_t *d_in,*d_out,*d_temp,*d_bad; int* d_st; cudaStream_t s; CK(cudaStreamCreate(&s));
    CK(cudaMalloc(&d_in,a.size()+1)); CK(cudaMalloc(&d_bad,a.size()+1)); CK(cudaMalloc(&d_out,n+1)); CK(cudaMalloc(&d_temp,tb)); CK(cudaMalloc(&d_st,4));
    CK(cudaMemcpy(d_in,a.data(),a.size(),cudaMemcpyHostToDevice));
    std::vector<uint8_t> out(n); int st=-1;
    // full
    int r=aceapex_gpu_decompress_async(plan,d_in,d_out,d_temp,d_st,0,s);
    CK(cudaStreamSynchronize(s)); CK(cudaGetLastError());
    CK(cudaMemcpy(&st,d_st,4,cudaMemcpyDeviceToHost)); CK(cudaMemcpy(out.data(),d_out,n,cudaMemcpyDeviceToHost));
    const bool full_ok = r==0 && st==0 && !memcmp(out.data(),orig.data(),n);
    printf("[api] full decode: return %d, status %d, output %s\n",r,st,full_ok?"MATCHES OK":"DIFFERS X");
    cudaEvent_t e0,e1; CK(cudaEventCreate(&e0)); CK(cudaEventCreate(&e1));
    std::vector<float> tf;
    for(int i=0;i<reps;i++){ CK(cudaEventRecord(e0,s)); aceapex_gpu_decompress_async(plan,d_in,d_out,d_temp,d_st,0,s); CK(cudaEventRecord(e1,s)); CK(cudaEventSynchronize(e1));
        float ms; CK(cudaEventElapsedTime(&ms,e0,e1)); tf.push_back(ms); }
    const float api_ms=med(tf);
    printf("[api] full decode on-device %.3f ms (median of %d) -> %.1f GB/s\n",api_ms,reps,n/api_ms/1e6);
    // the same with the XXH3 check of the output
    CK(cudaMemset(d_out,0,n)); r=aceapex_gpu_decompress_async(plan,d_in,d_out,d_temp,d_st,ACEAPEX_GPU_VERIFY_XXH3,s); CK(cudaStreamSynchronize(s)); CK(cudaGetLastError());
    CK(cudaMemcpy(&st,d_st,4,cudaMemcpyDeviceToHost)); CK(cudaMemcpy(out.data(),d_out,n,cudaMemcpyDeviceToHost));
    const bool vfull_ok = r==0 && st==0 && !memcmp(out.data(),orig.data(),n);
    std::vector<float> tv;
    for(int i=0;i<reps;i++){ CK(cudaEventRecord(e0,s)); aceapex_gpu_decompress_async(plan,d_in,d_out,d_temp,d_st,ACEAPEX_GPU_VERIFY_XXH3,s); CK(cudaEventRecord(e1,s)); CK(cudaEventSynchronize(e1));
        float ms; CK(cudaEventElapsedTime(&ms,e0,e1)); tv.push_back(ms); }
    const float ver_ms=med(tv);
    printf("[api] full decode + XXH3 check on-device %.3f ms (median of %d; check adds %.3f ms, %+.1f %%): return %d, status %d, output %s\n",
        ver_ms,reps,ver_ms-api_ms,100.0*(ver_ms/api_ms-1),r,st,vfull_ok?"MATCHES OK":"DIFFERS X");
    // ranges
    std::mt19937_64 rng(20261001); int rok=0; std::vector<float> t16;
    const uint64_t lens[6]={1,17,4096,16384,65536,1u<<20};
    std::vector<uint8_t> rb(RMAX);
    for(int i=0;i<NR;i++){ uint64_t len=std::min<uint64_t>(lens[i%6],n), off=rng()%(n-len+1);
        CK(cudaEventRecord(e0,s)); r=aceapex_gpu_decompress_range_async(plan,d_in,off,len,d_out,d_temp,d_st,s); CK(cudaEventRecord(e1,s)); CK(cudaEventSynchronize(e1));
        float ms; CK(cudaEventElapsedTime(&ms,e0,e1)); if(len==16384) t16.push_back(ms);
        CK(cudaMemcpy(&st,d_st,4,cudaMemcpyDeviceToHost)); CK(cudaMemcpy(rb.data(),d_out,len,cudaMemcpyDeviceToHost));
        if(r==0 && st==0 && !memcmp(rb.data(),orig.data()+off,len)) rok++; else if(rok>=0) printf("[api] range off=%llu len=%llu: return %d status %d DIFFERS X\n",(unsigned long long)off,(unsigned long long)len,r,st); }
    const float r16=med(t16);
    printf("[api] ranges: %d of %d windows == original%s; 16 KiB window %.3f ms (median of %zu)\n",rok,NR,rok==NR?" (MATCHES OK)":" DIFFERS X",r16,t16.size());
    // corruption
    int caught[2]={0,0}, silent[2]={0,0}, same[2]={0,0};
    for(int i=0;i<NF;i++){ CK(cudaMemcpy(d_bad,d_in,a.size(),cudaMemcpyDeviceToDevice));
        size_t at=a.size()/2+rng()%(a.size()-a.size()/2); uint8_t b=a[at]^(uint8_t)(1+rng()%255); CK(cudaMemcpy(d_bad+at,&b,1,cudaMemcpyHostToDevice));
        for(int v=0;v<2;v++){
            r=aceapex_gpu_decompress_async(plan,d_bad,d_out,d_temp,d_st,v?ACEAPEX_GPU_VERIFY_XXH3:0,s); CK(cudaStreamSynchronize(s)); CK(cudaGetLastError());
            CK(cudaMemcpy(&st,d_st,4,cudaMemcpyDeviceToHost)); CK(cudaMemcpy(out.data(),d_out,n,cudaMemcpyDeviceToHost));
            if(r||st) caught[v]++; else if(memcmp(out.data(),orig.data(),n)) silent[v]++; else same[v]++; } }
    printf("[api] %d byte flips in the stream half of the archive: without the hash check %d caught by status, %d decoded wrong with status 0, %d harmless; with ACEAPEX_GPU_VERIFY_XXH3 %d caught, %d silent, %d harmless; no CUDA error\n",
        NF,caught[0],silent[0],same[0],caught[1],silent[1],same[1]);
    printf("APIROW\t%s\t%zu\t%.3f\t%s\t%d\t%d\t%.3f\t%d\t%d\t%d\t%.1f\t%.3f\t%s\t%d\t%d\t%d\n",argv[1],a.size(),api_ms,full_ok?"bit-perfect":"MISMATCH",rok,NR,r16,caught[0],silent[0],same[0],plan_ms,
        ver_ms,vfull_ok?"bit-perfect":"MISMATCH",caught[1],silent[1],same[1]);
    aceapex_gpu_plan_destroy(plan);
    return (full_ok && vfull_ok && rok==NR && silent[1]==0) ? 0 : 5;
}
