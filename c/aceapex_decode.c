/* aceapex_decode.c - standalone C99 decoder for ACEPX2 archives. See aceapex_decode.h.
 *
 * Archive layout (all little-endian, packed):
 *   AetHeader 68 B: magic "ACEPX2\0\0", u32 version, u64 orig_size, u32 block_size,
 *                   u32 num_blocks, u8 xxh3[8], u64 zlit_sz, zoff_sz, zlen_sz, zcmd_sz
 *   BlockOffsets 64 B x num_blocks: lit_off, off_off, len_off, cmd_off, then the 4 sizes,
 *                   each a slice of the decoded lit / off / len / cmd stream
 *   zlit, zoff, zlen, zcmd: the four entropy-coded streams
 * off/len/cmd ("FSE" streams): u64 word = size (bits 0..47) | chunk/4096 (bits 48..62);
 *   u64 cs[nc] (bit 63 set = chunk stored raw); then the chunks as standard zstd frames.
 *   chunk field 0 = archive older than the field: chunk comes from FSE_CHUNK, else 512 KiB.
 * lit stream: u64 word = size | bit62 (zstd lanes) | bit61 (fixed chunks) | bit60 (tagged);
 *   bit62 clear = same layout as an FSE stream. Chunked: u64 CH, u64 zsz[NW], chunks.
 *   Legacy (bit61 clear): NW = 4 equal shares, u64 zsz[4] right after the word.
 *   Tagged chunk: byte 0 = 1 -> DNA pack (u32 nexc,h1..h4; zstd frames seq,cse,gap,val;
 *   2-bit bases MSB-first, case-mask bit -> |0x20, exceptions at cumulative gaps),
 *   any other byte -> zstd frame follows the tag.
 * Block tokens (cmd stream): 0xFF reset reps; c<0x80 literal run of c+1 bytes;
 *   0x80..0xBF rep match: rep index (c>>4)&3, len (c&15)+6, 15 -> +varint from len stream;
 *   0xC0..0xFE new match: len (c&63)+6 or 0xFE -> varint from len, distance varint from
 *   off, reps shift. Distances never leave the block (that is the whole point).
 */
#include "aceapex_decode.h"
#include <stdlib.h>
#include <string.h>
#include <zstd.h>

typedef struct { uint64_t lit_off, off_off, len_off, cmd_off, lit_sz, off_sz, len_sz, cmd_sz; } BO;
typedef struct {
    uint64_t orig; uint32_t bs, nb; const uint8_t* bo;   /* table bytes, 4-aligned: read via memcpy */
    const uint8_t *zl, *zo, *zn, *zc; uint64_t zls, zos, zns, zcs;
} Arc;
static uint64_t rd64(const uint8_t* p){ uint64_t v; memcpy(&v,p,8); return v; }
static uint32_t rd32(const uint8_t* p){ uint32_t v; memcpy(&v,p,4); return v; }
static BO bo_at(const uint8_t* t, size_t b){ BO o; memcpy(&o,t+64*b,64); return o; }
static int zdec(void* d, size_t raw, const void* s, size_t n){
    size_t r=ZSTD_decompress(d,raw,s,n); return !ZSTD_isError(r) && r==raw; }

/* ---- archive header / bounds ------------------------------------------------------- */
static int open_arc(const void* src, size_t n, Arc* a){
    const uint8_t* p=(const uint8_t*)src;
    if(!src || n<68 || memcmp(p,"ACEPX2\0\0",8)) return ACEAPEX_ERR_DATA;
    a->orig=rd64(p+12); a->bs=rd32(p+20); a->nb=rd32(p+24);
    a->zls=rd64(p+36); a->zos=rd64(p+44); a->zns=rd64(p+52); a->zcs=rd64(p+60);
    if(!a->bs || !a->nb || (uint64_t)a->nb*a->bs < a->orig) return ACEAPEX_ERR_DATA;
    uint64_t need=68+(uint64_t)a->nb*64+a->zls+a->zos+a->zns+a->zcs;
    if(need>n) return ACEAPEX_ERR_DATA;
    a->bo=p+68; a->zl=p+68+(size_t)a->nb*64;
    a->zo=a->zl+a->zls; a->zn=a->zo+a->zos; a->zc=a->zn+a->zns;
    return ACEAPEX_OK;
}

/* ---- a stream cursor: unpacks the chunks covering [from,to) and caches the window --- */
typedef struct {
    const uint8_t* z; size_t zsz;      /* the compressed stream */
    uint64_t size, chunk; size_t nc;   /* decoded size, chunk size, chunk count */
    int kind;                          /* 0 = FSE layout, 1 = lit chunked, 2 = lit legacy */
    int tagged; const uint8_t* tab; const uint8_t* data;   /* size table, first chunk */
    size_t* coff;                      /* compressed offset of each chunk (prefix sums) */
    uint8_t* win; uint64_t wlo, whi;   /* decoded window [wlo,whi) */
} Cur;
static uint64_t fse_default_chunk(void){
    const char* e=getenv("FSE_CHUNK"); uint64_t v=e?strtoull(e,0,10):0;
    if(v>=4096){ v&=~(uint64_t)4095; if(v>((uint64_t)16<<20)) v=(uint64_t)16<<20; return v; }
    return 512*1024;
}
static int cur_open(Cur* c, const uint8_t* z, size_t zsz, int is_lit){
    memset(c,0,sizeof *c); c->z=z; c->zsz=zsz;
    if(zsz<8){ c->size=0; c->nc=0; return ACEAPEX_OK; }   /* empty stream (tiny inputs) */
    uint64_t h=rd64(z);
    if(is_lit && (h&((uint64_t)1<<62))){
        int chunked=(h>>61)&1; c->tagged=(h>>60)&1; c->kind=chunked?1:2;
        c->size=h&~(((uint64_t)1<<62)|((uint64_t)1<<61)|((uint64_t)1<<60));
        if(chunked){ if(zsz<16) return ACEAPEX_ERR_DATA; c->chunk=rd64(z+8); c->tab=z+16; }
        else { c->chunk=(c->size+3)/4; c->tab=z+8; }
        if(!c->chunk) return ACEAPEX_ERR_DATA;
        c->nc=chunked?(size_t)((c->size+c->chunk-1)/c->chunk):4;
    } else {
        c->kind=0; c->size=h&(((uint64_t)1<<48)-1); uint64_t f=(h>>48)&0x7FFF;
        c->chunk=f?f<<12:fse_default_chunk(); c->tab=z+8;
        c->nc=(size_t)((c->size+c->chunk-1)/c->chunk);
    }
    if((size_t)(c->tab-z)+c->nc*8>zsz) return ACEAPEX_ERR_DATA;
    c->data=c->tab+c->nc*8;
    c->coff=(size_t*)malloc((c->nc+1)*sizeof(size_t)); if(!c->coff) return ACEAPEX_ERR_MEMORY;
    size_t p=0;
    for(size_t i=0;i<c->nc;i++){
        uint64_t e=rd64(c->tab+8*i); c->coff[i]=p;
        uint64_t raw=c->chunk; uint64_t o=(uint64_t)i*c->chunk;
        if(o>=c->size) raw=0; else if(o+raw>c->size) raw=c->size-o;
        p+= c->kind==0 && (e>>63) ? (size_t)raw : (size_t)(e&~((uint64_t)1<<63));
    }
    c->coff[c->nc]=p;
    if((size_t)(c->data-z)+p>zsz) { free(c->coff); c->coff=0; return ACEAPEX_ERR_DATA; }
    return ACEAPEX_OK;
}
static void cur_close(Cur* c){ free(c->coff); free(c->win); c->coff=0; c->win=0; }

static int dna_unpack(const uint8_t* s, size_t n, uint8_t* dst, size_t raw){
    if(n<20) return 0;
    uint32_t nexc=rd32(s),h1=rd32(s+4),h2=rd32(s+8),h3=rd32(s+12),h4=rd32(s+16);
    if(20+(size_t)h1+h2+h3+h4>n) return 0;
    size_t np=(raw+3)/4, nq=(raw+7)/8; const uint8_t* p=s+20; int ok=1;
    uint8_t* seq=(uint8_t*)malloc(np+1); uint8_t* cse=(uint8_t*)malloc(nq+1);
    uint32_t* gap=(uint32_t*)malloc((size_t)nexc*4+4); uint8_t* val=(uint8_t*)malloc((size_t)nexc+1);
    if(!seq||!cse||!gap||!val){ ok=0; goto out; }
    ok = zdec(seq,np,p,h1); p+=h1;
    ok = ok && zdec(cse,nq,p,h2); p+=h2;
    if(h3){ ok = ok && zdec(gap,(size_t)nexc*4,p,h3); } else memset(gap,0,(size_t)nexc*4); p+=h3;
    if(h4){ ok = ok && zdec(val,nexc,p,h4); } else memset(val,0,nexc);
    if(!ok) goto out;
    for(size_t i=0;i<raw;i++) dst[i]="ACGT"[(seq[i>>2]>>(6-2*(i&3)))&3];
    for(size_t k=0;k<nq;k++){ uint8_t m=cse[k]; if(!m) continue;
        size_t b=k<<3, lim=b+8<=raw?8:raw-b; for(size_t j=0;j<lim;j++) if(m&(0x80>>j)) dst[b+j]|=0x20; }
    { uint64_t pos=0; for(uint32_t k=0;k<nexc;k++){ pos+=gap[k]; if(pos<raw) dst[pos]=val[k]; } }
out:
    free(seq); free(cse); free(gap); free(val); return ok;
}
/* decode chunk i into dst (raw bytes) */
static int cur_chunk(const Cur* c, size_t i, uint8_t* dst, size_t raw){
    uint64_t e=rd64(c->tab+8*i); const uint8_t* p=c->data+c->coff[i]; size_t n=c->coff[i+1]-c->coff[i];
    if(c->kind==0){ if(e>>63){ memcpy(dst,p,raw); return 1; } return zdec(dst,raw,p,n); }
    if(!n) return raw==0;
    if(!c->tagged) return zdec(dst,raw,p,n);
    if(p[0]==1) return dna_unpack(p+1,n-1,dst,raw);
    return zdec(dst,raw,p+1,n-1);
}
/* make [from,to) of the decoded stream available; returns pointer to byte 'from' */
static const uint8_t* cur_get(Cur* c, uint64_t from, uint64_t to, int* err){
    if(to<=from) return c->z;                       /* empty slice: any valid pointer */
    if(to>c->size){ *err=ACEAPEX_ERR_DATA; return 0; }
    if(c->win && from>=c->wlo && to<=c->whi) return c->win+(from-c->wlo);
    size_t c0=(size_t)(from/c->chunk), c1=(size_t)((to-1)/c->chunk);
    uint64_t lo=(uint64_t)c0*c->chunk, hi=(uint64_t)(c1+1)*c->chunk; if(hi>c->size) hi=c->size;
    uint8_t* w=(uint8_t*)realloc(c->win,(size_t)(hi-lo)+1); if(!w){ *err=ACEAPEX_ERR_MEMORY; return 0; }
    c->win=w; c->wlo=lo; c->whi=hi;
    for(size_t i=c0;i<=c1;i++){
        uint64_t o=(uint64_t)i*c->chunk; size_t raw=(size_t)((o+c->chunk<=c->size)?c->chunk:c->size-o);
        if(!cur_chunk(c,i,w+(o-lo),raw)){ *err=ACEAPEX_ERR_DATA; c->whi=c->wlo; return 0; }
    }
    return w+(from-lo);
}

/* ---- one block: literals + matches ----------------------------------------------- */
static uint32_t varint(const uint8_t* b, size_t* p, size_t lim){
    uint32_t v=0, sh=0;
    while(*p<lim){ uint8_t x=b[(*p)++]; v|=(uint32_t)(x&0x7F)<<sh; if(!(x&0x80)) break; sh+=7; if(sh>28) break; }
    return v;
}
static void copy_match(uint8_t* d, size_t out, uint32_t dist, uint32_t len){
    uint8_t* t=d+out; const uint8_t* s=t-dist;
    if(dist>=len){ memcpy(t,s,len); return; }
    if(dist==1){ memset(t,s[0],len); return; }
    uint32_t done=0; while(done+dist<=len){ memcpy(t+done,s,dist); done+=dist; }
    if(done<len) memcpy(t+done,s,len-done);
}
static int decode_block(uint8_t* dst, size_t dsz, const uint8_t* lit, size_t ls,
                        const uint8_t* off, size_t os, const uint8_t* len, size_t ns,
                        const uint8_t* cmd, size_t cs){
    size_t lp=0, op=0, np=0, cp=0, out=0; uint32_t rep[4]={1,2,4,8};
    while(out<dsz && cp<cs){
        uint8_t c=cmd[cp++];
        if(c==0xFF){ rep[0]=1; rep[1]=2; rep[2]=4; rep[3]=8; continue; }
        if(c<0x80){ uint32_t l=c+1; if(lp+l>ls||out+l>dsz) return 0; memcpy(dst+out,lit+lp,l); out+=l; lp+=l; }
        else if((c&0xC0)==0x80){
            uint32_t ri=(c>>4)&3, lv=c&15; if(lv==15) lv+=varint(len,&np,ns);
            uint32_t l=lv+6, dist=rep[ri];
            if(ri){ for(int i=ri;i>0;i--) rep[i]=rep[i-1]; rep[0]=dist; }
            if(!dist||dist>out||out+l>dsz) return 0;
            copy_match(dst,out,dist,l); out+=l;
        } else {
            uint32_t lv=(c==0xFE)?varint(len,&np,ns):(uint32_t)(c&0x3F);
            uint32_t l=lv+6, dist=varint(off,&op,os);
            rep[3]=rep[2]; rep[2]=rep[1]; rep[1]=rep[0]; rep[0]=dist;
            if(!dist||dist>out||out+l>dsz) return 0;
            copy_match(dst,out,dist,l); out+=l;
        }
    }
    return out==dsz;
}

/* ---- a decoder over the four cursors -------------------------------------------- */
typedef struct { Arc a; Cur l,o,n,c; } Dec;
static int dec_open(Dec* d, const void* src, size_t n){
    int r=open_arc(src,n,&d->a); if(r) return r;
    memset(&d->l,0,sizeof(Cur)); memset(&d->o,0,sizeof(Cur)); memset(&d->n,0,sizeof(Cur)); memset(&d->c,0,sizeof(Cur));
    if((r=cur_open(&d->l,d->a.zl,(size_t)d->a.zls,1))) return r;
    if((r=cur_open(&d->o,d->a.zo,(size_t)d->a.zos,0))) return r;
    if((r=cur_open(&d->n,d->a.zn,(size_t)d->a.zns,0))) return r;
    if((r=cur_open(&d->c,d->a.zc,(size_t)d->a.zcs,0))) return r;
    return ACEAPEX_OK;
}
static void dec_close(Dec* d){ cur_close(&d->l); cur_close(&d->o); cur_close(&d->n); cur_close(&d->c); }
static size_t block_size_of(const Dec* d, size_t b){
    uint64_t st=(uint64_t)b*d->a.bs; return (size_t)(st>=d->a.orig?0:(d->a.orig-st<d->a.bs?d->a.orig-st:d->a.bs)); }
static int dec_block(Dec* d, size_t b, uint8_t* dst){
    if(b>=d->a.nb) return ACEAPEX_ERR_DATA;
    BO bov=bo_at(d->a.bo,b); const BO* bo=&bov; size_t sz=block_size_of(d,b); int err=0;
    const uint8_t* L=cur_get(&d->l,bo->lit_off,bo->lit_off+bo->lit_sz,&err); if(err) return err;
    const uint8_t* O=cur_get(&d->o,bo->off_off,bo->off_off+bo->off_sz,&err); if(err) return err;
    const uint8_t* N=cur_get(&d->n,bo->len_off,bo->len_off+bo->len_sz,&err); if(err) return err;
    const uint8_t* C=cur_get(&d->c,bo->cmd_off,bo->cmd_off+bo->cmd_sz,&err); if(err) return err;
    return decode_block(dst,sz,L,(size_t)bo->lit_sz,O,(size_t)bo->off_sz,N,(size_t)bo->len_sz,C,(size_t)bo->cmd_sz)
           ? ACEAPEX_OK : ACEAPEX_ERR_DATA;
}

/* ---- public API ------------------------------------------------------------------- */
int64_t aceapex_decoded_size(const void* src, size_t n){ Arc a; int r=open_arc(src,n,&a); return r?r:(int64_t)a.orig; }

int64_t aceapex_decompress(const void* src, size_t n, void* dst, size_t cap){
    Dec d; int r=dec_open(&d,src,n); if(r){ dec_close(&d); return r; }
    if(cap<d.a.orig){ dec_close(&d); return ACEAPEX_ERR_BUFFER; }
    for(size_t b=0;b<d.a.nb && !r;b++) r=dec_block(&d,b,(uint8_t*)dst+(size_t)b*d.a.bs);
    dec_close(&d); return r?r:(int64_t)d.a.orig;
}

/* ranges are served from a block cache: each distinct block decoded once */
typedef struct { size_t b; uint8_t* buf; } Cached;
static int64_t serve(Dec* d, aceapex_range_t* rg, size_t count){
    uint8_t* blk=(uint8_t*)malloc(d->a.bs+64); if(!blk) return ACEAPEX_ERR_MEMORY;
    size_t cur=(size_t)-1; int64_t okn=0;
    /* order of service: by first block, so a block is decoded once for consecutive users */
    size_t* order=(size_t*)malloc(count*sizeof(size_t)); if(!order){ free(blk); return ACEAPEX_ERR_MEMORY; }
    for(size_t i=0;i<count;i++) order[i]=i;
    /* insertion sort by offset is O(n^2) for adversarial input; a simple merge sort instead */
    { size_t* tmp=(size_t*)malloc(count*sizeof(size_t)); if(!tmp){ free(order); free(blk); return ACEAPEX_ERR_MEMORY; }
      for(size_t w=1;w<count;w*=2) for(size_t lo=0;lo<count;lo+=2*w){
        size_t mid=lo+w<count?lo+w:count, hi=lo+2*w<count?lo+2*w:count, i=lo,j=mid,k=lo;
        while(i<mid&&j<hi) tmp[k++]= rg[order[i]].offset<=rg[order[j]].offset ? order[i++] : order[j++];
        while(i<mid) tmp[k++]=order[i++];
        while(j<hi) tmp[k++]=order[j++];
        memcpy(order+lo,tmp+lo,(hi-lo)*sizeof(size_t)); }
      free(tmp); }
    for(size_t oi=0;oi<count;oi++){
        aceapex_range_t* r=&rg[order[oi]];
        if(r->length==0){ r->written=0; okn++; continue; }
        if(!r->dst || r->offset>d->a.orig || r->length>d->a.orig-r->offset){ r->written=ACEAPEX_ERR_DATA; continue; }
        uint64_t pos=r->offset, end=r->offset+r->length; uint8_t* out=(uint8_t*)r->dst; int64_t st=ACEAPEX_OK;
        while(pos<end){
            size_t b=(size_t)(pos/d->a.bs);
            if(b!=cur){ int e=dec_block(d,b,blk); if(e){ st=e; break; } cur=b; }
            uint64_t bst=(uint64_t)b*d->a.bs, take=bst+d->a.bs-pos; if(take>end-pos) take=end-pos;
            memcpy(out,blk+(pos-bst),(size_t)take); out+=take; pos+=take;
        }
        r->written= st? st : (int64_t)r->length; if(!st) okn++;
    }
    free(order); free(blk); return okn;
}
int64_t aceapex_decompress_region(const void* src, size_t n, void* dst, size_t cap, uint64_t off, uint64_t len){
    if(len==0) return 0;
    if(cap<len) return ACEAPEX_ERR_BUFFER;
    Dec d; int r=dec_open(&d,src,n); if(r){ dec_close(&d); return r; }
    aceapex_range_t rg={off,len,dst,0}; int64_t k=serve(&d,&rg,1); dec_close(&d);
    if(k<0) return k;
    return rg.written;
}
int64_t aceapex_decompress_ranges(const void* src, size_t n, aceapex_range_t* rg, size_t count, int threads){
    (void)threads;
    Dec d; int r=dec_open(&d,src,n); if(r){ dec_close(&d); return r; }
    int64_t k=serve(&d,rg,count); dec_close(&d); return k;
}
