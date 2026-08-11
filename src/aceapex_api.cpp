#define ACEAPEX_NO_MAIN
#include "aceapex_main.cpp"
#include "aceapex.h"
#include <vector>

size_t aceapex_compress_bound(size_t src_size) {
    // Worst case: incompressible data + header overhead
    return src_size + src_size/8 + 1024;
}

int64_t aceapex_compress(
    const void* src, size_t src_size,
    void*       dst, size_t dst_capacity,
    int         level,
    int         threads)
{
    // Empty input: nothing to encode. Returning 0 avoids a division by
    // num_blocks==0 further down (SIGFPE). Reported paths never hit this in
    // lzbench, but the public API must not crash on an empty buffer.
    if (src_size == 0) return 0;
    if (!src || !dst) return ACEAPEX_ERR_DATA;
    if (threads <= 0) threads = 8;
    if (level <= 0)   level   = 2;

    std::vector<BlockOffsets> boffs;
    uint8_t *rl,*ro,*rn,*rc;
    size_t tl,to,tn,tc,nb;
    if (!encode_file((const uint8_t*)src,src_size,threads,level,
                     boffs,rl,tl,ro,to,rn,tn,rc,tc,nb))
        return ACEAPEX_ERR_MEMORY;

    size_t zls,zos,zns,zcs;
    uint8_t *zl,*zo,*zn,*zc;
    zl=lit_compress(rl,tl,zls);
    entropy_encode(rl,tl,ro,to,rn,tn,rc,tc,
                   zl,zls,zo,zos,zn,zns,zc,zcs);
    free(rl);free(ro);free(rn);free(rc);

    AetHeader hdr;
    memcpy(hdr.magic,"ACEPX2\0\0",8);
    hdr.version=2; hdr.orig_size=src_size;
    hdr.block_size=BLOCK_SIZE; hdr.num_blocks=nb;
    uint64_t hv=OUR_CHECKSUM(src,src_size);
    memcpy(hdr.xxhash,&hv,8);
    hdr.zlit_sz=zls;hdr.zoff_sz=zos;
    hdr.zlen_sz=zns;hdr.zcmd_sz=zcs;

    size_t total=sizeof(hdr)+nb*sizeof(BlockOffsets)
                 +zls+zos+zns+zcs;
    if (total>dst_capacity) {
        free(zl);free(zo);free(zn);free(zc);
        return ACEAPEX_ERR_BUFFER;
    }

    uint8_t* p=(uint8_t*)dst;
    memcpy(p,&hdr,sizeof(hdr)); p+=sizeof(hdr);
    memcpy(p,boffs.data(),nb*sizeof(BlockOffsets));
    p+=nb*sizeof(BlockOffsets);
    memcpy(p,zl,zls);p+=zls;
    memcpy(p,zo,zos);p+=zos;
    memcpy(p,zn,zns);p+=zns;
    memcpy(p,zc,zcs);
    free(zl);free(zo);free(zn);free(zc);
    return (int64_t)total;
}

int64_t aceapex_decompress(
    const void* src, size_t src_size,
    void*       dst, size_t dst_capacity)
{
    const uint8_t* p=(const uint8_t*)src;
    AetHeader hdr; memcpy(&hdr,p,sizeof(hdr));
    if (memcmp(hdr.magic,"ACEPX2\0\0",8)!=0) return ACEAPEX_ERR_DATA;
    if (hdr.orig_size>dst_capacity) return ACEAPEX_ERR_BUFFER;

    // ---- Header validation. Runs once per archive, costs nothing in the hot loop.
    // A single corrupted byte in the header or in the BlockOffsets table used to send
    // stream pointers into arbitrary memory (SIGSEGV). Absolute offsets make this cheap
    // to check: every bound is a constant known before decoding starts.
    if (hdr.block_size == 0 || hdr.num_blocks == 0) return ACEAPEX_ERR_DATA;
    if ((uint64_t)hdr.num_blocks * (uint64_t)hdr.block_size < hdr.orig_size)
        return ACEAPEX_ERR_DATA;
    {
        uint64_t need = (uint64_t)sizeof(hdr)
                      + (uint64_t)hdr.num_blocks * sizeof(BlockOffsets)
                      + hdr.zlit_sz + hdr.zoff_sz + hdr.zlen_sz + hdr.zcmd_sz;
        if (need > src_size) return ACEAPEX_ERR_DATA;
    }
    p+=sizeof(hdr);
    std::vector<BlockOffsets> boffs(hdr.num_blocks);
    memcpy(boffs.data(),p,hdr.num_blocks*sizeof(BlockOffsets));
    p+=hdr.num_blocks*sizeof(BlockOffsets);
    // malloc(0) may legally return NULL; an empty stream is not an error.
    // The old !zl check turned zlit_sz==0 (tiny inputs) into ACEAPEX_ERR_MEMORY.
    uint8_t* zl=(uint8_t*)malloc(hdr.zlit_sz?hdr.zlit_sz:1);
    uint8_t* zo=(uint8_t*)malloc(hdr.zoff_sz?hdr.zoff_sz:1);
    uint8_t* zn=(uint8_t*)malloc(hdr.zlen_sz?hdr.zlen_sz:1);
    uint8_t* zc=(uint8_t*)malloc(hdr.zcmd_sz?hdr.zcmd_sz:1);
    if(!zl||!zo||!zn||!zc){free(zl);free(zo);free(zn);free(zc);return ACEAPEX_ERR_MEMORY;}
    memcpy(zl,p,hdr.zlit_sz); p+=hdr.zlit_sz;
    memcpy(zo,p,hdr.zoff_sz); p+=hdr.zoff_sz;
    memcpy(zn,p,hdr.zlen_sz); p+=hdr.zlen_sz;
    memcpy(zc,p,hdr.zcmd_sz);
    size_t os=*(uint64_t*)zo,ns=*(uint64_t*)zn,cs=*(uint64_t*)zc;
    size_t ls=0; uint8_t* l=lit_decompress(zl,hdr.zlit_sz,ls);
    if(!l){free(zl);free(zo);free(zn);free(zc);return ACEAPEX_ERR_MEMORY;}
    uint8_t* o=(uint8_t*)malloc(os);
    uint8_t* n=(uint8_t*)malloc(ns);
    uint8_t* c=(uint8_t*)malloc(cs);
    if(!o||!n||!c){free(o);free(n);free(c);free(zl);free(zo);free(zn);free(zc);return ACEAPEX_ERR_MEMORY;}
    fse_chunked_decomp(zo,os,o); fse_chunked_decomp(zn,ns,n); fse_chunked_decomp(zc,cs,c);
    free(zl);free(zo);free(zn);free(zc);

    // Every block's stream slice must lie inside its decoded stream.
    for (size_t b = 0; b < hdr.num_blocks; b++) {
        const BlockOffsets& bo = boffs[b];
        if (bo.lit_off + bo.lit_sz > ls || bo.lit_off > ls ||
            bo.off_off + bo.off_sz > os || bo.off_off > os ||
            bo.len_off + bo.len_sz > ns || bo.len_off > ns ||
            bo.cmd_off + bo.cmd_sz > cs || bo.cmd_off > cs) {
            free(l);free(o);free(n);free(c);
            return ACEAPEX_ERR_DATA;
        }
    }
    parallel_decode(l,o,n,c,boffs.data(),hdr.num_blocks,
                    (uint8_t*)dst,hdr.orig_size,hdr.block_size);
    free(l);free(o);free(n);free(c);
    return (int64_t)hdr.orig_size;
}

int64_t aceapex_decompress_region(
    const void* src, size_t src_size,
    void*       dst, size_t dst_capacity,
    uint64_t    offset, uint64_t length)
{
    if (!src || src_size < sizeof(AetHeader)) return ACEAPEX_ERR_DATA;
    const uint8_t* p = (const uint8_t*)src;
    AetHeader hdr; memcpy(&hdr, p, sizeof(hdr));
    if (memcmp(hdr.magic,"ACEPX2\0\0",8) != 0) return ACEAPEX_ERR_DATA;
    if (hdr.block_size == 0 || hdr.num_blocks == 0) return ACEAPEX_ERR_DATA;
    if (length == 0) return 0;
    if (offset > hdr.orig_size || length > hdr.orig_size - offset) return ACEAPEX_ERR_DATA;
    if (length > dst_capacity) return ACEAPEX_ERR_BUFFER;

    uint64_t need = (uint64_t)sizeof(hdr)
                  + (uint64_t)hdr.num_blocks * sizeof(BlockOffsets)
                  + hdr.zlit_sz + hdr.zoff_sz + hdr.zlen_sz + hdr.zcmd_sz;
    if (need > src_size) return ACEAPEX_ERR_DATA;

    p += sizeof(hdr);
    std::vector<BlockOffsets> boffs(hdr.num_blocks);
    memcpy(boffs.data(), p, (size_t)hdr.num_blocks * sizeof(BlockOffsets));
    p += (size_t)hdr.num_blocks * sizeof(BlockOffsets);

    const uint8_t* zlit = p;
    const uint8_t* zoff = zlit + hdr.zlit_sz;
    const uint8_t* zlen = zoff + hdr.zoff_sz;
    const uint8_t* zcmd = zlen + hdr.zlen_sz;

    size_t b0 = (size_t)(offset / hdr.block_size);
    size_t b1 = (size_t)((offset + length - 1) / hdr.block_size);
    if (b1 >= hdr.num_blocks) return ACEAPEX_ERR_DATA;

    size_t lf=boffs[b0].lit_off, lt=boffs[b1].lit_off+boffs[b1].lit_sz;
    size_t of=boffs[b0].off_off, ot=boffs[b1].off_off+boffs[b1].off_sz;
    size_t nf=boffs[b0].len_off, nt=boffs[b1].len_off+boffs[b1].len_sz;
    size_t cf=boffs[b0].cmd_off, ct=boffs[b1].cmd_off+boffs[b1].cmd_sz;

    size_t lit_sz = 0;
    uint8_t* lit = lit_range(zlit, hdr.zlit_sz, lit_sz, lf, lt);
    uint8_t* off = fse_range(zoff, *(const uint64_t*)zoff & ~(uint64_t(1)<<63), of, ot);
    uint8_t* len = fse_range(zlen, *(const uint64_t*)zlen & ~(uint64_t(1)<<63), nf, nt);
    uint8_t* cmd = fse_range(zcmd, *(const uint64_t*)zcmd & ~(uint64_t(1)<<63), cf, ct);
    if (!lit || !off || !len || !cmd) {
        free(lit); free(off); free(len); free(cmd);
        return ACEAPEX_ERR_MEMORY;
    }

    size_t span_start = b0 * (size_t)hdr.block_size;
    size_t span_end   = (b1 + 1) * (size_t)hdr.block_size;
    if (span_end > hdr.orig_size) span_end = (size_t)hdr.orig_size;
    uint8_t* span = (uint8_t*)malloc(span_end - span_start + 64);
    if (!span) { free(lit); free(off); free(len); free(cmd); return ACEAPEX_ERR_MEMORY; }

    for (size_t b = b0; b <= b1; b++) {
        const BlockOffsets& bo = boffs[b];
        size_t bstart = b * (size_t)hdr.block_size;
        size_t bsize  = (size_t)(hdr.orig_size - bstart);
        if (bsize > hdr.block_size) bsize = hdr.block_size;
        decompress_streams(span + (bstart - span_start), bsize,
            lit + bo.lit_off, bo.lit_sz, off + bo.off_off, bo.off_sz,
            len + bo.len_off, bo.len_sz, cmd + bo.cmd_off, bo.cmd_sz);
    }
    memcpy(dst, span + (offset - span_start), (size_t)length);

    free(lit); free(off); free(len); free(cmd); free(span);
    return (int64_t)length;
}
