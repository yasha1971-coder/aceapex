// gpu_a1h_kernels.cuh - GPU-A1 hypotheses (measurement branch gpu-a1, never merged): variants of the windows-batch
// match kernel k_decode_list, included by src/aceapex_gpu_lib.cu only with -DAXW_PROF. The production kernel
// (decode_block in src/aceapex_gpu_kernels.cuh, variant 0) is not touched; the token parse below is a copy of it.
//   variant 1  parse only: the leader parses every token, the lanes copy nothing (timing of the serial parse;
//              the output is wrong by design and never compared)
//   variant 2  H3 / C-030: the group's output goes through a ring of R bytes in shared memory; matches whose source
//              is still in the ring read shared memory, older sources read the already written global output; the
//              ring is flushed to global memory in aligned 16*G-byte lines with 16-byte stores
// Ring invariants (variant 2), positions relative to the block start, F = flushed watermark (a multiple of 16*G):
//   - every output position < P0 (segment start) is in the ring slot p mod R or below F in global memory;
//   - a segment writes [P0, P0+seg) with seg <= S = R - 16*G; before it F > P0 - 16*G;
//   - a source s < T0 <= P0 (every source precedes its token): ring when s >= P0+seg-R (that slot is not rewritten
//     by this segment: s+R >= P0+seg), else global (s < P0+seg-R <= P0-16*G < F: already flushed);
//   - after the segment the lines [F, (P0+seg) & ~(16*G-1)) are flushed; they are all still in the ring.
#ifndef GPU_A1H_KERNELS_CUH
#define GPU_A1H_KERNELS_CUH

#define AXH_PARSE(...)                                                                                                  \
            uint32_t type=2,l=0,aux=0; const uint32_t rem=dst_size-out_pos;                                          \
            if(++steps>cmd_sz+1){ if(err && lg==0) atomicAdd(err+3,1u); break; }                                     \
            if(lg==0){ bool vb=false; while(cp<cmd_sz){ uint8_t c=cmd[cp++];                                         \
                if(c==0xFF){ rep[0]=1;rep[1]=2;rep[2]=4;rep[3]=8; continue; }                                         \
                if(c<0x80){ l=(uint32_t)c+1; if(l>lit_sz-lp||l>rem){type=2;break;} type=0; aux=lp; lp+=l; }          \
                else if((c&0xC0)==0x80){ uint32_t ri=(c>>4)&3, lv=c&0x0F; if(lv==0x0F) lv+=rd_varint(len,np,len_sz,vb); \
                    uint32_t dist=rep[ri]; if(ri>0){ for(int i=(int)ri;i>0;i--) rep[i]=rep[i-1]; rep[0]=dist; }      \
                    if(vb||(lv<0x0F&&(c&0x0F)==0x0F)){type=2;break;}                                                  \
                    if(lv>rem||lv+6>rem||!dist||dist>out_pos){type=2;break;} l=lv+6; type=1; aux=dist; }               \
                else { uint32_t lv=(c==0xFE)?rd_varint(len,np,len_sz,vb):(uint32_t)(c&0x3F); uint32_t dist=rd_varint(off,op,off_sz,vb); \
                    rep[3]=rep[2];rep[2]=rep[1];rep[1]=rep[0];rep[0]=dist;                                            \
                    if(vb||lv>rem||lv+6>rem||!dist||dist>out_pos){type=2;break;} l=lv+6; type=1; aux=dist; }           \
                break; } }                                                                                            \
            type=__shfl_sync(gmask,type,leader); l=__shfl_sync(gmask,l,leader); aux=__shfl_sync(gmask,aux,leader);  \
            if(type==2) break;

// variant 1: parse only
template<int G>
__device__ static inline void decode_block_np(const uint8_t* __restrict__ lit, const uint8_t* __restrict__ off, const uint8_t* __restrict__ len,
                                              const uint8_t* __restrict__ cmd, uint32_t lit_sz, uint32_t off_sz, uint32_t len_sz, uint32_t cmd_sz,
                                              uint8_t* __restrict__ dst, uint32_t dst_size, uint32_t lg, uint32_t leader, uint32_t gmask, uint32_t* __restrict__ err)
{
    uint32_t lp=0,op=0,np=0,cp=0,out_pos=0, rep[4]={1,2,4,8}; uint32_t steps=0;
    while(out_pos<dst_size){
        AXH_PARSE()
        if(lg==0 && l) dst[out_pos]=(uint8_t)aux;       // one store per token, so the parse is not optimized away
        __syncwarp(gmask); out_pos+=l;
    }
    if(err && lg==0 && out_pos!=dst_size) atomicAdd(err,1u);
}

// variant 2: the output through a shared-memory ring of R bytes (R a power of two, R > 16*G)
template<int G, uint32_t R>
__device__ static inline void ring_flush(uint8_t* __restrict__ dst, const uint8_t* __restrict__ ring, uint32_t a, uint32_t b, bool al16, uint32_t lg){
    if(al16){ for(uint32_t x=a+16*lg; x+16<=b; x+=16*G) *(uint4*)(dst+x)=*(const uint4*)(ring+(x&(R-1))); }
    else    { for(uint32_t x=a+lg; x<b; x+=G) dst[x]=ring[x&(R-1)]; }
}
template<int G, uint32_t R>
__device__ static inline void decode_block_ring(const uint8_t* __restrict__ lit, const uint8_t* __restrict__ off, const uint8_t* __restrict__ len,
                                                const uint8_t* __restrict__ cmd, uint32_t lit_sz, uint32_t off_sz, uint32_t len_sz, uint32_t cmd_sz,
                                                uint8_t* __restrict__ dst, uint32_t dst_size, uint32_t lg, uint32_t leader, uint32_t gmask, uint32_t* __restrict__ err,
                                                uint8_t* __restrict__ ring)
{
    constexpr uint32_t FL=16*G, S=R-FL;
    static_assert((R&(R-1))==0 && R>FL, "ring");
    const bool al16=!(((uintptr_t)dst)&15);
    uint32_t lp=0,op=0,np=0,cp=0,out_pos=0, rep[4]={1,2,4,8}; uint32_t steps=0, F=0;
    while(out_pos<dst_size){
        AXH_PARSE()
        const uint32_t T0=out_pos;
        for(uint32_t j0=0;j0<l;j0+=S){
            const uint32_t seg=min(S,l-j0), P0=T0+j0, E=P0+seg;
            for(uint32_t i=lg;i<seg;i+=G){ const uint32_t j=j0+i; uint8_t v;
                if(type==0) v=lit[aux+j];
                else { const uint32_t s=T0-aux+(aux>=l ? j : j%aux); v = (s+R>=E) ? ring[s&(R-1)] : dst[s]; }
                ring[(P0+i)&(R-1)]=v; }
            __syncwarp(gmask);
            const uint32_t Ef=E&~(FL-1);
            if(Ef>F){ ring_flush<G,R>(dst,ring,F,Ef,al16,lg); F=Ef; }
            __syncwarp(gmask);
        }
        out_pos+=l;
    }
    for(uint32_t x=F+lg; x<out_pos; x+=G) dst[x]=ring[x&(R-1)];          // the tail below one line
    __syncwarp(gmask);
    if(err && lg==0 && out_pos!=dst_size) atomicAdd(err,1u);
}
#undef AXH_PARSE

// the list kernels of the variants: the same work distribution as k_decode_list
template<int G, int V, uint32_t R, int NG>
__global__ void k_decode_list_v(const uint8_t* __restrict__ LIT, const uint8_t* __restrict__ OFF,
                                const uint8_t* __restrict__ LEN, const uint8_t* __restrict__ CMD,
                                const BlockOffsets* __restrict__ boffs, uint64_t orig_size, uint32_t block_size,
                                uint8_t* __restrict__ sbuf, const uint32_t* __restrict__ list, const uint32_t* __restrict__ dn,
                                uint32_t* __restrict__ blk_ctr, uint32_t* __restrict__ err)
{
    __shared__ __align__(16) uint8_t rings[V==2 ? NG : 1][V==2 ? R : 16];
    uint32_t lane=threadIdx.x&31, lg=lane&(G-1), leader=lane&~(uint32_t)(G-1);
    uint32_t gmask=((G==32)?0xffffffffu:((1u<<G)-1u)<<leader); const uint32_t n=*dn;
    uint8_t* ring=rings[V==2 ? threadIdx.x/G : 0];
    for(;;){
        uint32_t q=0; if(lg==0) q=atomicAdd(blk_ctr,1u); q=__shfl_sync(gmask,q,leader); if(q>=n) return;
        const uint32_t b=list[q]; BlockOffsets bo=boffs[b];
        uint64_t base=(uint64_t)b*block_size, rem=orig_size-base;
        uint32_t dst_size=(uint32_t)(rem<(uint64_t)block_size?rem:(uint64_t)block_size);
        if(V==1) decode_block_np<G>(LIT+bo.lit_off,OFF+bo.off_off,LEN+bo.len_off,CMD+bo.cmd_off,(uint32_t)bo.lit_sz,(uint32_t)bo.off_sz,(uint32_t)bo.len_sz,(uint32_t)bo.cmd_sz,
                                    sbuf+(uint64_t)q*block_size,dst_size,lg,leader,gmask,err);
        else decode_block_ring<G,R>(LIT+bo.lit_off,OFF+bo.off_off,LEN+bo.len_off,CMD+bo.cmd_off,(uint32_t)bo.lit_sz,(uint32_t)bo.off_sz,(uint32_t)bo.len_sz,(uint32_t)bo.cmd_sz,
                                    sbuf+(uint64_t)q*block_size,dst_size,lg,leader,gmask,err,ring);
    }
}
#endif
