#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <time.h>
#include <pthread.h>
#include <atomic>
#include <vector>
#include <algorithm>
#include <zstd.h>
// Windows compatibility
#ifdef _WIN32
#include <malloc.h>
static inline void* aligned_alloc(size_t align, size_t size) {
    return _aligned_malloc(size, align);
}
static inline void aligned_free(void* ptr) { _aligned_free(ptr); }
#else
static inline void aligned_free(void* ptr) { free(ptr); }
#endif
 
// ACEAPEX v3 — v2 + lazy matching for better ratio
//
// Global zstd compression (full context = best ratio)
// + Per-block stream offsets (parallel LZ77 decode = max speed)
// This combination has never been done before.
 
#define HASH_SIZE    0x1FFF
#define MAX_DIST     (128 * 1024 * 1024)
#define BLOCK_SIZE   (32 * 1024)
#define MAX_THREADS  16
#define BLOCK_MARKER 0xFF
#define ZSTD_LEVEL   22
 
struct BlockResult {
    uint8_t* lit_buf; uint8_t* off_buf;
    uint8_t* len_buf; uint8_t* cmd_buf;
    size_t   lit_size, off_size, len_size, cmd_size;
    int      overflow;
};
 
struct PoolState {
    const uint8_t* src; size_t src_size;
    size_t num_blocks; BlockResult* results;
    std::atomic<size_t> next_block;
};
 
struct WorkerArgs {
    int thread_id;
    struct ThreadHashTable* htab;
    PoolState* pool;
};
 
struct ThreadHashTable {
    int32_t  pos  [HASH_SIZE + 1];
    uint32_t epoch[HASH_SIZE + 1];
    uint32_t cur_epoch;
} __attribute__((aligned(64)));
 
// Per-block stream offsets for parallel decode
struct BlockOffsets {
    uint64_t lit_off, off_off, len_off, cmd_off;
    uint64_t lit_sz,  off_sz,  len_sz,  cmd_sz;
};
 
static inline void wv(uint8_t* buf, size_t& ptr, uint32_t val,
                      size_t limit, int& ov, int sid) {
    while (val >= 0x80) {
        if (ptr >= limit) { ov=sid; return; }
        buf[ptr++] = (uint8_t)((val & 0x7F) | 0x80); val >>= 7;
    }
    if (ptr >= limit) { ov=sid; return; }
    buf[ptr++] = (uint8_t)val;
}
 
static inline uint32_t min_match_len(uint32_t dist) {
    if (dist < 128)     return 6;
    if (dist < 16384)   return 8;
    if (dist < 2097152) return 10;
    return 12;
}
 
static void compress_block(const uint8_t* src, size_t src_size,
                            size_t bstart, size_t bend,
                            ThreadHashTable* ht, BlockResult* res) {
    size_t bsz = bend - bstart;
    size_t cap = bsz * 2 + 1024;
    res->lit_buf = (uint8_t*)malloc(cap);
    res->off_buf = (uint8_t*)malloc(cap * 6);
    res->len_buf = (uint8_t*)malloc(cap * 6);
    res->cmd_buf = (uint8_t*)malloc(cap + cap/4 + 4);
    res->overflow = 0;
    size_t lit_cap=cap, off_cap=cap*6, len_cap=cap*6, cmd_cap=cap+cap/4+4;
 
    ht->cur_epoch++;
    if (ht->cur_epoch == 0) {
        memset(ht->epoch, 0, sizeof(ht->epoch)); ht->cur_epoch = 1;
    }
 
    size_t lit_i=0, off_i=0, len_i=0, cmd_i=0, pos=bstart;
    uint32_t rep[4]={1,2,4,8}, lit_run=0, miss=0;
    int ov=0;
    res->cmd_buf[cmd_i++] = BLOCK_MARKER;
 
    auto flush_lit = [&]() {
        while (lit_run > 0 && !ov) {
            uint32_t chunk = (lit_run > 128) ? 128 : lit_run;
            if (cmd_i >= cmd_cap) { ov=4; return; }
            res->cmd_buf[cmd_i++] = (uint8_t)(chunk-1);
            lit_run -= chunk;
        }
    };
 
    while (pos + 12 < bend && !ov) {
        uint32_t c_len=0, c_off=0; int c_rep=-1;
        bool do_rep = (miss < 16) || (miss < 64 && (miss&1)==0) || (miss>=64 && (miss&3)==0);
        if (do_rep) {
            for (int i=0; i<4; i++) {
                uint32_t d=rep[i];
                if (pos < bstart+d) continue;
                if (*(uint32_t*)(src+pos) != *(uint32_t*)(src+pos-d)) continue;
                uint32_t l=4, maxl=(uint32_t)(bend-pos);
                while (l<maxl && src[pos+l]==src[pos-d+l] && l<65535) l++;
                if (l>=6 && l>c_len) { c_len=l; c_off=d; c_rep=i; }
            }
        }
        uint32_t h=((*(uint32_t*)(src+pos)*0x9E3779B1u)>>10)&HASH_SIZE;
        int32_t mp=(ht->epoch[h]==ht->cur_epoch)?ht->pos[h]:-1;
        ht->pos[h]=(int32_t)pos; ht->epoch[h]=ht->cur_epoch;
        if (mp>=0 && (size_t)mp>=bstart && (size_t)mp<pos) {
            uint32_t dist=(uint32_t)(pos-mp);
            if (dist<MAX_DIST && dist!=rep[0]) {
                uint32_t mlen=min_match_len(dist);
                uint32_t maxl=(uint32_t)(bend-pos);
                if (pos+8<=bend && *(uint64_t*)(src+pos)==*(uint64_t*)(src+mp)) {
                    uint32_t l=8;
                    while (l<maxl && src[pos+l]==src[mp+l] && l<65535) l++;
                    if (l>=mlen && l>c_len) { c_len=l; c_off=dist; c_rep=-1; }
                } else if (*(uint32_t*)(src+pos)==*(uint32_t*)(src+mp)) {
                    uint32_t l=4;
                    while (l<maxl && src[pos+l]==src[mp+l] && l<65535) l++;
                    if (l>=mlen && dist<4096 && l>c_len) { c_len=l; c_off=dist; c_rep=-1; }
                }
            }
        }
        // Lazy matching: if pos+1 gives better match, emit literal at pos
        if (c_len >= 6 && c_len < 64 && pos+13 < bend) {
            uint32_t h1=((*(uint32_t*)(src+pos+1)*0x9E3779B1u)>>10)&HASH_SIZE;
            int32_t mp1=(ht->epoch[h1]==ht->cur_epoch)?ht->pos[h1]:-1;
            if (mp1>=0 && (size_t)mp1>=bstart && (size_t)mp1<pos+1) {
                uint32_t dist1=(uint32_t)(pos+1-mp1);
                if (dist1<MAX_DIST && dist1!=rep[0]) {
                    uint32_t mlen1=min_match_len(dist1);
                    uint32_t maxl1=(uint32_t)(bend-pos-1);
                    if (pos+9<=bend && *(uint64_t*)(src+pos+1)==*(uint64_t*)(src+mp1)) {
                        uint32_t l1=8;
                        while (l1<maxl1 && src[pos+1+l1]==src[mp1+l1] && l1<65535) l1++;
                        if (l1 >= mlen1 && l1 > c_len + 1) {
                            // pos+1 is better — take literal at pos, match at pos+1
                            if (lit_i < lit_cap) {
                                res->lit_buf[lit_i++]=src[pos]; lit_run++; miss++;
                                pos++;
                                c_len=l1; c_off=dist1; c_rep=-1;
                            }
                        }
                    }
                }
            }
        }
        if (c_len >= 6) {
            flush_lit(); if (ov) break; miss=0;
            uint32_t lv=c_len-6;
            if (c_rep != -1) {
                if (cmd_i>=cmd_cap) { ov=4; break; }
                if (lv<15) { res->cmd_buf[cmd_i++]=(uint8_t)(0x80|(c_rep<<4)|lv); }
                else { res->cmd_buf[cmd_i++]=(uint8_t)(0x80|(c_rep<<4)|0x0F);
                       wv(res->len_buf,len_i,lv-15,len_cap,ov,3); if(ov) break; }
                uint32_t rd=rep[c_rep];
                for (int i=c_rep;i>0;i--) rep[i]=rep[i-1]; rep[0]=rd;
            } else {
                if (cmd_i>=cmd_cap) { ov=4; break; }
                if (lv<62) { res->cmd_buf[cmd_i++]=(uint8_t)(0xC0|lv); }
                else { res->cmd_buf[cmd_i++]=0xFE;
                       wv(res->len_buf,len_i,lv,len_cap,ov,3); if(ov) break; }
                wv(res->off_buf,off_i,c_off,off_cap,ov,2); if(ov) break;
                rep[3]=rep[2]; rep[2]=rep[1]; rep[1]=rep[0]; rep[0]=c_off;
            }
            pos+=c_len; continue;
        }
        if (lit_i>=lit_cap) { ov=1; break; }
        res->lit_buf[lit_i++]=src[pos++]; lit_run++; miss++;
        if (miss>=1 && pos+12<bend) {
            uint32_t hh=((*(uint32_t*)(src+pos)*0x9E3779B1u)>>10)&HASH_SIZE;
            ht->pos[hh]=(int32_t)pos; ht->epoch[hh]=ht->cur_epoch;
            if (lit_i>=lit_cap) { ov=1; break; }
            res->lit_buf[lit_i++]=src[pos++]; lit_run++;
        }
    }
    if (!ov) {
        while (pos<bend) {
            if (lit_i>=lit_cap) { ov=1; break; }
            res->lit_buf[lit_i++]=src[pos++]; lit_run++;
        }
        flush_lit();
    }
    res->lit_size=lit_i; res->off_size=off_i;
    res->len_size=len_i; res->cmd_size=cmd_i; res->overflow=ov;
}
 
static void* worker_func(void* arg) {
    WorkerArgs* wa=(WorkerArgs*)arg;
    PoolState*  ps=wa->pool;
    while (true) {
        size_t bid=ps->next_block.fetch_add(1);
        if (bid>=ps->num_blocks) break;
        size_t bstart=bid*BLOCK_SIZE, bend=bstart+BLOCK_SIZE;
        if (bend>ps->src_size) bend=ps->src_size;
        compress_block(ps->src,ps->src_size,bstart,bend,wa->htab,&ps->results[bid]);
    }
    return nullptr;
}
 
// Optimized decoder
static inline void copy_match(uint8_t* dst, size_t out_ptr, uint32_t dist, uint32_t len) {
    uint8_t* d = dst + out_ptr;
    const uint8_t* s = dst + out_ptr - dist;
    if (__builtin_expect(dist >= len, 1)) { memcpy(d, s, len); return; }
    if (dist == 1) { memset(d, s[0], len); return; }
    uint32_t done = 0;
    while (done + dist <= len) { memcpy(d + done, s, dist); done += dist; }
    if (done < len) memcpy(d + done, s, len - done);
}
 
static inline uint32_t read_varint(const uint8_t* buf, size_t& ptr, size_t limit) {
    if (__builtin_expect(ptr < limit, 1)) {
        uint8_t b0 = buf[ptr];
        if (__builtin_expect(!(b0 & 0x80), 1)) { ptr++; return b0; }
        if (__builtin_expect(ptr + 1 < limit, 1)) {
            uint8_t b1 = buf[ptr+1];
            if (__builtin_expect(!(b1 & 0x80), 1)) {
                ptr += 2;
                return (uint32_t)(b0 & 0x7F) | ((uint32_t)b1 << 7);
            }
        }
    }
    uint32_t val=0, shift=0;
    while (ptr<limit) {
        uint8_t b=buf[ptr++]; val|=(uint32_t)(b&0x7F)<<shift;
        if (!(b&0x80)) return val; shift+=7;
    }
    return val;
}
 
static void decompress_streams(
    uint8_t* dst, size_t dst_size,
    const uint8_t* lit, size_t lit_sz,
    const uint8_t* off, size_t off_sz,
    const uint8_t* len, size_t len_sz,
    const uint8_t* cmd, size_t cmd_sz)
{
    size_t lp=0, op=0, np=0, cp=0, out=0;
    uint32_t rep[4]={1,2,4,8};
    while (out<dst_size && cp<cmd_sz) {
        uint8_t c=cmd[cp++];
        if (c==0xFF) { rep[0]=1;rep[1]=2;rep[2]=4;rep[3]=8; continue; }
        if (c<0x80) {
            uint32_t l=c+1;
            if (lp+l>lit_sz||out+l>dst_size) break;
            memcpy(dst+out,lit+lp,l); out+=l; lp+=l;
        } else if ((c&0xC0)==0x80) {
            uint32_t ri=(c>>4)&3, lv=c&0x0F;
            if (lv==0x0F) lv+=read_varint(len,np,len_sz);
            uint32_t l=lv+6, dist=rep[ri];
            if (ri>0) { for(int i=ri;i>0;i--) rep[i]=rep[i-1]; rep[0]=dist; }
            if (!dist||out+l>dst_size) break;
            copy_match(dst,out,dist,l); out+=l;
        } else {
            uint32_t lv=(c==0xFE)?read_varint(len,np,len_sz):(uint32_t)(c&0x3F);
            uint32_t l=lv+6, dist=read_varint(off,op,off_sz);
            rep[3]=rep[2];rep[2]=rep[1];rep[1]=rep[0];rep[0]=dist;
            if (!dist||out+l>dst_size) break;
            copy_match(dst,out,dist,l); out+=l;
        }
    }
}
 
// SHA-256
static const uint32_t K256[64] = {
    0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
    0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
    0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
    0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
    0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
    0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
    0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
    0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
};
 
static void sha256(const uint8_t* data, size_t len, uint8_t out[32]) {
    uint32_t h[8]={0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,
                   0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19};
    auto ror=[](uint32_t x,int n){ return (x>>n)|(x<<(32-n)); };
    size_t total=(len+9+63)&~63ULL;
    uint8_t* buf=(uint8_t*)calloc(total,1);
    memcpy(buf,data,len); buf[len]=0x80;
    uint64_t bits=(uint64_t)len*8;
    for(int i=0;i<8;i++) buf[total-1-i]=(uint8_t)(bits>>(i*8));
    for(size_t off=0;off<total;off+=64) {
        uint32_t w[64];
        for(int i=0;i<16;i++)
            w[i]=((uint32_t)buf[off+i*4]<<24)|((uint32_t)buf[off+i*4+1]<<16)|
                 ((uint32_t)buf[off+i*4+2]<<8)|(uint32_t)buf[off+i*4+3];
        for(int i=16;i<64;i++) {
            uint32_t s0=ror(w[i-15],7)^ror(w[i-15],18)^(w[i-15]>>3);
            uint32_t s1=ror(w[i-2],17)^ror(w[i-2],19)^(w[i-2]>>10);
            w[i]=w[i-16]+s0+w[i-7]+s1;
        }
        uint32_t a=h[0],b=h[1],c=h[2],d=h[3],e=h[4],f=h[5],g=h[6],hh=h[7];
        for(int i=0;i<64;i++) {
            uint32_t S1=ror(e,6)^ror(e,11)^ror(e,25);
            uint32_t ch=(e&f)^(~e&g);
            uint32_t t1=hh+S1+ch+K256[i]+w[i];
            uint32_t S0=ror(a,2)^ror(a,13)^ror(a,22);
            uint32_t maj=(a&b)^(a&c)^(b&c);
            uint32_t t2=S0+maj;
            hh=g;g=f;f=e;e=d+t1;d=c;c=b;b=a;a=t1+t2;
        }
        h[0]+=a;h[1]+=b;h[2]+=c;h[3]+=d;h[4]+=e;h[5]+=f;h[6]+=g;h[7]+=hh;
    }
    free(buf);
    for(int i=0;i<8;i++) {
        out[i*4+0]=(uint8_t)(h[i]>>24); out[i*4+1]=(uint8_t)(h[i]>>16);
        out[i*4+2]=(uint8_t)(h[i]>>8);  out[i*4+3]=(uint8_t)(h[i]);
    }
}
 
static void sha256_hex(const uint8_t* data, size_t len, char out[65]) {
    uint8_t d[32]; sha256(data,len,d);
    for(int i=0;i<32;i++) sprintf(out+i*2,"%02x",d[i]); out[64]=0;
}
 
static uint8_t* zstd_comp(const uint8_t* src, size_t sz, size_t& out_sz, int lv) {
    size_t b=ZSTD_compressBound(sz); uint8_t* buf=(uint8_t*)malloc(b);
    out_sz=ZSTD_compress(buf,b,src,sz,lv);
    if (ZSTD_isError(out_sz)) { free(buf); out_sz=0; return nullptr; }
    return buf;
}
 
#pragma pack(push,1)
struct AetHeader {
    char     magic[8];   // "ACEPX2\0\0"
    uint32_t version;    // 2
    uint64_t orig_size;
    uint32_t block_size;
    uint32_t num_blocks;
    uint8_t  sha256[32];
    uint64_t zlit_sz, zoff_sz, zlen_sz, zcmd_sz; // global stream sizes
};
#pragma pack(pop)
 
static double now_sec() {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t);
    return t.tv_sec + t.tv_nsec*1e-9;
}
 
// Parallel decode worker — uses global streams with per-block offsets
struct DecArgs {
    const uint8_t* lit; const uint8_t* off;
    const uint8_t* len; const uint8_t* cmd;
    const BlockOffsets* boffs;
    uint8_t* dst; size_t dst_size;
    size_t bid_start; size_t bid_end;
    size_t block_size;
};
 
static void* dec_worker(void* arg) {
    DecArgs* a = (DecArgs*)arg;
    for (size_t b = a->bid_start; b < a->bid_end; b++) {
        const BlockOffsets& bo = a->boffs[b];
        size_t bstart = b * a->block_size;
        size_t bsize  = a->dst_size > bstart ?
                        std::min(a->block_size, a->dst_size - bstart) : 0;
        if (bsize > 0)
            decompress_streams(
                a->dst + bstart, bsize,
                a->lit + bo.lit_off, bo.lit_sz,
                a->off + bo.off_off, bo.off_sz,
                a->len + bo.len_off, bo.len_sz,
                a->cmd + bo.cmd_off, bo.cmd_sz);
    }
    return nullptr;
}
 
// Common encode path — returns global streams + per-block offsets
static bool encode_file(const uint8_t* src, size_t src_size, int threads,
    std::vector<BlockOffsets>& boffs,
    uint8_t*& raw_lit, size_t& total_lit,
    uint8_t*& raw_off, size_t& total_off,
    uint8_t*& raw_len, size_t& total_len,
    uint8_t*& raw_cmd, size_t& total_cmd,
    double& enc_time, size_t& num_blocks)
{
    num_blocks = (src_size + BLOCK_SIZE - 1) / BLOCK_SIZE;
    boffs.resize(num_blocks);
 
    ThreadHashTable** htabs=(ThreadHashTable**)calloc(threads,sizeof(void*));
    for(int i=0;i<threads;i++) {
        htabs[i]=(ThreadHashTable*)aligned_alloc(64,sizeof(ThreadHashTable));
        memset(htabs[i]->epoch,0,sizeof(htabs[i]->epoch));
        htabs[i]->cur_epoch=0;
    }
    BlockResult* results=(BlockResult*)calloc(num_blocks,sizeof(BlockResult));
    PoolState pool;
    pool.src=src; pool.src_size=src_size;
    pool.num_blocks=num_blocks; pool.results=results;
    pool.next_block.store(0);
    WorkerArgs* wargs=(WorkerArgs*)calloc(threads,sizeof(WorkerArgs));
    pthread_t* pts=(pthread_t*)calloc(threads,sizeof(pthread_t));
    for(int i=0;i<threads;i++) {
        wargs[i].thread_id=i; wargs[i].htab=htabs[i]; wargs[i].pool=&pool;
        pthread_create(&pts[i],nullptr,worker_func,&wargs[i]);
    }
    double t0=now_sec();
    for(int i=0;i<threads;i++) pthread_join(pts[i],nullptr);
    enc_time=now_sec()-t0;
 
    // Calculate totals and per-block offsets
    total_lit=0; total_off=0; total_len=0; total_cmd=0;
    for(size_t b=0;b<num_blocks;b++) {
        boffs[b].lit_off=total_lit; boffs[b].lit_sz=results[b].lit_size;
        boffs[b].off_off=total_off; boffs[b].off_sz=results[b].off_size;
        boffs[b].len_off=total_len; boffs[b].len_sz=results[b].len_size;
        boffs[b].cmd_off=total_cmd; boffs[b].cmd_sz=results[b].cmd_size;
        total_lit+=results[b].lit_size; total_off+=results[b].off_size;
        total_len+=results[b].len_size; total_cmd+=results[b].cmd_size;
    }
 
    raw_lit=(uint8_t*)malloc(total_lit);
    raw_off=(uint8_t*)malloc(total_off);
    raw_len=(uint8_t*)malloc(total_len);
    raw_cmd=(uint8_t*)malloc(total_cmd);
 
    size_t li=0,oi=0,ni=0,ci=0;
    for(size_t b=0;b<num_blocks;b++) {
        memcpy(raw_lit+li,results[b].lit_buf,results[b].lit_size); li+=results[b].lit_size;
        memcpy(raw_off+oi,results[b].off_buf,results[b].off_size); oi+=results[b].off_size;
        memcpy(raw_len+ni,results[b].len_buf,results[b].len_size); ni+=results[b].len_size;
        memcpy(raw_cmd+ci,results[b].cmd_buf,results[b].cmd_size); ci+=results[b].cmd_size;
        free(results[b].lit_buf); free(results[b].off_buf);
        free(results[b].len_buf); free(results[b].cmd_buf);
    }
    for(int i=0;i<threads;i++) aligned_free(htabs[i]);
    free(htabs); free(results); free(wargs); free(pts);
    return true;
}
 
// Parallel decode from global streams — batched by thread count
static double parallel_decode(
    const uint8_t* lit, const uint8_t* off,
    const uint8_t* len, const uint8_t* cmd,
    const BlockOffsets* boffs, size_t num_blocks,
    uint8_t* dst, size_t dst_size, size_t block_size,
    int nthreads = 0)
{
    if (nthreads <= 0) nthreads = 8;
    // Cap threads to num_blocks
    size_t nt = std::min((size_t)nthreads, num_blocks);
    std::vector<DecArgs> dargs(nt);
    size_t blocks_per_thread = (num_blocks + nt - 1) / nt;
    for(size_t t=0;t<nt;t++) {
        size_t bstart = t * blocks_per_thread;
        size_t bend   = std::min(bstart + blocks_per_thread, num_blocks);
        dargs[t]={lit,off,len,cmd,boffs,dst,dst_size,bstart,bend,block_size};
    }
    double t0=now_sec();
    std::vector<pthread_t> dpts(nt);
    for(size_t t=0;t<nt;t++) pthread_create(&dpts[t],nullptr,dec_worker,&dargs[t]);
    for(size_t t=0;t<nt;t++) pthread_join(dpts[t],nullptr);
    return now_sec()-t0;
}
 
// ============================================================
// compress
// ============================================================
static int do_compress(const char* in_path, const char* out_path, int threads) {
    FILE* fin=fopen(in_path,"rb");
    if (!fin) { fprintf(stderr,"Cannot open: %s\n",in_path); return 1; }
    fseek(fin,0,SEEK_END); size_t src_size=(size_t)ftell(fin); fseek(fin,0,SEEK_SET);
    uint8_t* src=(uint8_t*)malloc(src_size);
    if (fread(src,1,src_size,fin)!=src_size) { fprintf(stderr,"Read error\n"); return 1; }
    fclose(fin);
    fprintf(stderr,"[*] Compress: %s (%.2f MB) threads=%d\n",in_path,src_size/1e6,threads);
 
    std::vector<BlockOffsets> boffs;
    uint8_t *raw_lit,*raw_off,*raw_len,*raw_cmd;
    size_t total_lit,total_off,total_len,total_cmd,num_blocks;
    double enc_time;
    encode_file(src,src_size,threads,boffs,
                raw_lit,total_lit,raw_off,total_off,
                raw_len,total_len,raw_cmd,total_cmd,
                enc_time,num_blocks);
 
    // Global zstd compression — full context = best ratio
    size_t zlit_sz,zoff_sz,zlen_sz,zcmd_sz;
    uint8_t* zlit=zstd_comp(raw_lit,total_lit,zlit_sz,ZSTD_LEVEL);
    uint8_t* zoff=zstd_comp(raw_off,total_off,zoff_sz,ZSTD_LEVEL);
    uint8_t* zlen=zstd_comp(raw_len,total_len,zlen_sz,ZSTD_LEVEL);
    uint8_t* zcmd=zstd_comp(raw_cmd,total_cmd,zcmd_sz,ZSTD_LEVEL);
    size_t total_z=zlit_sz+zoff_sz+zlen_sz+zcmd_sz;
 
    AetHeader hdr;
    memcpy(hdr.magic,"ACEPX2\0\0",8);
    hdr.version=2; hdr.orig_size=(uint64_t)src_size;
    hdr.block_size=(uint32_t)BLOCK_SIZE; hdr.num_blocks=(uint32_t)num_blocks;
    sha256(src,src_size,hdr.sha256);
    hdr.zlit_sz=zlit_sz; hdr.zoff_sz=zoff_sz;
    hdr.zlen_sz=zlen_sz; hdr.zcmd_sz=zcmd_sz;
 
    FILE* fout=fopen(out_path,"wb");
    fwrite(&hdr,sizeof(hdr),1,fout);
    fwrite(boffs.data(),sizeof(BlockOffsets),num_blocks,fout);
    fwrite(zlit,1,zlit_sz,fout); fwrite(zoff,1,zoff_sz,fout);
    fwrite(zlen,1,zlen_sz,fout); fwrite(zcmd,1,zcmd_sz,fout);
    fclose(fout);
 
    char sha_hex[65]; sha256_hex(src,src_size,sha_hex);
    fprintf(stderr,"  Original:   %14zu bytes\n",src_size);
    fprintf(stderr,"  Compressed: %14zu bytes\n",total_z);
    fprintf(stderr,"  Ratio:  %.5fx\n",(double)src_size/total_z);
    fprintf(stderr,"  Encode: %.2f MB/s  (%.3fs)\n",src_size/enc_time/1e6,enc_time);
    fprintf(stderr,"  SHA256: %s\n",sha_hex);
 
    free(src); free(raw_lit); free(raw_off); free(raw_len); free(raw_cmd);
    free(zlit); free(zoff); free(zlen); free(zcmd);
    return 0;
}
 
// ============================================================
// decompress
// ============================================================
static int do_decompress(const char* in_path, const char* out_path) {
    FILE* fin=fopen(in_path,"rb");
    if (!fin) { fprintf(stderr,"Cannot open: %s\n",in_path); return 1; }
    AetHeader hdr;
    fread(&hdr,sizeof(hdr),1,fin);
    if (memcmp(hdr.magic,"ACEPX2\0\0",8)!=0) { fprintf(stderr,"Bad magic\n"); return 1; }
    fprintf(stderr,"[*] Decompress: %s -> %s\n",in_path,out_path);
 
    uint32_t nb=hdr.num_blocks;
    std::vector<BlockOffsets> boffs(nb);
    fread(boffs.data(),sizeof(BlockOffsets),nb,fin);
 
    // Read and decompress global streams
    uint8_t* zlit=(uint8_t*)malloc(hdr.zlit_sz); fread(zlit,1,hdr.zlit_sz,fin);
    uint8_t* zoff=(uint8_t*)malloc(hdr.zoff_sz); fread(zoff,1,hdr.zoff_sz,fin);
    uint8_t* zlen=(uint8_t*)malloc(hdr.zlen_sz); fread(zlen,1,hdr.zlen_sz,fin);
    uint8_t* zcmd=(uint8_t*)malloc(hdr.zcmd_sz); fread(zcmd,1,hdr.zcmd_sz,fin);
    fclose(fin);
 
    size_t lit_sz=ZSTD_getFrameContentSize(zlit,hdr.zlit_sz);
    size_t off_sz=ZSTD_getFrameContentSize(zoff,hdr.zoff_sz);
    size_t len_sz=ZSTD_getFrameContentSize(zlen,hdr.zlen_sz);
    size_t cmd_sz=ZSTD_getFrameContentSize(zcmd,hdr.zcmd_sz);
    uint8_t* lit=(uint8_t*)malloc(lit_sz); ZSTD_decompress(lit,lit_sz,zlit,hdr.zlit_sz);
    uint8_t* off=(uint8_t*)malloc(off_sz); ZSTD_decompress(off,off_sz,zoff,hdr.zoff_sz);
    uint8_t* len=(uint8_t*)malloc(len_sz); ZSTD_decompress(len,len_sz,zlen,hdr.zlen_sz);
    uint8_t* cmd=(uint8_t*)malloc(cmd_sz); ZSTD_decompress(cmd,cmd_sz,zcmd,hdr.zcmd_sz);
    free(zlit); free(zoff); free(zlen); free(zcmd);
 
    uint8_t* dst=(uint8_t*)malloc(hdr.orig_size);
    double dec_time=parallel_decode(lit,off,len,cmd,boffs.data(),nb,
                                     dst,hdr.orig_size,hdr.block_size);
 
    uint8_t digest[32]; sha256(dst,hdr.orig_size,digest);
    bool ok=(memcmp(digest,hdr.sha256,32)==0);
    FILE* fout=fopen(out_path,"wb");
    if (fout) { fwrite(dst,1,hdr.orig_size,fout); fclose(fout); }
    fprintf(stderr,"  Decode: %.2f MB/s  (%.3fs)\n",hdr.orig_size/dec_time/1e6,dec_time);
    fprintf(stderr,"  Status: %s\n",ok?"BIT-PERFECT":"HASH MISMATCH");
 
    free(lit); free(off); free(len); free(cmd); free(dst);
    return ok?0:1;
}
 
// ============================================================
// test
// ============================================================
static int do_test(const char* in_path, int threads) {
    FILE* fin=fopen(in_path,"rb");
    if (!fin) { fprintf(stderr,"Cannot open: %s\n",in_path); return 1; }
    fseek(fin,0,SEEK_END); size_t src_size=(size_t)ftell(fin); fseek(fin,0,SEEK_SET);
    uint8_t* src=(uint8_t*)malloc(src_size);
    fread(src,1,src_size,fin); fclose(fin);
    fprintf(stderr,"[*] Test: %s (%.2f MB) threads=%d\n",in_path,src_size/1e6,threads);
 
    std::vector<BlockOffsets> boffs;
    uint8_t *raw_lit,*raw_off,*raw_len,*raw_cmd;
    size_t total_lit,total_off,total_len,total_cmd,num_blocks;
    double enc_time;
    encode_file(src,src_size,threads,boffs,
                raw_lit,total_lit,raw_off,total_off,
                raw_len,total_len,raw_cmd,total_cmd,
                enc_time,num_blocks);
 
    // Global zstd — full context
    size_t zlit_sz,zoff_sz,zlen_sz,zcmd_sz;
    uint8_t* zlit=zstd_comp(raw_lit,total_lit,zlit_sz,ZSTD_LEVEL);
    uint8_t* zoff=zstd_comp(raw_off,total_off,zoff_sz,ZSTD_LEVEL);
    uint8_t* zlen=zstd_comp(raw_len,total_len,zlen_sz,ZSTD_LEVEL);
    uint8_t* zcmd=zstd_comp(raw_cmd,total_cmd,zcmd_sz,ZSTD_LEVEL);
    size_t total_z=zlit_sz+zoff_sz+zlen_sz+zcmd_sz;
 
    // Decompress global streams
    uint8_t* lit=(uint8_t*)malloc(total_lit); ZSTD_decompress(lit,total_lit,zlit,zlit_sz);
    uint8_t* off=(uint8_t*)malloc(total_off); ZSTD_decompress(off,total_off,zoff,zoff_sz);
    uint8_t* len=(uint8_t*)malloc(total_len); ZSTD_decompress(len,total_len,zlen,zlen_sz);
    uint8_t* cmd=(uint8_t*)malloc(total_cmd); ZSTD_decompress(cmd,total_cmd,zcmd,zcmd_sz);
 
    // Parallel LZ77 decode using per-block offsets
    uint8_t* dst=(uint8_t*)malloc(src_size);
    double dec_time=parallel_decode(lit,off,len,cmd,boffs.data(),num_blocks,
                                     dst,src_size,(size_t)BLOCK_SIZE);
 
    uint8_t digest_orig[32], digest_dec[32];
    sha256(src,src_size,digest_orig); sha256(dst,src_size,digest_dec);
    bool ok=(memcmp(digest_orig,digest_dec,32)==0);
    char sha_hex[65]; sha256_hex(src,src_size,sha_hex);
 
    fprintf(stderr,"\n  ====================================================\n");
    fprintf(stderr,"  ACEAPEX v3 BATCHED TEST REPORT\n");
    fprintf(stderr,"  ====================================================\n");
    fprintf(stderr,"  Original:   %14zu bytes\n",src_size);
    fprintf(stderr,"  Compressed: %14zu bytes\n",total_z);
    fprintf(stderr,"  Ratio:  %.5fx   BPB: %.4f\n",(double)src_size/total_z,total_z*8.0/src_size);
    fprintf(stderr,"  Encode: %.2f MB/s  (%.3fs)\n",src_size/enc_time/1e6,enc_time);
    fprintf(stderr,"  Decode: %.2f MB/s  (%.3fs)\n",src_size/dec_time/1e6,dec_time);
    fprintf(stderr,"  SHA256: %.16s...\n",sha_hex);
    fprintf(stderr,"  Status: %s\n",ok?"BIT-PERFECT":"HASH MISMATCH");
    fprintf(stderr,"  ====================================================\n");
 
    free(src); free(dst);
    free(raw_lit); free(raw_off); free(raw_len); free(raw_cmd);
    free(zlit); free(zoff); free(zlen); free(zcmd);
    free(lit); free(off); free(len); free(cmd);
    return ok?0:1;
}
 
int main(int argc, char** argv) {
    if (argc < 2) {
        fprintf(stderr,"ACEAPEX v2 - Global compress + Parallel decode\n\n"
            "Usage:\n  %s c --in <f> --out <f.aet> [--threads N]\n"
            "  %s d --in <f.aet> --out <f>\n  %s t --in <f> [--threads N]\n",
            argv[0],argv[0],argv[0]);
        return 1;
    }
    const char* cmd=argv[1]; const char* in=nullptr; const char* out=nullptr; int thr=8;
    for(int i=2;i<argc;i++) {
        if (!strcmp(argv[i],"--in")&&i+1<argc) in=argv[++i];
        else if (!strcmp(argv[i],"--out")&&i+1<argc) out=argv[++i];
        else if (!strcmp(argv[i],"--threads")&&i+1<argc) thr=atoi(argv[++i]);
    }
    if (!in) { fprintf(stderr,"--in required\n"); return 1; }
    if (!strcmp(cmd,"c")) { if (!out) { fprintf(stderr,"--out required\n"); return 1; } return do_compress(in,out,thr); }
    if (!strcmp(cmd,"d")) { if (!out) { fprintf(stderr,"--out required\n"); return 1; } return do_decompress(in,out); }
    if (!strcmp(cmd,"t")) return do_test(in,thr);
    return 1;
}