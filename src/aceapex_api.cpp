#define ACEAPEX_NO_MAIN
#include "aceapex_main.cpp"
#include "aceapex.h"
#include <vector>
#include <algorithm>
#include <atomic>

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
    // Таблица блоков читается ПРЯМО ИЗ АРХИВА. Копия в вектор стоила 969 KB на каждый
    // вызов ради 128 байт, что дало 485 page-faults на запрос — почти всю оставшуюся
    // латентность. Архив уже в памяти вызывающего, копировать нечего.
    const BlockOffsets* boffs = (const BlockOffsets*)p;
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

    size_t lit_sz = 0, wl=0, wo=0, wn=0, wc=0;
    uint8_t* lit = lit_range(zlit, hdr.zlit_sz, lit_sz, lf, lt, &wl);
    uint8_t* off = fse_range(zoff, *(const uint64_t*)zoff & ~(uint64_t(1)<<63), of, ot, &wo);
    uint8_t* len = fse_range(zlen, *(const uint64_t*)zlen & ~(uint64_t(1)<<63), nf, nt, &wn);
    uint8_t* cmd = fse_range(zcmd, *(const uint64_t*)zcmd & ~(uint64_t(1)<<63), cf, ct, &wc);
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
            lit + (bo.lit_off-wl), bo.lit_sz, off + (bo.off_off-wo), bo.off_sz,
            len + (bo.len_off-wn), bo.len_sz, cmd + (bo.cmd_off-wc), bo.cmd_sz);
    }
    memcpy(dst, span + (offset - span_start), (size_t)length);

    free(lit); free(off); free(len); free(cmd); free(span);
    return (int64_t)length;
}

// ---------------------------------------------------------------------------
// BATCH. Стоимость одного региона определяется распаковкой чанков, покрывающих
// его блоки, а не размером ответа. При многих диапазонах те же блоки распаковыв-
// аются повторно: 10 000 случайных 16 KiB запросов трогают 11 342 различных блока
// из 15 499. Группировка по блокам превращает N_requests * T_decode в
// N_unique_blocks * T_decode + T_dispatch.
// ---------------------------------------------------------------------------
namespace {

struct RangeWork {
    size_t   idx;          // позиция в исходном массиве, чтобы вернуть порядок
    uint64_t offset, length;
    void*    dst;
    uint32_t b0, b1;       // покрываемые блоки
};

struct Group { size_t first, last; uint32_t b0, b1; };   // [first,last) в w[]

struct BatchTask {
    const uint8_t*      src;
    const AetHeader*    hdr;
    const BlockOffsets* boffs;
    const uint8_t      *zlit, *zoff, *zlen, *zcmd;
    RangeWork*          w;
    Group*              g;
    size_t              ng;
    std::atomic<size_t> next;
    std::atomic<int>    failed;
};

// Один рабочий берёт группы подряд идущих запросов. Группа — это набор запросов,
// чьи блоки перекрываются или соседствуют: для них выгодно распаковать один span.
void* batch_worker(void* arg) {
    BatchTask* t = (BatchTask*)arg;
    const AetHeader& h = *t->hdr;
    for (;;) {
        // Группы нарезаны ДО запуска потоков, рабочий берёт готовую целиком.
        // Прежняя схема с захватом соседей через compare_exchange давала гонку:
        // между load и обменом другой поток успевал взять запрос, и два рабочих
        // писали в один RangeWork. TSan это поймал, данные сходились случайно.
        size_t gi = t->next.fetch_add(1);
        if (gi >= t->ng) break;
        const Group& G = t->g[gi];
        size_t i = G.first, grp_end = G.last;
        RangeWork& r = t->w[i];

        size_t lf=t->boffs[G.b0].lit_off, lt=t->boffs[G.b1].lit_off+t->boffs[G.b1].lit_sz;
        size_t of=t->boffs[G.b0].off_off, ot=t->boffs[G.b1].off_off+t->boffs[G.b1].off_sz;
        size_t nf=t->boffs[G.b0].len_off, nt=t->boffs[G.b1].len_off+t->boffs[G.b1].len_sz;
        size_t cf=t->boffs[G.b0].cmd_off, ct=t->boffs[G.b1].cmd_off+t->boffs[G.b1].cmd_sz;

        size_t lit_sz=0, wl=0, wo=0, wn=0, wc=0;
        uint8_t* lit=lit_range(t->zlit,h.zlit_sz,lit_sz,lf,lt,&wl);
        uint8_t* off=fse_range(t->zoff,*(const uint64_t*)t->zoff&~(uint64_t(1)<<63),of,ot,&wo);
        uint8_t* len=fse_range(t->zlen,*(const uint64_t*)t->zlen&~(uint64_t(1)<<63),nf,nt,&wn);
        uint8_t* cmd=fse_range(t->zcmd,*(const uint64_t*)t->zcmd&~(uint64_t(1)<<63),cf,ct,&wc);
        if(!lit||!off||!len||!cmd){
            free(lit);free(off);free(len);free(cmd);
            for(size_t k=G.first;k<G.last;k++) t->w[k].dst=nullptr;
            t->failed.store(1); continue;
        }

        size_t span_start=(size_t)G.b0*h.block_size;
        size_t span_end=(size_t)(G.b1+1)*h.block_size;
        if(span_end>h.orig_size) span_end=(size_t)h.orig_size;
        uint8_t* span=(uint8_t*)malloc(span_end-span_start+64);
        if(!span){ free(lit);free(off);free(len);free(cmd);
                   t->failed.store(1); continue; }

        for(uint32_t b=G.b0;b<=G.b1;b++){
            const BlockOffsets& bo=t->boffs[b];
            size_t bs=(size_t)b*h.block_size;
            size_t bsz=(size_t)(h.orig_size-bs);
            if(bsz>h.block_size) bsz=h.block_size;
            decompress_streams(span+(bs-span_start),bsz,
                lit+(bo.lit_off-wl),bo.lit_sz, off+(bo.off_off-wo),bo.off_sz,
                len+(bo.len_off-wn),bo.len_sz, cmd+(bo.cmd_off-wc),bo.cmd_sz);
        }
        for(size_t k=i;k<grp_end;k++){
            RangeWork& q=t->w[k];
            if(q.offset<span_start || q.offset+q.length>span_end) continue;
            memcpy(q.dst, span+(q.offset-span_start), (size_t)q.length);
        }
        free(lit);free(off);free(len);free(cmd);free(span);
    }
    return nullptr;
}

} // namespace

int64_t aceapex_decompress_ranges(
    const void* src, size_t src_size,
    aceapex_range_t* ranges, size_t count, int threads)
{
    if(!src||!ranges) return ACEAPEX_ERR_DATA;
    if(count==0) return 0;
    if(src_size<sizeof(AetHeader)) return ACEAPEX_ERR_DATA;

    const uint8_t* p=(const uint8_t*)src;
    AetHeader hdr; memcpy(&hdr,p,sizeof(hdr));
    if(memcmp(hdr.magic,"ACEPX2\0\0",8)!=0) return ACEAPEX_ERR_DATA;
    if(hdr.block_size==0||hdr.num_blocks==0) return ACEAPEX_ERR_DATA;
    uint64_t need=(uint64_t)sizeof(hdr)+(uint64_t)hdr.num_blocks*sizeof(BlockOffsets)
                 +hdr.zlit_sz+hdr.zoff_sz+hdr.zlen_sz+hdr.zcmd_sz;
    if(need>src_size) return ACEAPEX_ERR_DATA;

    p+=sizeof(hdr);
    const BlockOffsets* boffs=(const BlockOffsets*)p;
    p+=(size_t)hdr.num_blocks*sizeof(BlockOffsets);
    const uint8_t* zlit=p;
    const uint8_t* zoff=zlit+hdr.zlit_sz;
    const uint8_t* zlen=zoff+hdr.zoff_sz;
    const uint8_t* zcmd=zlen+hdr.zlen_sz;

    // Проверяем каждый запрос отдельно: плохой диапазон не должен ронять батч.
    std::vector<RangeWork> w; w.reserve(count);
    for(size_t i=0;i<count;i++){
        aceapex_range_t& q=ranges[i];
        q.written=ACEAPEX_ERR_DATA;
        if(q.length==0){ q.written=0; continue; }
        if(!q.dst) continue;
        if(q.offset>hdr.orig_size||q.length>hdr.orig_size-q.offset) continue;
        uint32_t b0=(uint32_t)(q.offset/hdr.block_size);
        uint32_t b1=(uint32_t)((q.offset+q.length-1)/hdr.block_size);
        if(b1>=hdr.num_blocks) continue;
        w.push_back({i,q.offset,q.length,q.dst,b0,b1});
    }
    if(w.empty()) return 0;

    // Сортировка по первому блоку: соседние запросы попадают в один рабочий подряд,
    // а значит переиспользуют горячие страницы архива и кэш процессора.
    std::sort(w.begin(),w.end(),
              [](const RangeWork& a,const RangeWork& b){ return a.b0<b.b0; });

    // Нарезка на группы: подряд идущие запросы, чьи блоки соседствуют, обслуживаются
    // одной распаковкой span. Ограничение в 64 блока не даёт span раздуться.
    std::vector<Group> groups;
    for(size_t i=0;i<w.size();){
        uint32_t b0=w[i].b0, b1=w[i].b1;
        size_t j=i+1;
        while(j<w.size() && w[j].b0<=b1+1 && w[j].b1<=b0+63){
            if(w[j].b1>b1) b1=w[j].b1;
            j++;
        }
        groups.push_back({i,j,b0,b1});
        i=j;
    }

    BatchTask t{(const uint8_t*)src,&hdr,boffs,zlit,zoff,zlen,zcmd,
                w.data(),groups.data(),groups.size(),{0},{0}};
    // Порог: поднимать восемь потоков ради сотни запросов дороже, чем выполнить их
    // последовательно. Замер: при N=100 батч был вдвое медленнее цикла.
    int lanes = threads>0 ? threads : (int)sysconf(_SC_NPROCESSORS_ONLN);
    if(lanes<1) lanes=1;
    if(w.size()<512) lanes=1;
    if((size_t)lanes>groups.size()) lanes=(int)groups.size();
    if(lanes<1) lanes=1;

    if(lanes==1){
        batch_worker(&t);
    } else {
        std::vector<pthread_t> th(lanes);
        for(int k=0;k<lanes;k++) pthread_create(&th[k],nullptr,batch_worker,&t);
        for(int k=0;k<lanes;k++) pthread_join(th[k],nullptr);
    }

    int64_t ok=0;
    for(const RangeWork& r : w)
        if(r.dst){ ranges[r.idx].written=(int64_t)r.length; ok++; }
    return ok;
}
