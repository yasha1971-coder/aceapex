// aceapex_gpu_kernels.cuh - the device side of the GPU decoder, shared by the measurement tool
// (aceapex_gpu.cu) and the library (src/aceapex_gpu_lib.cu, C ABI in src/aceapex_gpu.h): block table,
// the v7-RA match kernel, the DNA-pack unpack kernels (mode 1), the one-warp rANS piece decoder
// (ADR-018) and the open DNA pack kernels (ADR-019). Steps judged on the CPU by scripts/rans_warp_emu.cpp,
// scripts/open_warp_emu.cpp and scripts/gpu_plan_emu.cpp.
#ifndef ACEAPEX_GPU_KERNELS_CUH
#define ACEAPEX_GPU_KERNELS_CUH
#include "ax_open_warp.h"   // + ax_rans_warp.h, ax_lit_open.h
#include "ax_vec.h"         // 16-byte stores (AX_VEC)
#include <cstdint>

#pragma pack(push,1)
struct BlockOffsets { uint64_t lit_off, off_off, len_off, cmd_off, lit_sz, off_sz, len_sz, cmd_sz; };
#pragma pack(pop)

// AX_VEC 1 (default): 16-byte stores (uint4) for long non-overlapping copies in the match kernel and 16 bases per
// thread in k_unpack; AX_VEC 0: the byte stores before (kept to measure both in one run)
#ifndef AX_VEC
#define AX_VEC 1
#endif
#define AXU_PER (AX_VEC ? 16 : 4)      /* bases per thread in k_unpack: grid y = ceil(chunk / AXU_PER / 256) */

// ---------------------------------------------------------------- v7-RA match kernel
// at most 5 bytes (a 32-bit value): a longer varint or one cut by the stream end sets bad (the block fails)
__device__ static inline uint32_t rd_varint(const uint8_t* buf, uint32_t& p, uint32_t limit, bool& bad){
    uint32_t val=0;
    #pragma unroll
    for(uint32_t k=0;k<5;k++){ if(p>=limit) break; const uint8_t b=buf[p++]; val|=(uint32_t)(b&0x7F)<<(7*k); if(!(b&0x80)) return val; }
    bad=true; return 0;
}
template<int G>
__global__ void k_decode_g(const uint8_t* __restrict__ LIT, const uint8_t* __restrict__ OFF,
                           const uint8_t* __restrict__ LEN, const uint8_t* __restrict__ CMD,
                           const BlockOffsets* __restrict__ boffs, uint64_t orig_size, uint32_t block_size,
                           uint8_t* __restrict__ out, uint32_t* __restrict__ blk_ctr, uint32_t blk_end,
                           uint32_t* __restrict__ err)   // err[0]: blocks that did not decode to their size, err[3]: step limit hit (nullptr: not counted)
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
        // lengths are checked against the room left (rem), never as out_pos+l: a corrupt varint near 2^32 made
        // out_pos+l wrap below dst_size and the copy run gigabytes past the block. Every token consumes a command
        // byte, so a block takes at most cmd_sz+1 steps; more is a broken invariant: err[3], stop (fail-closed)
        uint32_t steps=0;
        while(out_pos<dst_size){
            uint32_t type=2,l=0,aux=0; const uint32_t rem=dst_size-out_pos;
            if(++steps>cmd_sz+1){ if(err && lg==0) atomicAdd(err+3,1u); break; }
            if(lg==0){ bool vb=false; while(cp<cmd_sz){ uint8_t c=cmd[cp++];
                if(c==0xFF){ rep[0]=1;rep[1]=2;rep[2]=4;rep[3]=8; continue; }
                if(c<0x80){ l=(uint32_t)c+1; if(l>lit_sz-lp||l>rem){type=2;break;} type=0; aux=lp; lp+=l; }
                else if((c&0xC0)==0x80){ uint32_t ri=(c>>4)&3, lv=c&0x0F; if(lv==0x0F) lv+=rd_varint(len,np,len_sz,vb);
                    uint32_t dist=rep[ri]; if(ri>0){ for(int i=(int)ri;i>0;i--) rep[i]=rep[i-1]; rep[0]=dist; }
                    if(vb||(lv<0x0F&&(c&0x0F)==0x0F)){type=2;break;}              // bad varint / 15 + varint wrapped around
                    if(lv>rem||lv+6>rem||!dist||dist>out_pos){type=2;break;} l=lv+6; type=1; aux=dist; }
                else { uint32_t lv=(c==0xFE)?rd_varint(len,np,len_sz,vb):(uint32_t)(c&0x3F); uint32_t dist=rd_varint(off,op,off_sz,vb);
                    rep[3]=rep[2];rep[2]=rep[1];rep[1]=rep[0];rep[0]=dist;
                    if(vb||lv>rem||lv+6>rem||!dist||dist>out_pos){type=2;break;} l=lv+6; type=1; aux=dist; }
                break; } }
            type=__shfl_sync(gmask,type,leader); l=__shfl_sync(gmask,l,leader); aux=__shfl_sync(gmask,aux,leader);
            if(type==2) break;
            if(type==0){ if(AX_VEC && l>=64) axv_copy16(dst+out_pos,lit+aux,l,lg,G); else for(uint32_t i=lg;i<l;i+=G) dst[out_pos+i]=lit[aux+i]; }
            else { uint32_t src=out_pos-aux;
                if(aux>=l){ if(AX_VEC && l>=64) axv_copy16(dst+out_pos,dst+src,l,lg,G); else for(uint32_t i=lg;i<l;i+=G) dst[out_pos+i]=dst[src+i]; }
                else      { for(uint32_t i=lg;i<l;i+=G) dst[out_pos+i]=dst[src+(i%aux)]; } }
            __syncwarp(gmask); out_pos+=l;
        }
        if(err && lg==0 && out_pos!=dst_size) atomicAdd(err,1u);
    }
}
typedef void (*kern_t)(const uint8_t*,const uint8_t*,const uint8_t*,const uint8_t*,const BlockOffsets*,uint64_t,uint32_t,uint8_t*,uint32_t*,uint32_t,uint32_t*);

// ---------------------------------------------------------------- DNA unpack kernels
struct DnaDesc { const uint8_t *seq,*cse,*gap,*val; uint8_t* dst; uint64_t raw; uint32_t nexc, res; };
__global__ void k_unpack(const DnaDesc* d){
    const DnaDesc c=d[blockIdx.x]; const uint64_t i0=((uint64_t)blockIdx.y*blockDim.x+threadIdx.x)*AXU_PER; if(i0>=c.raw) return;
#if AX_VEC
    if(i0+16<=c.raw && !(((uintptr_t)(c.dst+i0))&15)){        // 16 bases: 4 packed bytes, 2 case bytes, one uint4 store
        uint32_t w[4]; axv_unpack16(c.seq,c.cse,i0,w); axv_store16(c.dst+i0,w[0],w[1],w[2],w[3]); return; }
#endif
    for(uint64_t i=i0;i<i0+AXU_PER && i<c.raw;i++){ const uint8_t v=c.seq[i>>2]; uint8_t b="ACGT"[(v>>(6-2*(i&3)))&3]; if(c.cse[i>>3]&(0x80>>(i&7))) b|=0x20; c.dst[i]=b; }
}
__global__ void k_exc(const DnaDesc* d){
    const DnaDesc c=d[blockIdx.x]; if(!c.nexc) return; __shared__ uint32_t s[256]; uint64_t carry=0;
    for(uint32_t base=0; base<c.nexc; base+=256){
        uint32_t e=base+threadIdx.x; uint32_t g = e<c.nexc ? ((const uint32_t*)c.gap)[e] : 0; s[threadIdx.x]=g; __syncthreads();
        for(uint32_t o=1;o<256;o<<=1){ uint32_t t = threadIdx.x>=o ? s[threadIdx.x-o] : 0; __syncthreads(); s[threadIdx.x]+=t; __syncthreads(); }
        const uint64_t pos=carry+s[threadIdx.x]; if(e<c.nexc && pos<c.raw) c.dst[pos] = c.val ? c.val[e] : 0;
        carry+=s[255]; __syncthreads(); }
}
// ---------------------------------------------------------------- rANS token chunks (ADR-018)
// One warp decodes one chunk: the steps of src/ax_rans_warp.h (judged on the CPU by
// scripts/rans_warp_emu.cpp) with the warp collectives between them. The chunk bytes are in
// the compressed buffer next to the zstd frames; the output goes into the stream buffer.
// err[0] counts bad chunks, err[1] holds the lowest bad chunk index. A piece of the open
// literal profile (spec 3.4) with mode 0 is a raw copy: the warp copies it.
struct RansDesc { uint64_t src; uint8_t* dst; uint64_t n; uint32_t csz, mode, cls, res; };   // n <= AXW_MAXN (checked)
#define AXW_MAXN 0xFFFFFF00ull
#define AXW_WARPS 4
__device__ static inline uint32_t w_scan(uint32_t v, uint32_t lane, uint32_t& total){
    uint32_t inc=v;
    #pragma unroll
    for(int o=1;o<32;o<<=1){ uint32_t t=__shfl_up_sync(0xffffffffu,inc,o); if(lane>=(uint32_t)o) inc+=t; }
    total=__shfl_sync(0xffffffffu,inc,31); return inc-v;
}
// one warp decodes one piece/chunk into dst (global or shared); returns true (warp-uniform) on a bad chunk.
// V 0: refill word loaded from global memory in the step (axw_refill); V 1: from a 64-word register window
// (axw_wload / axw_refill_v, AX_OPEN_SEQ): same bytes
template<int V=0>
__device__ static bool rans_warp(const uint8_t* __restrict__ src, uint32_t csz, uint32_t n, uint32_t mode, uint8_t* dst, AxwShared& sh, uint32_t lane){
    const uint32_t FULL=0xffffffffu, lt=(1u<<lane)-1u;
    if(mode==0){ for(uint32_t i=lane;i<n;i+=32) dst[i]=src[i]; return false; }   // raw piece (sizes checked on the host)
    bool b=false, bad=csz<AXW_MIN; uint32_t cb=0;
    if(!bad){
        axw_stage(lane,src,csz,sh); __syncwarp();
        uint32_t K; const uint32_t r0=w_scan(axw_rank_count(lane,sh),lane,K);
        axw_rank_write(lane,sh,r0); __syncwarp();
        const uint32_t lim=axw_lim(csz); uint32_t jb=0;
        for(uint32_t r=0; jb<K && 32+32*r<lim; r++){
            const bool t=axw_term(lane,sh,r,lim); const uint32_t m=__ballot_sync(FULL,t);
            axw_leb(lane,sh,r,t,jb+__popc(m&lt),K,b); jb+=__popc(m); }
        b|= jb<K; __syncwarp();
        uint32_t tot; cb=w_scan(axw_sum(lane,sh),lane,tot); b|= tot!=AXR_M;
        bad=__any_sync(FULL,b);
    }
    if(!bad){
        axw_cum(lane,sh,cb); __syncwarp(); axw_fill(lane,sh); __syncwarp();
        uint32_t x,W; const uint8_t* words; b|=axw_init(lane,src,csz,sh.end,x,W,words); bad=__any_sync(FULL,b);
        if(!bad && V==0){
            uint32_t base=0; const uint32_t groups=(n+31)/32;
            for(uint32_t g=0; g<groups; g++){
                const bool need=axw_step(lane,sh,g,n,x,dst); const uint32_t m=__ballot_sync(FULL,need);
                axw_refill(lane,need,m,base,W,words,x,b); base+=__popc(m); }
            b|= base!=W || x!=AXR_L; bad=__any_sync(FULL,b);
        }
        else if(!bad){
            uint32_t base=0, wb=0, w0=axw_wload(words,W,lane), w1=axw_wload(words,W,32+lane); const uint32_t groups=(n+31)/32;
            for(uint32_t g=0; g<groups; g++){
                const bool need=axw_step(lane,sh,g,n,x,dst); const uint32_t m=__ballot_sync(FULL,need);
                const uint32_t idx=axw_widx(lane,m,base), o=idx-wb;
                const uint32_t v0=__shfl_sync(FULL,w0,o&31), v1=__shfl_sync(FULL,w1,o&31);
                axw_refill_v(need,idx,W,o<32?v0:v1,x,b); base+=__popc(m);
                if(base>=wb+32){ wb+=32; w0=w1; w1=axw_wload(words,W,wb+32+lane); } }
            b|= base!=W || x!=AXR_L; bad=__any_sync(FULL,b);
        }
    }
    return bad;
}
template<int V=0>
__global__ void __launch_bounds__(32*AXW_WARPS) k_rans(const uint8_t* __restrict__ C, const RansDesc* __restrict__ d, uint32_t nd, uint32_t* __restrict__ err){
    __shared__ AxwShared sh_all[AXW_WARPS];
    const uint32_t lane=threadIdx.x&31, k=blockIdx.x*AXW_WARPS+(threadIdx.x>>5);
    if(k>=nd) return;                                   // whole warp: nd is uniform
    const RansDesc c=d[k];
    const bool bad= c.n>AXW_MAXN || rans_warp<V>(C+c.src,c.csz,(uint32_t)c.n,c.mode,c.dst,sh_all[threadIdx.x>>5],lane);
    if(bad && lane==0){ atomicAdd(err,1u); atomicMin(err+1,k); }
}

// ---------------------------------------------------------------- open DNA pack (ADR-019, spec 3.4)
// After the pieces are decoded into the open scratch: the case runs are parsed into run ends
// (k_open_cse, one block per chunk), the bases are written with their case (k_open_bases,
// 16 positions per thread, binary search over the run ends), then the exceptions (k_open_exc,
// one block per chunk). Steps in src/ax_open_warp.h, judged on the CPU by
// scripts/open_warp_emu.cpp. err[0] counts bad chunks, err[1] the lowest index; a bad chunk
// stores 0 runs.
struct OpenDesc { const uint8_t *seq,*cse,*gap,*val; uint8_t* dst; uint32_t* ends; uint32_t* nrun; uint64_t raw; uint32_t ncse, ngap, nexc, res; };
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
    bool bad= c.raw>AXW_MAXN; uint64_t carry=0; uint32_t jb=0;
    const uint32_t raw=(uint32_t)(bad?0:c.raw);
    for(uint32_t base=0; base<n; base+=AXO_NT){
        const uint32_t t=base+tid; const bool term=axl_term(t,b,n); const uint32_t v=axl_value(t,b,term,bad);
        uint64_t total; const uint64_t ex=b_scan64(term?(AXO_KEY_J|v):0,total,sh);
        axl_cse_end(term,jb+(uint32_t)(ex>>44),v,carry+(ex&(AXO_KEY_J-1))+v,raw,c.ends,bad);
        jb+=(uint32_t)(total>>44); carry+=total&(AXO_KEY_J-1);
    }
    if(tid==0 && (axl_tail_bad(b,n) || carry!=c.raw)) bad=true;   // also k_open_bases/k_open_exc see 0 runs
    __syncwarp();
    const int any=__syncthreads_or(bad);
    if(tid==0){ *c.nrun = any?0:jb; if(any){ atomicAdd(err,1u); atomicMin(err+1,k); } }
}
__global__ void __launch_bounds__(256) k_open_bases(const OpenDesc* __restrict__ d){
    const OpenDesc c=d[blockIdx.x]; const uint32_t g=blockIdx.y*blockDim.x+threadIdx.x; const uint32_t R=*c.nrun;
    if(R && 16ull*g<c.raw) axl_bases16(g,c.seq,c.ends,R,(uint32_t)c.raw,c.dst);   // R = 0: a bad chunk (k_open_cse), nothing written
}
// AX_OPEN_BASES / AX_OPEN_EXC (ax_open_warp.h, variants): lanes 0 and 1 find the runs at the first and last
// position of the warp's 512, lanes 2 and 3 the exceptions there (X 1), every lane searches between them; X 1 puts
// the exceptions (positions from k_open_cg) into the 16-byte store. epos/eoff: exception positions of all chunks,
// chunk k's from eoff[k].
template<int X>
__global__ void __launch_bounds__(256) k_open_bases_v(const OpenDesc* __restrict__ d, const uint32_t* __restrict__ epos_all, const uint64_t* __restrict__ eoff){
    const OpenDesc c=d[blockIdx.x]; const uint32_t lane=threadIdx.x&31, g=blockIdx.y*blockDim.x+threadIdx.x; const uint32_t R=*c.nrun;
    if(!R || c.raw>AXW_MAXN) return;                                   // block-uniform: a chunk k_open_cse rejected
    const uint32_t raw=(uint32_t)c.raw, first=16*(g-lane);
    if(first>=raw) return;                                             // warp-uniform
    const uint32_t last=min(first+511u,raw-1);
    const uint32_t* ep = X ? epos_all+eoff[blockIdx.x] : nullptr; const uint32_t ne = X ? c.nexc : 0;
    uint32_t t=0;
    if(lane==0) t=axl_run_of(c.ends,R,first); else if(lane==1) t=axl_run_of(c.ends,R,last);
    else if(X && lane==2) t=axl_exc_in(ep,0,ne,first); else if(X && lane==3) t=axl_exc_in(ep,0,ne,last+1);
    const uint32_t jlo=__shfl_sync(0xffffffffu,t,0), jhi=__shfl_sync(0xffffffffu,t,1), elo=__shfl_sync(0xffffffffu,t,2), ehi=__shfl_sync(0xffffffffu,t,3);
    const uint32_t i0=16*g; if(i0>=raw) return;
    const uint32_t j=axl_run_in(c.ends,jlo,jhi,i0);
    axl_bases16_v(g,c.seq,c.ends,R,raw,c.dst,j, ep, X?ehi:0, c.val, X?axl_exc_in(ep,elo,ehi,i0):0);
}
// AX_OPEN_EXC: case runs (as k_open_cse) and then, in the same block, the exception positions (the parse of
// k_open_exc writing epos instead of the bytes); k_open_bases_v<1> writes the bytes
__global__ void __launch_bounds__(AXO_NT) k_open_cg(const OpenDesc* __restrict__ d, uint32_t* __restrict__ epos_all, const uint64_t* __restrict__ eoff, uint32_t* __restrict__ err){
    __shared__ uint64_t sh[AXO_NT/32];
    const uint32_t k=blockIdx.x, tid=threadIdx.x; const OpenDesc c=d[k];
    bool bad= c.raw>AXW_MAXN; const uint32_t raw=(uint32_t)(bad?0:c.raw);
    { const uint8_t* b=c.cse; const uint32_t n=c.ncse; uint64_t carry=0; uint32_t jb=0;
      for(uint32_t base=0; base<n; base+=AXO_NT){
          const uint32_t t=base+tid; const bool term=axl_term(t,b,n); const uint32_t v=axl_value(t,b,term,bad);
          uint64_t total; const uint64_t ex=b_scan64(term?(AXO_KEY_J|v):0,total,sh);
          axl_cse_end(term,jb+(uint32_t)(ex>>44),v,carry+(ex&(AXO_KEY_J-1))+v,raw,c.ends,bad);
          jb+=(uint32_t)(total>>44); carry+=total&(AXO_KEY_J-1); }
      if(tid==0 && (axl_tail_bad(b,n) || carry!=c.raw)) bad=true;
      __syncwarp();
      const int any=__syncthreads_or(bad);
      if(tid==0){ *c.nrun = any?0:jb; if(any){ atomicAdd(err,1u); atomicMin(err+1,k); } }
      if(any) return; }                                                // block-uniform
    if(!c.nexc) return;
    { const uint8_t* b=c.gap; const uint32_t n=c.ngap; uint32_t* ep=epos_all+eoff[k]; uint64_t carry=0; uint32_t jb=0;
      for(uint32_t base=0; base<n; base+=AXO_NT){
          const uint32_t t=base+tid; const bool term=axl_term(t,b,n); const uint32_t v=axl_value(t,b,term,bad);
          uint64_t total; const uint64_t ex=b_scan64(term?(AXO_KEY_J|v):0,total,sh);
          axl_exc_pos(term,jb+(uint32_t)(ex>>44),v,carry+(ex&(AXO_KEY_J-1))+v,c.nexc,raw,ep,bad);
          jb+=(uint32_t)(total>>44); carry+=total&(AXO_KEY_J-1); }
      if(tid==0 && (axl_tail_bad(b,n) || jb!=c.nexc)) bad=true;
      __syncwarp();
      const int any=__syncthreads_or(bad);
      if(tid==0 && any){ atomicAdd(err,1u); atomicMin(err+1,k); } }
}

// Fused seq piece + bases (literal chunks <= 64 KiB): warp 0 decodes the chunk's seq piece (2-bit pack,
// <= 16 KiB) into shared memory instead of the global scratch, then the block writes bases with their
// case straight into the literal stream: the packed bases never leave the SM and k_open_bases is not
// launched. Needs the run ends of k_open_cse (as k_open_bases). err as k_rans (piece index k).
#define AXO_FSEQ 16384
__global__ void __launch_bounds__(256) k_open_seqb(const uint8_t* __restrict__ C, const RansDesc* __restrict__ sd, const OpenDesc* __restrict__ d, uint32_t* __restrict__ err){
    __shared__ AxwShared sh; __shared__ __align__(16) uint8_t sq[AXO_FSEQ]; __shared__ int bad_s;
    const uint32_t k=blockIdx.x, tid=threadIdx.x; const OpenDesc c=d[k];
    if(tid<32){ const RansDesc r=sd[k]; const bool bad = r.n>AXO_FSEQ || rans_warp(C+r.src,r.csz,(uint32_t)r.n,r.mode,sq,sh,tid);
        if(tid==0){ bad_s=bad; if(bad){ atomicAdd(err,1u); atomicMin(err+1,k); } } }
    __syncthreads();
    if(bad_s) return;
    const uint32_t R=*c.nrun;
    for(uint32_t g=tid; 16ull*g<c.raw && c.raw<=AXO_FSEQ*4; g+=256) axl_bases16(g,sq,c.ends,R,(uint32_t)c.raw,c.dst);
}
__global__ void __launch_bounds__(AXO_NT) k_open_exc(const OpenDesc* __restrict__ d, uint32_t* __restrict__ err){
    __shared__ uint64_t sh[AXO_NT/32];
    const uint32_t k=blockIdx.x, tid=threadIdx.x; const OpenDesc c=d[k]; if(!c.nexc || !*c.nrun) return;   // uniform per block; 0 runs: bad chunk, counted by k_open_cse
    const uint8_t* b=c.gap; const uint32_t n=c.ngap;
    bool bad=false; uint64_t carry=0; uint32_t jb=0;
    for(uint32_t base=0; base<n; base+=AXO_NT){
        const uint32_t t=base+tid; const bool term=axl_term(t,b,n); const uint32_t v=axl_value(t,b,term,bad);
        uint64_t total; const uint64_t ex=b_scan64(term?(AXO_KEY_J|v):0,total,sh);
        axl_exc(term,jb+(uint32_t)(ex>>44),v,carry+(ex&(AXO_KEY_J-1))+v,c.nexc,(uint32_t)c.raw,c.val,c.dst,bad);
        jb+=(uint32_t)(total>>44); carry+=total&(AXO_KEY_J-1);
    }
    if(tid==0 && (axl_tail_bad(b,n) || jb!=c.nexc)) bad=true;
    __syncwarp();
    const int any=__syncthreads_or(bad);
    if(tid==0 && any){ atomicAdd(err,1u); atomicMin(err+1,k); }
}


#endif
