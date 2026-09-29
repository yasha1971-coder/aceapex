// aceapex_gpu.cu - the whole GPU path on an .aet archive as the CPU encoder wrote it:
//   token streams: nvCOMP batched zstd frames and/or rANS chunks (ADR-018, k_rans: one warp
//   per chunk) -> literal chunks: nvCOMP batched zstd (modes 0, 1) and/or pieces of the open
//   profile (ADR-019, modes 2, 3: k_rans on raw/rANS pieces) -> DNA unpack kernels (mode 1:
//   k_unpack, k_exc; mode 2: k_open_cse, k_open_bases, k_open_exc) -> v7-RA match kernel
//   k_decode_g<G>. All frames and chunks land in the stream buffers. An archive of the open
//   profile (AX_PROFILE=open) is decoded without nvCOMP calls.
// G is chosen at run time by a short probe on this GPU (8/16/32) unless given.
// Two measurements: sequential (H2D, tok, lit, unpack, match, each median of N runs) and a
// pipeline where the H2D of batch k+1 overlaps the entropy decode of batch k.
// Output is hashed (FNV-1a) against the original file: bit-perfect or nothing. A rANS chunk
// that fails its checks (spec 3.1.1) sets a device flag and the run stops (exit 6).
// Build: nvcc -O3 -arch=sm_XX -I<nvcomp>/include -L<nvcomp>/lib64 -l:libnvcomp.so.5 -o aceapex_gpu aceapex_gpu.cu
// Usage: aceapex_gpu <archive.aet> <original> [G=auto|8|16|32] [repeats=7] [batches=4]
#include "src/ax_open_warp.h"   // + ax_rans_warp.h, ax_lit_open.h
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <vector>
#include <algorithm>
#include <cuda_runtime.h>
#include <nvcomp/zstd.h>

#define CK(x) do{cudaError_t ck_e_=(x); if(ck_e_!=cudaSuccess){fprintf(stderr,"CUDA %s @%d: %s\n",#x,__LINE__,cudaGetErrorString(ck_e_)); exit(2);} }while(0)
#define NV(x) do{nvcompStatus_t nv_s_=(x); if(nv_s_!=nvcompSuccess){fprintf(stderr,"nvcomp %s @%d: status %d\n",#x,__LINE__,(int)nv_s_); exit(3);} }while(0)

#pragma pack(push,1)
struct BlockOffsets { uint64_t lit_off, off_off, len_off, cmd_off, lit_sz, off_sz, len_sz, cmd_sz; };
#pragma pack(pop)

// ---------------------------------------------------------------- v7-RA match kernel
__device__ static inline uint32_t rd_varint(const uint8_t* buf, uint32_t& p, uint32_t limit){
    uint32_t val=0, shift=0;
    while(p<limit){ uint8_t b=buf[p++]; val|=(uint32_t)(b&0x7F)<<shift; if(!(b&0x80)) return val; shift+=7; }
    return val;
}
template<int G>
__global__ void k_decode_g(const uint8_t* __restrict__ LIT, const uint8_t* __restrict__ OFF,
                           const uint8_t* __restrict__ LEN, const uint8_t* __restrict__ CMD,
                           const BlockOffsets* __restrict__ boffs, uint64_t orig_size, uint32_t block_size,
                           uint8_t* __restrict__ out, uint32_t* __restrict__ blk_ctr, uint32_t blk_end)
{
    uint32_t lane=threadIdx.x&31, lg=lane&(G-1), leader=lane&~(uint32_t)(G-1);
    uint32_t gmask=((G==32)?0xffffffffu:((1u<<G)-1u)<<leader);
    for(;;){
        uint32_t b=0; if(lg==0) b=atomicAdd(blk_ctr,1u); b=__shfl_sync(gmask,b,leader); if(b>=blk_end) return;
        BlockOffsets bo=boffs[b];
        const uint8_t *lit=LIT+bo.lit_off, *off=OFF+bo.off_off, *len=LEN+bo.len_off, *cmd=CMD+bo.cmd_off;
        uint64_t base=(uint64_t)b*block_size, rem=orig_size-base;
        uint32_t dst_size=(uint32_t)(rem<(uint64_t)block_size?rem:(uint64_t)block_size); uint8_t* dst=out+base;
        uint32_t lp=0,op=0,np=0,cp=0,out_pos=0, rep[4]={1,2,4,8};
        uint32_t cmd_sz=(uint32_t)bo.cmd_sz, lit_sz=(uint32_t)bo.lit_sz, off_sz=(uint32_t)bo.off_sz, len_sz=(uint32_t)bo.len_sz;
        while(out_pos<dst_size){
            uint32_t type=2,l=0,aux=0;
            if(lg==0){ while(cp<cmd_sz){ uint8_t c=cmd[cp++];
                if(c==0xFF){ rep[0]=1;rep[1]=2;rep[2]=4;rep[3]=8; continue; }
                if(c<0x80){ l=(uint32_t)c+1; if(lp+l>lit_sz||out_pos+l>dst_size){type=2;break;} type=0; aux=lp; lp+=l; }
                else if((c&0xC0)==0x80){ uint32_t ri=(c>>4)&3, lv=c&0x0F; if(lv==0x0F) lv+=rd_varint(len,np,len_sz); l=lv+6;
                    uint32_t dist=rep[ri]; if(ri>0){ for(int i=(int)ri;i>0;i--) rep[i]=rep[i-1]; rep[0]=dist; }
                    if(!dist||dist>out_pos||out_pos+l>dst_size){type=2;break;} type=1; aux=dist; }
                else { uint32_t lv=(c==0xFE)?rd_varint(len,np,len_sz):(uint32_t)(c&0x3F); l=lv+6; uint32_t dist=rd_varint(off,op,off_sz);
                    rep[3]=rep[2];rep[2]=rep[1];rep[1]=rep[0];rep[0]=dist;
                    if(!dist||dist>out_pos||out_pos+l>dst_size){type=2;break;} type=1; aux=dist; }
                break; } }
            type=__shfl_sync(gmask,type,leader); l=__shfl_sync(gmask,l,leader); aux=__shfl_sync(gmask,aux,leader);
            if(type==2) break;
            if(type==0){ for(uint32_t i=lg;i<l;i+=G) dst[out_pos+i]=lit[aux+i]; }
            else { uint32_t src=out_pos-aux;
                if(aux>=l){ for(uint32_t i=lg;i<l;i+=G) dst[out_pos+i]=dst[src+i]; }
                else      { for(uint32_t i=lg;i<l;i+=G) dst[out_pos+i]=dst[src+(i%aux)]; } }
            __syncwarp(gmask); out_pos+=l;
        }
    }
}
typedef void (*kern_t)(const uint8_t*,const uint8_t*,const uint8_t*,const uint8_t*,const BlockOffsets*,uint64_t,uint32_t,uint8_t*,uint32_t*,uint32_t);

// ---------------------------------------------------------------- DNA unpack kernels
struct DnaDesc { const uint8_t *seq,*cse,*gap,*val; uint8_t* dst; uint32_t raw, nexc; };
__global__ void k_unpack(const DnaDesc* d){
    const DnaDesc c=d[blockIdx.x]; uint32_t i0=(blockIdx.y*blockDim.x+threadIdx.x)*4; if(i0>=c.raw) return;
    uint8_t v=c.seq[i0>>2], m=c.cse[i0>>3]; uint32_t n=c.raw-i0; if(n>4) n=4;
    #pragma unroll
    for(uint32_t k=0;k<4;k++){ if(k<n){ uint8_t b="ACGT"[(v>>(6-2*k))&3]; if(m&(0x80>>((i0+k)&7))) b|=0x20; c.dst[i0+k]=b; } }
}
__global__ void k_exc(const DnaDesc* d){
    const DnaDesc c=d[blockIdx.x]; if(!c.nexc) return; __shared__ uint32_t s[256]; uint32_t carry=0;
    for(uint32_t base=0; base<c.nexc; base+=256){
        uint32_t e=base+threadIdx.x; uint32_t g = e<c.nexc ? ((const uint32_t*)c.gap)[e] : 0; s[threadIdx.x]=g; __syncthreads();
        for(uint32_t o=1;o<256;o<<=1){ uint32_t t = threadIdx.x>=o ? s[threadIdx.x-o] : 0; __syncthreads(); s[threadIdx.x]+=t; __syncthreads(); }
        uint32_t pos=carry+s[threadIdx.x]; if(e<c.nexc && pos<c.raw) c.dst[pos] = c.val ? c.val[e] : 0;
        carry+=s[255]; __syncthreads(); }
}
// ---------------------------------------------------------------- rANS token chunks (ADR-018)
// One warp decodes one chunk: the steps of src/ax_rans_warp.h (judged on the CPU by
// scripts/rans_warp_emu.cpp) with the warp collectives between them. The chunk bytes are in
// the compressed buffer next to the zstd frames; the output goes into the stream buffer.
// err[0] counts bad chunks, err[1] holds the lowest bad chunk index. A piece of the open
// literal profile (spec 3.4) with mode 0 is a raw copy: the warp copies it.
struct RansDesc { uint64_t src; uint8_t* dst; uint32_t csz, n, mode; };
#define AXW_WARPS 4
__device__ static inline uint32_t w_scan(uint32_t v, uint32_t lane, uint32_t& total){
    uint32_t inc=v;
    #pragma unroll
    for(int o=1;o<32;o<<=1){ uint32_t t=__shfl_up_sync(0xffffffffu,inc,o); if(lane>=(uint32_t)o) inc+=t; }
    total=__shfl_sync(0xffffffffu,inc,31); return inc-v;
}
__global__ void __launch_bounds__(32*AXW_WARPS) k_rans(const uint8_t* __restrict__ C, const RansDesc* __restrict__ d, uint32_t nd, uint32_t* __restrict__ err){
    __shared__ AxwShared sh_all[AXW_WARPS];
    const uint32_t FULL=0xffffffffu, lane=threadIdx.x&31, lt=(1u<<lane)-1u, k=blockIdx.x*AXW_WARPS+(threadIdx.x>>5);
    if(k>=nd) return;                                   // whole warp: nd is uniform
    const RansDesc c=d[k]; const uint8_t* src=C+c.src; AxwShared& sh=sh_all[threadIdx.x>>5];
    if(c.mode==0){ for(uint32_t i=lane;i<c.n;i+=32) c.dst[i]=src[i]; return; }   // raw piece (sizes checked on the host)
    bool b=false, bad=c.csz<AXW_MIN; uint32_t cb=0;
    if(!bad){
        axw_stage(lane,src,c.csz,sh); __syncwarp();
        uint32_t K; const uint32_t r0=w_scan(axw_rank_count(lane,sh),lane,K);
        axw_rank_write(lane,sh,r0); __syncwarp();
        const uint32_t lim=axw_lim(c.csz); uint32_t jb=0;
        for(uint32_t r=0; jb<K && 32+32*r<lim; r++){
            const bool t=axw_term(lane,sh,r,lim); const uint32_t m=__ballot_sync(FULL,t);
            axw_leb(lane,sh,r,t,jb+__popc(m&lt),K,b); jb+=__popc(m); }
        b|= jb<K; __syncwarp();
        uint32_t tot; cb=w_scan(axw_sum(lane,sh),lane,tot); b|= tot!=AXR_M;
        bad=__any_sync(FULL,b);
    }
    if(!bad){
        axw_cum(lane,sh,cb); __syncwarp(); axw_fill(lane,sh); __syncwarp();
        uint32_t x,W; const uint8_t* words; b|=axw_init(lane,src,c.csz,sh.end,x,W,words); bad=__any_sync(FULL,b);
        if(!bad){
            uint32_t base=0; const uint32_t groups=(c.n+31)/32;
            for(uint32_t g=0; g<groups; g++){
                const bool need=axw_step(lane,sh,g,c.n,x,c.dst); const uint32_t m=__ballot_sync(FULL,need);
                axw_refill(lane,need,m,base,W,words,x,b); base+=__popc(m); }
            b|= base!=W || x!=AXR_L; bad=__any_sync(FULL,b);
        }
    }
    if(bad && lane==0){ atomicAdd(err,1u); atomicMin(err+1,k); }
}

// ---------------------------------------------------------------- open DNA pack (ADR-019, spec 3.4)
// After the pieces are decoded into the open scratch: the case runs are parsed into run ends
// (k_open_cse, one block per chunk), the bases are written with their case (k_open_bases,
// 16 positions per thread, binary search over the run ends), then the exceptions (k_open_exc,
// one block per chunk). Steps in src/ax_open_warp.h, judged on the CPU by
// scripts/open_warp_emu.cpp. err[0] counts bad chunks, err[1] the lowest index; a bad chunk
// stores 0 runs.
struct OpenDesc { const uint8_t *seq,*cse,*gap,*val; uint8_t* dst; uint32_t* ends; uint32_t* nrun; uint32_t raw, ncse, ngap, nexc; };
// exclusive scan over the block of AXO_NT threads; total of all threads in `total`
__device__ static inline uint64_t b_scan64(uint64_t v, uint64_t& total, uint64_t* sh){
    const uint32_t lane=threadIdx.x&31, w=threadIdx.x>>5, NW=AXO_NT/32; uint64_t inc=v;
    __syncwarp();                     // reconverge after the data-dependent LEB128 steps (T4: illegal instruction without it)
    #pragma unroll
    for(int o=1;o<32;o<<=1){ uint64_t t=__shfl_up_sync(0xffffffffu,inc,o); if(lane>=(uint32_t)o) inc+=t; }
    if(lane==31) sh[w]=inc;
    __syncthreads();
    if(w==0){ uint64_t x=lane<NW?sh[lane]:0;
        #pragma unroll
        for(int o=1;o<32;o<<=1){ uint64_t t=__shfl_up_sync(0xffffffffu,x,o); if(lane>=(uint32_t)o) x+=t; }
        if(lane<NW) sh[lane]=x; }
    __syncthreads();
    const uint64_t before=w?sh[w-1]:0; total=sh[NW-1];
    __syncthreads();
    return before+inc-v;
}
__global__ void __launch_bounds__(AXO_NT) k_open_cse(const OpenDesc* __restrict__ d, uint32_t* __restrict__ err){
    __shared__ uint64_t sh[AXO_NT/32];
    const uint32_t k=blockIdx.x, tid=threadIdx.x; const OpenDesc c=d[k]; const uint8_t* b=c.cse; const uint32_t n=c.ncse;
    bool bad=false; uint64_t carry=0; uint32_t jb=0;
    for(uint32_t base=0; base<n; base+=AXO_NT){
        const uint32_t t=base+tid; const bool term=axl_term(t,b,n); const uint32_t v=axl_value(t,b,term,bad);
        uint64_t total; const uint64_t ex=b_scan64(term?(AXO_KEY_J|v):0,total,sh);
        axl_cse_end(term,jb+(uint32_t)(ex>>44),v,carry+(ex&(AXO_KEY_J-1))+v,c.raw,c.ends,bad);
        jb+=(uint32_t)(total>>44); carry+=total&(AXO_KEY_J-1);
    }
    if(tid==0 && (axl_tail_bad(b,n) || carry!=c.raw)) bad=true;
    __syncwarp();
    const int any=__syncthreads_or(bad);
    if(tid==0){ *c.nrun = any?0:jb; if(any){ atomicAdd(err,1u); atomicMin(err+1,k); } }
}
__global__ void __launch_bounds__(256) k_open_bases(const OpenDesc* __restrict__ d){
    const OpenDesc c=d[blockIdx.x]; const uint32_t g=blockIdx.y*blockDim.x+threadIdx.x;
    if(16*g<c.raw) axl_bases16(g,c.seq,c.ends,*c.nrun,c.raw,c.dst);
}
__global__ void __launch_bounds__(AXO_NT) k_open_exc(const OpenDesc* __restrict__ d, uint32_t* __restrict__ err){
    __shared__ uint64_t sh[AXO_NT/32];
    const uint32_t k=blockIdx.x, tid=threadIdx.x; const OpenDesc c=d[k]; if(!c.nexc) return;   // uniform per block
    const uint8_t* b=c.gap; const uint32_t n=c.ngap;
    bool bad=false; uint64_t carry=0; uint32_t jb=0;
    for(uint32_t base=0; base<n; base+=AXO_NT){
        const uint32_t t=base+tid; const bool term=axl_term(t,b,n); const uint32_t v=axl_value(t,b,term,bad);
        uint64_t total; const uint64_t ex=b_scan64(term?(AXO_KEY_J|v):0,total,sh);
        axl_exc(term,jb+(uint32_t)(ex>>44),v,carry+(ex&(AXO_KEY_J-1))+v,c.nexc,c.raw,c.val,c.dst,bad);
        jb+=(uint32_t)(total>>44); carry+=total&(AXO_KEY_J-1);
    }
    if(tid==0 && (axl_tail_bad(b,n) || jb!=c.nexc)) bad=true;
    __syncwarp();
    const int any=__syncthreads_or(bad);
    if(tid==0 && any){ atomicAdd(err,1u); atomicMin(err+1,k); }
}

__global__ void k_set(uint32_t* p, uint32_t v){ *p=v; }
__global__ void k_fnv(const uint8_t* buf, size_t n, uint64_t* out){
    if(blockIdx.x==0&&threadIdx.x==0){ uint64_t h=0xcbf29ce484222325ULL; for(size_t i=0;i<n;i++) h=(h^buf[i])*0x100000001b3ULL; *out=h; }
}

// ---------------------------------------------------------------- archive parsing
static std::vector<uint8_t> slurp(const char* p){ FILE* f=fopen(p,"rb"); if(!f){perror(p); exit(1);} fseek(f,0,SEEK_END); long n=ftell(f); fseek(f,0,SEEK_SET); std::vector<uint8_t> v(n); if(fread(v.data(),1,n,f)!=(size_t)n){fprintf(stderr,"short read %s\n",p); exit(1);} fclose(f); return v; }
static inline uint64_t rd64(const uint8_t* p){ uint64_t v; memcpy(&v,p,8); return v; }
static inline uint32_t rd32(const uint8_t* p){ uint32_t v; memcpy(&v,p,4); return v; }
enum { K_PLAIN=0, K_SEQ=1, K_CSE=2, K_GAP=3, K_VAL=4 };
// a zstd frame: bytes in the archive, decoded size, where the output goes (stream 0..3 or
// scratch for DNA sub-frames), block index it belongs to (for batching)
struct Job { const uint8_t* src; size_t csz; size_t osz; int stream; int kind; uint64_t dst_off; uint32_t chunk; };
struct RawCopy { const uint8_t* src; size_t n; int stream; uint64_t dst_off; };
// a piece for k_rans: class 0 = token chunk, 1..4 = seq/cse/gap/val of an open DNA pack, 5 = open
// plain chunk; stream -1 = the open scratch buffer
enum { P_TOK=0, P_SEQ=1, P_CSE=2, P_GAP=3, P_VAL=4, P_PLAIN=5, P_NCLS=6 };
struct RansJob { const uint8_t* src; size_t csz, n; int stream; uint64_t dst_off; uint32_t mode; int cls; uint64_t lo; };   // lo: literal-stream offset of an open piece's chunk
struct OpenChunk { uint32_t chunk, raw, ncse, ngap, nexc; uint64_t off[4]; };
struct DnaChunk { uint32_t chunk; size_t raw; uint32_t nexc; bool has_gap, has_val; size_t job[4]; };

static float median_ms(std::vector<float> v){ std::sort(v.begin(),v.end()); return v[v.size()/2]; }

int main(int argc, char** argv){
    int PK=0;                                        // --pipeline[=K]: K block batches, H2D of batch k+1 under the decode of batch k
    { int j=1; for(int i=1;i<argc;i++){ if(!strncmp(argv[i],"--pipeline",10)){ PK = argv[i][10]=='=' ? atoi(argv[i]+11) : 8; if(PK<1) PK=1; } else argv[j++]=argv[i]; } argc=j; }
    if(argc<3){ fprintf(stderr,"usage: %s <archive.aet> <original> [G=auto|8|16|32] [repeats=7] [batches=4] [--pipeline[=K]]\n",argv[0]); return 1; }
    int Gwant = (argc>3 && strcmp(argv[3],"auto")!=0) ? atoi(argv[3]) : 0;
    int reps = argc>4 ? atoi(argv[4]) : 7; int NB = argc>5 ? atoi(argv[5]) : 4; if(NB<1) NB=1;
    std::vector<uint8_t> a=slurp(argv[1]);
    if(a.size()<68 || memcmp(a.data(),"ACEPX2\0\0",8)){ fprintf(stderr,"not an ACEPX2 archive\n"); return 1; }
    uint64_t orig=rd64(&a[12]); uint32_t bs=rd32(&a[20]), nb=rd32(&a[24]);
    uint64_t zl=rd64(&a[36]), zo=rd64(&a[44]), zn=rd64(&a[52]), zc=rd64(&a[60]);
    const uint8_t* zs[4]; uint64_t zsz[4]={zl,zo,zn,zc}; size_t p=68+64ull*nb; for(int i=0;i<4;i++){ zs[i]=&a[p]; p+=zsz[i]; }
    std::vector<BlockOffsets> bo(nb); memcpy(bo.data(),&a[68],64ull*nb);
    uint64_t ssz[4]={0,0,0,0}; uint64_t chunk[4]={0,0,0,0};
    std::vector<Job> jobs; std::vector<RawCopy> raws; std::vector<DnaChunk> dna; std::vector<RansJob> rans; std::vector<OpenChunk> opn; uint64_t oscr=0;
    for(int st=1; st<4; st++){                       // off/len/cmd
        const uint8_t* z=zs[st]; if(zsz[st]<8){ continue; } uint64_t w=rd64(z); uint64_t osz=w&((1ull<<48)-1);
        uint64_t ch=((w>>48)&0x7fff)*4096; if(!ch){ const char* e=getenv("FSE_CHUNK"); ch=e?strtoull(e,0,10):524288; }
        ssz[st]=osz; chunk[st]=ch; uint64_t nc=(osz+ch-1)/ch; size_t pos=8+8*nc;
        if(pos>zsz[st]){ fprintf(stderr,"chunk table of stream %d past the stream\n",st); return 1; }
        for(uint64_t i=0;i<nc;i++){ uint64_t cs=rd64(z+8+8*i); size_t raw=(size_t)std::min<uint64_t>(ch,osz-i*ch);
            if(((cs>>48)&0x3fff) || ((cs>>63)&&((cs>>62)&1))){ fprintf(stderr,"corrupt chunk entry, stream %d chunk %llu\n",st,(unsigned long long)i); return 1; }
            size_t csz=(cs>>63)?raw:(size_t)(cs&((1ull<<48)-1));
            if(csz>zsz[st]-pos){ fprintf(stderr,"chunk %llu of stream %d past the stream\n",(unsigned long long)i,st); return 1; }
            if(cs>>63) raws.push_back({z+pos,raw,st,i*ch});
            else if((cs>>62)&1) rans.push_back({z+pos,csz,raw,st,i*ch,1,P_TOK});   // rANS token chunk (ADR-018): k_rans on the device
            else jobs.push_back({z+pos,csz,raw,st,K_PLAIN,i*ch,(uint32_t)i});
            pos+=csz; }
    }
    const size_t NT=jobs.size();                     // jobs [0,NT) are token frames, [NT,N) literal frames
    { const uint8_t* z=zs[0]; uint64_t h=rd64(z); bool zl62=h&(1ull<<62); bool chunked=h&(1ull<<61); bool tagged=h&(1ull<<60);
      if(!zl62){ fprintf(stderr,"literal stream without bit62 (FSE layout) not handled here\n"); return 1; }
      uint64_t sz=h&~((1ull<<62)|(1ull<<61)|(1ull<<60)); uint64_t CH=chunked?rd64(z+8):(sz+3)/4; uint64_t NW=chunked?(sz+CH-1)/CH:4;
      size_t pos=(chunked?16:8)+8*NW; ssz[0]=sz; chunk[0]=CH;
      if(pos>zsz[0]){ fprintf(stderr,"literal chunk table past the stream\n"); return 1; }
      for(uint64_t t=0;t<NW;t++){ uint64_t o=t*CH; size_t raw=(size_t)(o>=sz?0:(o+CH<=sz?CH:sz-o)); size_t csz=rd64(z+(chunked?16:8)+8*t); const uint8_t* c=z+pos;
        if(csz>zsz[0]-pos){ fprintf(stderr,"literal chunk %llu past the stream\n",(unsigned long long)t); return 1; }
        pos+=csz;
        if(!raw) continue;
        if(tagged && csz && c[0]==2){                      // open DNA pack: framing checked here, content on the device
            AxoParts P; if(csz<2 || axo_parse(c+1,csz-1,(uint32_t)raw,&P)){ fprintf(stderr,"literal chunk %llu: bad open DNA pack framing\n",(unsigned long long)t); return 1; }
            OpenChunk oc; oc.chunk=(uint32_t)t; oc.raw=(uint32_t)raw; oc.ncse=P.ncse; oc.ngap=P.ngap; oc.nexc=P.nexc;
            for(int q=0;q<4;q++){ oc.off[q]=oscr; oscr+=((uint64_t)P.n[q]+64)&~63ull;
                if(P.n[q]) rans.push_back({c+1+P.off[q],P.h[q],P.n[q],-1,oc.off[q],P.mode[q],P_SEQ+q,o}); }
            opn.push_back(oc); continue; }
        if(tagged && csz && c[0]==3){                      // open plain: one piece into the literal stream
            if(csz<2 || c[1]>1 || (c[1]==0 && csz-2!=raw)){ fprintf(stderr,"literal chunk %llu: bad open piece\n",(unsigned long long)t); return 1; }
            rans.push_back({c+2,csz-2,raw,0,o,c[1],P_PLAIN}); continue; }
        if(tagged && c[0]==1){ uint32_t nexc=rd32(c+1),h1=rd32(c+5),h2=rd32(c+9),h3=rd32(c+13),h4=rd32(c+17); const uint8_t* f=c+21;
            DnaChunk d; d.chunk=(uint32_t)t; d.raw=raw; d.nexc=nexc; d.has_gap=h3!=0; d.has_val=h4!=0; for(int k=0;k<4;k++) d.job[k]=(size_t)-1;
            d.job[0]=jobs.size(); jobs.push_back({f,h1,(raw+3)/4,0,K_SEQ,0,(uint32_t)t}); f+=h1;
            d.job[1]=jobs.size(); jobs.push_back({f,h2,(raw+7)/8,0,K_CSE,0,(uint32_t)t}); f+=h2;
            if(h3){ d.job[2]=jobs.size(); jobs.push_back({f,h3,(size_t)nexc*4,0,K_GAP,0,(uint32_t)t}); } f+=h3;
            if(h4){ d.job[3]=jobs.size(); jobs.push_back({f,h4,(size_t)nexc,0,K_VAL,0,(uint32_t)t}); }
            dna.push_back(d); }
        else jobs.push_back({tagged?c+1:c, tagged?csz-1:csz, raw, 0, K_PLAIN, o, (uint32_t)t}); }
    }
    size_t N=jobs.size(), cbytes=0, scratch=0, maxo=0; std::vector<size_t> coff(N), soff(N);
    for(size_t i=0;i<N;i++){ coff[i]=cbytes; cbytes+=jobs[i].csz; maxo=std::max(maxo,jobs[i].osz);
        if(jobs[i].kind!=K_PLAIN){ soff[i]=scratch; scratch+=(jobs[i].osz+63)&~size_t(63); } }
    // pieces (rANS token chunks, open-profile pieces) grouped by class; their bytes follow the frames in dC
    std::stable_sort(rans.begin(),rans.end(),[](const RansJob& x,const RansJob& y){ return x.cls<y.cls; });
    const size_t zbytes=cbytes, NR=rans.size(); std::vector<RansDesc> hr(NR); size_t cls_off[P_NCLS+1]={0};
    for(size_t k=0;k<NR;k++){ hr[k]={cbytes,nullptr,(uint32_t)rans[k].csz,(uint32_t)rans[k].n,rans[k].mode}; cbytes+=rans[k].csz; cls_off[rans[k].cls+1]++; }
    for(int q=0;q<P_NCLS;q++) cls_off[q+1]+=cls_off[q];
    const size_t NTOK=cls_off[P_TOK+1]-cls_off[P_TOK];
    printf("archive %s: orig=%llu block=%u nb=%u; %zu zstd frames (%zu token, %zu literal; %.1f MB), pieces %.1f MB: %zu token rANS chunks, open pack seq/cse/gap/val %zu/%zu/%zu/%zu, open plain %zu; %zu raw chunks, %zu DNA chunks (zstd), %zu open DNA chunks; streams lit/off/len/cmd = %.1f/%.1f/%.1f/%.1f MB\n",
        argv[1],(unsigned long long)orig,bs,nb,N,NT,N-NT,zbytes/1e6,(cbytes-zbytes)/1e6,NTOK,cls_off[2]-cls_off[1],cls_off[3]-cls_off[2],cls_off[4]-cls_off[3],cls_off[5]-cls_off[4],cls_off[6]-cls_off[5],
        raws.size(),dna.size(),opn.size(),ssz[0]/1e6,ssz[1]/1e6,ssz[2]/1e6,ssz[3]/1e6);

    // ---- device buffers: streams, scratch, compressed input, tables, output
    uint8_t *dS[4], *dScr, *dC, *dOUT; BlockOffsets* dBO; uint32_t* dCTR; DnaDesc* dDD; uint64_t* dH;
    for(int i=0;i<4;i++) CK(cudaMalloc(&dS[i],ssz[i]+256));
    CK(cudaMalloc(&dScr,scratch+256)); CK(cudaMalloc(&dC,cbytes+256)); CK(cudaMalloc(&dOUT,orig+256));
    CK(cudaMalloc(&dBO,64ull*nb)); CK(cudaMalloc(&dCTR,4)); CK(cudaMalloc(&dH,8)); CK(cudaMalloc(&dDD,(dna.size()+1)*sizeof(DnaDesc)));
    CK(cudaMemcpy(dBO,bo.data(),64ull*nb,cudaMemcpyHostToDevice));
    uint8_t* hc; CK(cudaHostAlloc(&hc,cbytes+1,cudaHostAllocDefault)); for(size_t i=0;i<N;i++) memcpy(hc+coff[i],jobs[i].src,jobs[i].csz);
    uint8_t* dOS; CK(cudaMalloc(&dOS,oscr+256));                      // open scratch: seq/cse/gap/val of every open chunk
    for(size_t k=0;k<NR;k++){ memcpy(hc+hr[k].src,rans[k].src,rans[k].csz); hr[k].dst=(rans[k].stream<0?dOS:dS[rans[k].stream])+rans[k].dst_off; }
    RansDesc* dRD; uint32_t* dErr; CK(cudaMalloc(&dRD,(NR+1)*sizeof(RansDesc))); CK(cudaMalloc(&dErr,16));
    if(NR) CK(cudaMemcpy(dRD,hr.data(),NR*sizeof(RansDesc),cudaMemcpyHostToDevice));
    { const uint32_t e0[4]={0u,0xffffffffu,0u,0xffffffffu}; CK(cudaMemcpy(dErr,e0,16,cudaMemcpyHostToDevice)); }
    const size_t NO=opn.size(); std::vector<OpenDesc> ho(NO); OpenDesc* dOD; CK(cudaMalloc(&dOD,(NO+1)*sizeof(OpenDesc)));
    uint64_t nends=0; for(const OpenChunk& q:opn) nends+=q.ncse;          // run ends: at most one per case-run byte
    uint32_t *dEnds, *dNrun; CK(cudaMalloc(&dEnds,(nends+1)*4)); CK(cudaMalloc(&dNrun,(NO+1)*4));
    for(size_t k=0;k<NO;k++){ const OpenChunk& q=opn[k]; ho[k]={dOS+q.off[0],dOS+q.off[1],dOS+q.off[2],dOS+q.off[3],dS[0]+(uint64_t)q.chunk*chunk[0],nullptr,dNrun+k,q.raw,q.ncse,q.ngap,q.nexc}; }
    { uint64_t e=0; for(size_t k=0;k<NO;k++){ ho[k].ends=dEnds+e; e+=opn[k].ncse; } }
    if(NO) CK(cudaMemcpy(dOD,ho.data(),NO*sizeof(OpenDesc),cudaMemcpyHostToDevice));
    for(auto& r:raws) CK(cudaMemcpy(dS[r.stream]+r.dst_off,r.src,r.n,cudaMemcpyHostToDevice));
    std::vector<const void*> hcp(N); std::vector<void*> hop(N); std::vector<size_t> hcs(N), hos(N);
    for(size_t i=0;i<N;i++){ const Job& j=jobs[i]; hcp[i]=dC+coff[i]; hcs[i]=j.csz; hos[i]=j.osz;
        hop[i]= j.kind==K_PLAIN ? (void*)(dS[j.stream]+j.dst_off) : (void*)(dScr+soff[i]); }
    const void** dcp; void** dop; size_t *dcs,*dos,*dact; nvcompStatus_t* dst;
    CK(cudaMalloc(&dcp,N*8)); CK(cudaMalloc(&dop,N*8)); CK(cudaMalloc(&dcs,N*8)); CK(cudaMalloc(&dos,N*8)); CK(cudaMalloc(&dact,N*8)); CK(cudaMalloc(&dst,N*sizeof(nvcompStatus_t)));
    CK(cudaMemcpy(dcp,hcp.data(),N*8,cudaMemcpyHostToDevice)); CK(cudaMemcpy(dop,hop.data(),N*8,cudaMemcpyHostToDevice));
    CK(cudaMemcpy(dcs,hcs.data(),N*8,cudaMemcpyHostToDevice)); CK(cudaMemcpy(dos,hos.data(),N*8,cudaMemcpyHostToDevice));
    std::vector<DnaDesc> hd(dna.size());
    for(size_t k=0;k<dna.size();k++){ const DnaChunk& d=dna[k]; auto P=[&](int q)->const uint8_t*{ return d.job[q]==(size_t)-1?nullptr:dScr+soff[d.job[q]]; };
        hd[k]={P(0),P(1),P(2),P(3), dS[0]+(uint64_t)d.chunk*chunk[0], (uint32_t)d.raw, d.nexc}; }
    if(!hd.empty()) CK(cudaMemcpy(dDD,hd.data(),hd.size()*sizeof(DnaDesc),cudaMemcpyHostToDevice));
    nvcompBatchedZstdDecompressOpts_t opts=nvcompBatchedZstdDecompressDefaultOpts;
    // temp for all frames in one call, and for the token / literal frames as two calls (stage timing)
    size_t temp=0, tmp2=0; const size_t tot_out=scratch+ssz[0]+ssz[1]+ssz[2]+ssz[3];
    if(N) NV(nvcompBatchedZstdDecompressGetTempSizeAsync(N,maxo,opts,&temp,tot_out));
    if(NT){ NV(nvcompBatchedZstdDecompressGetTempSizeAsync(NT,maxo,opts,&tmp2,tot_out)); temp=std::max(temp,tmp2); }
    if(N>NT){ NV(nvcompBatchedZstdDecompressGetTempSizeAsync(N-NT,maxo,opts,&tmp2,tot_out)); temp=std::max(temp,tmp2); }
    void* dtemp; CK(cudaMalloc(&dtemp,temp+256));
    cudaStream_t s0,s1; CK(cudaStreamCreate(&s0)); CK(cudaStreamCreate(&s1));
    cudaEvent_t e0,e1; CK(cudaEventCreate(&e0)); CK(cudaEventCreate(&e1));
    auto elapsed=[&](cudaStream_t s, auto fn){ CK(cudaEventRecord(e0,s)); fn(); CK(cudaEventRecord(e1,s)); CK(cudaEventSynchronize(e1)); float ms=0; CK(cudaEventElapsedTime(&ms,e0,e1)); return ms; };

    // ---- stage functions
    auto h2d=[&](cudaStream_t s){ CK(cudaMemcpyAsync(dC,hc,cbytes,cudaMemcpyHostToDevice,s)); };
    auto zstd_rng=[&](cudaStream_t s, size_t i0, size_t i1){ if(i1>i0) NV(nvcompBatchedZstdDecompressAsync(dcp+i0,dcs+i0,dos+i0,dact+i0,i1-i0,dtemp,temp,dop+i0,opts,dst+i0,s)); };
    auto zstd_all=[&](cudaStream_t s){ zstd_rng(s,0,N); };
    auto pieces=[&](cudaStream_t s, int c0, int c1){ const size_t i0=cls_off[c0], n=cls_off[c1]-i0;
        if(n) k_rans<<<(unsigned)((n+AXW_WARPS-1)/AXW_WARPS),32*AXW_WARPS,0,s>>>(dC,dRD+i0,(uint32_t)n,dErr); };
    auto rans_all=[&](cudaStream_t s){ pieces(s,0,P_NCLS); };
    auto tok=[&](cudaStream_t s){ zstd_rng(s,0,NT); pieces(s,P_TOK,P_TOK+1); };   // token streams: zstd frames and/or rANS chunks
    auto lit=[&](cudaStream_t s){ zstd_rng(s,NT,N); pieces(s,P_SEQ,P_NCLS); };    // literal zstd frames and open pieces
    // fail-closed: a piece or an open DNA chunk that failed its checks stops the run before any number is printed as valid
    auto rans_check=[&](const char* tag){ uint32_t e[4]; CK(cudaMemcpy(e,dErr,16,cudaMemcpyDeviceToHost));
        if(e[0]){ fprintf(stderr,"[%s] rANS/pieces: %u of %zu failed the spec 3.1.1/3.4 checks (first: piece %u) - archive rejected\n",tag,e[0],NR,e[1]); exit(6); }
        if(e[2]){ fprintf(stderr,"[%s] open DNA pack: %u of %zu chunks failed the spec 3.4 checks (first: %u) - archive rejected\n",tag,e[2],NO,e[3]); exit(6); } };
    dim3 g1((unsigned)std::max<size_t>(dna.size(),1), (unsigned)((chunk[0]/4+255)/256));
    dim3 go((unsigned)std::max<size_t>(NO,1), (unsigned)((chunk[0]/16+255)/256));
    auto un_seq=[&](cudaStream_t s){ if(NO) k_open_bases<<<go,256,0,s>>>(dOD); };                     // bases + case
    auto un_cse=[&](cudaStream_t s){ if(NO) k_open_cse<<<(unsigned)NO,AXO_NT,0,s>>>(dOD,dErr+2); };   // case runs -> run ends
    auto un_exc=[&](cudaStream_t s){ if(NO) k_open_exc<<<(unsigned)NO,AXO_NT,0,s>>>(dOD,dErr+2); };
    auto unpack=[&](cudaStream_t s){ if(!dna.empty()){ k_unpack<<<g1,256,0,s>>>(dDD); k_exc<<<(unsigned)dna.size(),256,0,s>>>(dDD); }
        un_cse(s); un_seq(s); un_exc(s); };
    const int TPB=128; int dev=0,nsm=0; CK(cudaGetDevice(&dev)); CK(cudaDeviceGetAttribute(&nsm,cudaDevAttrMultiProcessorCount,dev));
    cudaDeviceProp prop; CK(cudaGetDeviceProperties(&prop,dev));
    auto match=[&](int G, cudaStream_t s, uint32_t b0, uint32_t b1){
        kern_t k = G==8?k_decode_g<8>:G==16?k_decode_g<16>:k_decode_g<32>;
        int maxblk=0; CK(cudaOccupancyMaxActiveBlocksPerMultiprocessor(&maxblk,k,TPB,0));
        uint64_t lanes=(uint64_t)(b1-b0)*G; uint32_t want=(uint32_t)((lanes+TPB-1)/TPB), grid=(uint32_t)nsm*maxblk; if(grid>want) grid=want; if(grid<1) grid=1;
        CK(cudaMemcpyAsync(dCTR,&b0,4,cudaMemcpyHostToDevice,s));
        k<<<grid,TPB,0,s>>>(dS[0],dS[1],dS[2],dS[3],dBO,orig,bs,dOUT,dCTR,b1); };

    // ---- warm-up: full sequential pass, then check bit-perfect against the original
    h2d(s0); zstd_all(s0); rans_all(s0); unpack(s0); match(Gwant?Gwant:16,s0,0,nb); CK(cudaStreamSynchronize(s0)); CK(cudaGetLastError());
    rans_check("warm-up");
    { std::vector<nvcompStatus_t> hst(N); CK(cudaMemcpy(hst.data(),dst,N*sizeof(nvcompStatus_t),cudaMemcpyDeviceToHost)); size_t bad=0; for(auto x:hst) if(x!=nvcompSuccess) bad++;
      printf("frames: %zu bad of %zu\n",bad,N); }
    auto fnv_check=[&](const char* tag){ uint64_t h=0; k_fnv<<<1,1,0,s0>>>(dOUT,(size_t)orig,dH); CK(cudaMemcpyAsync(&h,dH,8,cudaMemcpyDeviceToHost,s0)); CK(cudaStreamSynchronize(s0));
        static uint64_t ho=0; static bool have=false;
        if(!have){ FILE* f=fopen(argv[2],"rb"); if(!f){perror(argv[2]); exit(1);} std::vector<uint8_t> buf(1<<20); size_t n; ho=0xcbf29ce484222325ULL;
            while((n=fread(buf.data(),1,buf.size(),f))>0){ for(size_t i=0;i<n;i++) ho=(ho^buf[i])*0x100000001b3ULL; }
            fclose(f); have=true; }
        printf("[%s] FNV out=%016llx orig=%016llx %s\n",tag,(unsigned long long)h,(unsigned long long)ho,h==ho?"MATCHES OK":"DIFFERS X"); return h==ho; };
    bool ok=fnv_check("warm-up");

    // ---- G probe: first min(nb,2048) blocks, 3 runs each, pick the fastest
    int G=Gwant; uint32_t pb=std::min<uint32_t>(nb,2048);
    if(!G){ float best=1e30f; for(int g:{8,16,32}){ std::vector<float> t; for(int r=0;r<3;r++) t.push_back(elapsed(s0,[&]{ match(g,s0,0,pb); }));
            float m=median_ms(t); printf("probe G=%d: %.3f ms on %u blocks\n",g,m,pb); if(m<best){best=m;G=g;} }
        printf("chosen G=%d on %s (%d SMs)\n",G,prop.name,nsm); }
    // ---- sequential stages, median of reps; lit and unpack also split into their parts
    std::vector<float> tH,tT,tL,tU,tM, tLz,tLp[P_NCLS],tUd,tUs,tUc,tUe;
    for(int r=0;r<reps;r++){ tH.push_back(elapsed(s0,[&]{h2d(s0);})); tT.push_back(elapsed(s0,[&]{tok(s0);})); tL.push_back(elapsed(s0,[&]{lit(s0);}));
        tU.push_back(elapsed(s0,[&]{unpack(s0);})); tM.push_back(elapsed(s0,[&]{match(G,s0,0,nb);}));
        tLz.push_back(elapsed(s0,[&]{zstd_rng(s0,NT,N);}));
        for(int q=P_SEQ;q<P_NCLS;q++) tLp[q].push_back(elapsed(s0,[&]{pieces(s0,q,q+1);}));
        tUd.push_back(elapsed(s0,[&]{ if(!dna.empty()){ k_unpack<<<g1,256,0,s0>>>(dDD); k_exc<<<(unsigned)dna.size(),256,0,s0>>>(dDD); } }));
        tUc.push_back(elapsed(s0,[&]{un_cse(s0);})); tUs.push_back(elapsed(s0,[&]{un_seq(s0);})); tUe.push_back(elapsed(s0,[&]{un_exc(s0);})); }
    rans_check("sequential");
    float mH=median_ms(tH),mT=median_ms(tT),mL=median_ms(tL),mU=median_ms(tU),mM=median_ms(tM), mD=mT+mL+mU+mM, seq=mH+mD;
    float mLz=median_ms(tLz), mLp[P_NCLS]={0}; for(int q=P_SEQ;q<P_NCLS;q++) mLp[q]=median_ms(tLp[q]);
    float mUd=median_ms(tUd), mUs=median_ms(tUs), mUc=median_ms(tUc), mUe=median_ms(tUe);
    const size_t NLP=cls_off[P_NCLS]-cls_off[P_SEQ];
    const char* tmode = NTOK&&NT ? "zstd+rANS" : NTOK ? "rANS" : "zstd";
    const char* lmode = NLP&&N>NT ? "zstd+open" : NLP ? "open" : "zstd";
    printf("[sequential] H2D %.3f + tok(%s: %zu frames, %zu chunks) %.3f + lit(%s: %zu frames, %zu pieces) %.3f + unpack %.3f + match(G=%d) %.3f = %.3f ms -> %.1f GB/s delivered; on-device %.3f ms -> %.1f GB/s\n",
        mH,tmode,NT,NTOK,mT,lmode,N-NT,NLP,mL,mU,G,mM,seq,orig/seq/1e6,mD,orig/mD/1e6);
    printf("[lit parts] zstd frames %.3f | open pieces: seq %.3f, cse %.3f, gap %.3f, val %.3f, plain %.3f ms\n",mLz,mLp[P_SEQ],mLp[P_CSE],mLp[P_GAP],mLp[P_VAL],mLp[P_PLAIN]);
    printf("[unpack parts] zstd DNA pack %.3f | open: bases %.3f, case runs %.3f, exceptions %.3f ms\n",mUd,mUs,mUc,mUe);
    ok = fnv_check("sequential") && ok;

    // ---- pipeline: NB batches of frames in order; H2D of batch k+1 on s1 overlaps zstd of batch k on s0
    // (the pieces follow the frames in dC and arrive with the last batch)
    std::vector<size_t> bcut(NB+1); for(int k=0;k<=NB;k++) bcut[k]=(size_t)((double)N*k/NB);
    auto byte_at=[&](size_t i)->size_t{ return i<N?coff[i]:zbytes; };
    std::vector<size_t> btemp(NB,0); size_t maxtemp=0;
    for(int k=0;k<NB;k++){ size_t n=bcut[k+1]-bcut[k], ob=0; for(size_t i=bcut[k];i<bcut[k+1];i++) ob+=jobs[i].osz;
        if(n) NV(nvcompBatchedZstdDecompressGetTempSizeAsync(n,maxo,opts,&btemp[k],ob)); maxtemp=std::max(maxtemp,btemp[k]); }
    void* dtemp2; CK(cudaMalloc(&dtemp2,maxtemp+256));
    std::vector<cudaEvent_t> ev(NB); for(auto& e:ev) CK(cudaEventCreate(&e));
    auto pipeline=[&](){
        for(int k=0;k<NB;k++){ size_t i0=bcut[k], n=bcut[k+1]-i0, b0=byte_at(i0), b1=k+1<NB?byte_at(bcut[k+1]):cbytes;
            if(b1>b0) CK(cudaMemcpyAsync(dC+b0,hc+b0,b1-b0,cudaMemcpyHostToDevice,s1)); CK(cudaEventRecord(ev[k],s1));
            CK(cudaStreamWaitEvent(s0,ev[k],0));
            if(n) NV(nvcompBatchedZstdDecompressAsync(dcp+i0,dcs+i0,dos+i0,dact+i0,n,dtemp2,maxtemp,dop+i0,opts,dst+i0,s0)); }
        rans_all(s0); unpack(s0); match(G,s0,0,nb); };
    std::vector<float> tP; for(int r=0;r<reps;r++) tP.push_back(elapsed(s0,[&]{ pipeline(); }));
    float mP=median_ms(tP);
    printf("[pipeline] %d batches, H2D overlapped with zstd: %.3f ms -> %.1f GB/s delivered (sequential %.3f ms, gain %.1f%%)\n",NB,mP,orig/mP/1e6,seq,100.0*(seq-mP)/seq);
    rans_check("pipeline");
    ok = fnv_check("pipeline") && ok;

    // ---- H2D of the archive bytes: pageable (a malloc'd copy) against pinned (hc, cudaHostAlloc)
    float gbPg=0, gbPn=0;
    { std::vector<uint8_t> pg(hc,hc+cbytes); std::vector<float> a1,a2;
      for(int r=0;r<reps;r++){ a1.push_back(elapsed(s0,[&]{ CK(cudaMemcpyAsync(dC,pg.data(),cbytes,cudaMemcpyHostToDevice,s0)); }));
                               a2.push_back(elapsed(s0,[&]{ h2d(s0); })); }
      gbPg=cbytes/median_ms(a1)/1e6; gbPn=cbytes/median_ms(a2)/1e6;
      printf("[h2d] %.1f MB: pageable %.3f ms (%.1f GB/s), pinned %.3f ms (%.1f GB/s)\n",cbytes/1e6,median_ms(a1),gbPg,median_ms(a2),gbPn); }

    // ---- stream pipeline (--pipeline=K): the blocks in K batches; every frame, piece and literal chunk
    // belongs to the batch of the first block that reads its output, and its compressed bytes are laid out
    // batch by batch in a second pinned buffer. Stream s1 copies batch k+1 while s0 decodes batch k
    // (frames, pieces, unpack, match of its blocks); s0 runs the batches in order, so a chunk decoded
    // for an earlier batch is in place when a later block reads it.
    float mSP=0;
    if(PK){
        const int K=(int)std::min<uint32_t>((uint32_t)PK,nb);
        std::vector<uint32_t> bc(K+1); for(int k=0;k<=K;k++) bc[k]=(uint32_t)((uint64_t)nb*k/K);
        auto bend=[&](int st,uint32_t b)->uint64_t{ const BlockOffsets& x=bo[b]; return st==0?x.lit_off+x.lit_sz:st==1?x.off_off+x.off_sz:st==2?x.len_off+x.len_sz:x.cmd_off+x.cmd_sz; };
        for(int st=0;st<4;st++) for(uint32_t b=1;b<nb;b++) if(bend(st,b)<bend(st,b-1)){ fprintf(stderr,"[stream-pipeline] stream %d block ends not monotonic - not run\n",st); exit(7); }
        auto kof=[&](uint32_t b)->int{ return (int)(std::upper_bound(bc.begin(),bc.end(),b)-bc.begin())-1; };
        auto batch_of=[&](int st,uint64_t o)->int{ uint32_t lo=0,hi=nb; while(lo<hi){ uint32_t m=(lo+hi)/2; if(bend(st,m)>o) hi=m; else lo=m+1; } return kof(lo<nb?lo:nb-1); };
        std::vector<int> jb(N), rb(NR), ob(NO), db(dna.size());
        for(size_t i=0;i<N;i++){ const Job& j=jobs[i]; jb[i]= j.kind==K_PLAIN ? batch_of(j.stream,j.dst_off) : batch_of(0,(uint64_t)j.chunk*chunk[0]); }
        for(size_t k=0;k<NR;k++){ const RansJob& r=rans[k]; rb[k]= r.stream<0 ? batch_of(0,r.lo) : batch_of(r.stream,r.dst_off); }
        for(size_t k=0;k<NO;k++) ob[k]=batch_of(0,(uint64_t)opn[k].chunk*chunk[0]);
        for(size_t k=0;k<dna.size();k++) db[k]=batch_of(0,(uint64_t)dna[k].chunk*chunk[0]);
        for(size_t k=1;k<NO;k++) if(ob[k]<ob[k-1]){ fprintf(stderr,"[stream-pipeline] open chunks out of order - not run\n"); exit(7); }
        for(size_t k=1;k<dna.size();k++) if(db[k]<db[k-1]){ fprintf(stderr,"[stream-pipeline] DNA chunks out of order - not run\n"); exit(7); }
        std::vector<size_t> pj(N), pr(NR); for(size_t i=0;i<N;i++) pj[i]=i; for(size_t k=0;k<NR;k++) pr[k]=k;
        std::stable_sort(pj.begin(),pj.end(),[&](size_t x,size_t y){ return jb[x]<jb[y]; });
        std::stable_sort(pr.begin(),pr.end(),[&](size_t x,size_t y){ return rb[x]<rb[y]; });
        std::vector<size_t> jc(K+1,0), rc(K+1,0), oc(K+1,0), dc(K+1,0), cc(K+1,0);
        for(size_t i=0;i<N;i++) jc[jb[i]+1]++; for(size_t k=0;k<NR;k++) rc[rb[k]+1]++;
        for(size_t k=0;k<NO;k++) oc[ob[k]+1]++; for(size_t k=0;k<dna.size();k++) dc[db[k]+1]++;
        for(int k=0;k<K;k++){ jc[k+1]+=jc[k]; rc[k+1]+=rc[k]; oc[k+1]+=oc[k]; dc[k+1]+=dc[k]; }
        // batch-ordered bytes: batch k = its frames, then its pieces
        uint8_t* hc2; CK(cudaHostAlloc(&hc2,cbytes+1,cudaHostAllocDefault)); uint8_t* dC2; CK(cudaMalloc(&dC2,cbytes+256));
        std::vector<const void*> qcp(N); std::vector<void*> qop(N); std::vector<size_t> qcs(N), qos(N); std::vector<RansDesc> qr(NR);
        size_t w=0;
        for(int k=0;k<K;k++){ cc[k]=w;
            for(size_t i=jc[k];i<jc[k+1];i++){ const size_t x=pj[i]; memcpy(hc2+w,jobs[x].src,jobs[x].csz); qcp[i]=dC2+w; qop[i]=hop[x]; qcs[i]=hcs[x]; qos[i]=hos[x]; w+=jobs[x].csz; }
            for(size_t i=rc[k];i<rc[k+1];i++){ const size_t x=pr[i]; memcpy(hc2+w,rans[x].src,rans[x].csz); qr[i]=hr[x]; qr[i].src=w; w+=rans[x].csz; } }
        cc[K]=w; if(w!=cbytes){ fprintf(stderr,"[stream-pipeline] layout %zu != %zu bytes\n",w,cbytes); exit(7); }
        const void** qdcp; void** qdop; size_t *qdcs,*qdos,*qdact; nvcompStatus_t* qdst; RansDesc* qdRD;
        CK(cudaMalloc(&qdcp,N*8+8)); CK(cudaMalloc(&qdop,N*8+8)); CK(cudaMalloc(&qdcs,N*8+8)); CK(cudaMalloc(&qdos,N*8+8)); CK(cudaMalloc(&qdact,N*8+8));
        CK(cudaMalloc(&qdst,N*sizeof(nvcompStatus_t)+8)); CK(cudaMalloc(&qdRD,(NR+1)*sizeof(RansDesc)));
        if(N){ CK(cudaMemcpy(qdcp,qcp.data(),N*8,cudaMemcpyHostToDevice)); CK(cudaMemcpy(qdop,qop.data(),N*8,cudaMemcpyHostToDevice));
               CK(cudaMemcpy(qdcs,qcs.data(),N*8,cudaMemcpyHostToDevice)); CK(cudaMemcpy(qdos,qos.data(),N*8,cudaMemcpyHostToDevice)); }
        if(NR) CK(cudaMemcpy(qdRD,qr.data(),NR*sizeof(RansDesc),cudaMemcpyHostToDevice));
        size_t qtemp=0; for(int k=0;k<K;k++){ size_t n=jc[k+1]-jc[k], o=0, t=0; for(size_t i=jc[k];i<jc[k+1];i++) o+=qos[i];
            if(n){ NV(nvcompBatchedZstdDecompressGetTempSizeAsync(n,maxo,opts,&t,o)); qtemp=std::max(qtemp,t); } }
        void* qdtemp; CK(cudaMalloc(&qdtemp,qtemp+256));
        uint32_t* dCTR2; CK(cudaMalloc(&dCTR2,4*(K+1)));
        kern_t kG = G==8?k_decode_g<8>:G==16?k_decode_g<16>:k_decode_g<32>;
        int maxblk=0; CK(cudaOccupancyMaxActiveBlocksPerMultiprocessor(&maxblk,kG,TPB,0));
        std::vector<cudaEvent_t> cev(K); for(auto& e:cev) CK(cudaEventCreateWithFlags(&e,cudaEventDisableTiming));
        cudaEvent_t st0; CK(cudaEventCreateWithFlags(&st0,cudaEventDisableTiming));
        auto spipe=[&](){
            CK(cudaEventRecord(st0,s0)); CK(cudaStreamWaitEvent(s1,st0,0));
            for(int k=0;k<K;k++){ if(cc[k+1]>cc[k]) CK(cudaMemcpyAsync(dC2+cc[k],hc2+cc[k],cc[k+1]-cc[k],cudaMemcpyHostToDevice,s1)); CK(cudaEventRecord(cev[k],s1)); }
            for(int k=0;k<K;k++){ CK(cudaStreamWaitEvent(s0,cev[k],0));
                const size_t j0=jc[k], nj=jc[k+1]-j0, r0=rc[k], nr=rc[k+1]-r0, o0=oc[k], no=oc[k+1]-o0, d0=dc[k], nd=dc[k+1]-d0;
                if(nj) NV(nvcompBatchedZstdDecompressAsync(qdcp+j0,qdcs+j0,qdos+j0,qdact+j0,nj,qdtemp,qtemp,qdop+j0,opts,qdst+j0,s0));
                if(nr) k_rans<<<(unsigned)((nr+AXW_WARPS-1)/AXW_WARPS),32*AXW_WARPS,0,s0>>>(dC2,qdRD+r0,(uint32_t)nr,dErr);
                if(nd){ k_unpack<<<dim3((unsigned)nd,g1.y),256,0,s0>>>(dDD+d0); k_exc<<<(unsigned)nd,256,0,s0>>>(dDD+d0); }
                if(no){ k_open_cse<<<(unsigned)no,AXO_NT,0,s0>>>(dOD+o0,dErr+2); k_open_bases<<<dim3((unsigned)no,go.y),256,0,s0>>>(dOD+o0); k_open_exc<<<(unsigned)no,AXO_NT,0,s0>>>(dOD+o0,dErr+2); }
                const uint32_t b0=bc[k], b1=bc[k+1]; if(b1>b0){
                    uint64_t lanes=(uint64_t)(b1-b0)*G; uint32_t want=(uint32_t)((lanes+TPB-1)/TPB), grid=(uint32_t)nsm*maxblk; if(grid>want) grid=want; if(grid<1) grid=1;
                    k_set<<<1,1,0,s0>>>(dCTR2+k,b0); kG<<<grid,TPB,0,s0>>>(dS[0],dS[1],dS[2],dS[3],dBO,orig,bs,dOUT,dCTR2+k,b1); } } };
        // cold pass on cleared buffers (output, decoded streams, scratch; raw chunks copied back): the hash
        // below checks this path alone, a batch that ran before its bytes arrived cannot hide behind old data
        CK(cudaMemset(dOUT,0,orig)); for(int i=0;i<4;i++) CK(cudaMemset(dS[i],0,ssz[i]+256));
        CK(cudaMemset(dScr,0,scratch+256)); CK(cudaMemset(dOS,0,oscr+256));
        for(auto& r:raws) CK(cudaMemcpy(dS[r.stream]+r.dst_off,r.src,r.n,cudaMemcpyHostToDevice));
        spipe(); CK(cudaStreamSynchronize(s0)); CK(cudaGetLastError());
        rans_check("stream-pipeline");
        if(N){ std::vector<nvcompStatus_t> hst(N); CK(cudaMemcpy(hst.data(),qdst,N*sizeof(nvcompStatus_t),cudaMemcpyDeviceToHost)); size_t bad=0; for(auto x:hst) if(x!=nvcompSuccess) bad++;
            if(bad){ fprintf(stderr,"[stream-pipeline] %zu frames failed\n",bad); ok=false; } }
        ok = fnv_check("stream-pipeline cold") && ok;
        std::vector<float> tS; for(int r=0;r<reps;r++) tS.push_back(elapsed(s0,[&]{ spipe(); }));
        mSP=median_ms(tS); size_t mb=0; for(int k=0;k<K;k++) mb=std::max(mb,cc[k+1]-cc[k]);
        printf("[stream-pipeline] %d batches (largest %.1f MB), copy stream + decode stream: %.3f ms -> %.1f GB/s delivered; sequential %.3f (H2D %.3f + on-device %.3f), gain %.1f%%\n",
            K,mb/1e6,mSP,orig/mSP/1e6,seq,mH,mD,100.0*(seq-mSP)/seq);
        rans_check("stream-pipeline");
        ok = fnv_check("stream-pipeline") && ok;
    }
    printf("%s: %s, %d SMs, G=%d, %s\n", ok?"RESULT OK":"RESULT FAIL", prop.name, nsm, G, ok?"bit-perfect on all passes":"hash mismatch");
    // one tab-separated row for tables: archive, bytes, token coder, literal coder, tok, lit, unpack, match, on-device,
    // H2D+on-device (ms), GB/s, verdict, then the parts: lit zstd, seq, cse, gap, val, plain; unpack zstd-pack, bases, case, exceptions
    // then: stream pipeline ms (0 without --pipeline), H2D pageable GB/s, H2D pinned GB/s
    printf("ROW\t%s\t%zu\t%s\t%s\t%.3f\t%.3f\t%.3f\t%.3f\t%.3f\t%.3f\t%.2f\t%s\t%.3f\t%.3f\t%.3f\t%.3f\t%.3f\t%.3f\t%.3f\t%.3f\t%.3f\t%.3f\t%.3f\t%.1f\t%.1f\n",
        argv[1],a.size(),tmode,lmode,mT,mL,mU,mM,mD,seq,orig/mD/1e6,ok?"bit-perfect":"MISMATCH",
        mLz,mLp[P_SEQ],mLp[P_CSE],mLp[P_GAP],mLp[P_VAL],mLp[P_PLAIN],mUd,mUs,mUc,mUe,mSP,gbPg,gbPn);
    return ok?0:5;
}
