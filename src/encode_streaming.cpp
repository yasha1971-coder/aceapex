#define ACEAPEX_NO_MAIN
#include "aceapex_main.cpp"

static const size_t HISTORY_SIZE = 1 * 1024 * 1024;
static const size_t CHUNK_SIZE   = 1 * 1024 * 1024;

int encode_streaming_file(const char* in_path, const char* out_path, int threads, int level) {
    FILE* fin = fopen(in_path, "rb");
    if (!fin) { fprintf(stderr, "Cannot open: %s\n", in_path); return 1; }
    fseek(fin, 0, SEEK_END);
    size_t total_size = ftell(fin);
    fseek(fin, 0, SEEK_SET);

    fprintf(stderr, "[*] Streaming compress: %s (%.2f MB)\n", in_path, total_size/1e6);

    // Window = history + current chunk
    size_t win_size = HISTORY_SIZE + CHUNK_SIZE;
    uint8_t* window = (uint8_t*)malloc(win_size);
    size_t history_len = 0;

    // Setup hash table
    uint32_t hash_log = 17;
    uint32_t hash_mask = (1u << hash_log) - 1;
    uint32_t chain_mask = (1u<<20)-1;
    ThreadHashTable* ht = (ThreadHashTable*)calloc(1, sizeof(ThreadHashTable));
    ht->pos   = (int32_t*) calloc(hash_mask+1, sizeof(int32_t));
    ht->epoch = (uint32_t*)calloc(hash_mask+1, sizeof(uint32_t));
    ht->chain = (int32_t*) malloc(((size_t)chain_mask+1)*sizeof(int32_t));
    memset(ht->chain, -1, ((size_t)chain_mask+1)*sizeof(int32_t));
    ht->hash_mask = hash_mask;
    ht->chain_mask = chain_mask;
    ht->max_attempts = (level>=2)?32:4;

    std::vector<BlockOffsets> boffs;
    std::vector<BlockResult>  results;
    size_t chunk_idx = 0;
    size_t total_read = 0;

    while (total_read < total_size) {
        // Read next chunk
        size_t to_read = std::min(CHUNK_SIZE, total_size - total_read);
        fread(window + history_len, 1, to_read, fin);
        size_t window_len = history_len + to_read;
        total_read += to_read;

        // Compress current chunk (history_len .. window_len)
        BlockResult res;
        res.lit_buf = (uint8_t*)malloc(to_read * 2 + 4096);
        res.off_buf = (uint8_t*)malloc(to_read * 2 + 4096);
        res.len_buf = (uint8_t*)malloc(to_read * 2 + 4096);
        res.cmd_buf = (uint8_t*)malloc(to_read * 2 + 4096);
        res.lit_size = res.off_size = res.len_size = res.cmd_size = 0;
        res.overflow = 0;

        compress_block(window, window_len, history_len, window_len, ht, &res);

        results.push_back(res);

        // Shift window — keep last HISTORY_SIZE bytes
        size_t keep = std::min(HISTORY_SIZE, window_len);
        memmove(window, window + window_len - keep, keep);
        history_len = keep;
        ht->cur_epoch++; // invalidate old hash entries
        chunk_idx++;

        fprintf(stderr, "  Chunk %zu: %.1f MB done\n", chunk_idx, total_read/1e6);
    }
    fclose(fin);

    // Build output
    size_t total_lit=0, total_off=0, total_len=0, total_cmd=0;
    for (auto& r : results) {
        total_lit+=r.lit_size; total_off+=r.off_size;
        total_len+=r.len_size; total_cmd+=r.cmd_size;
    }
    uint8_t* raw_lit=(uint8_t*)malloc(total_lit);
    uint8_t* raw_off=(uint8_t*)malloc(total_off);
    uint8_t* raw_len=(uint8_t*)malloc(total_len);
    uint8_t* raw_cmd=(uint8_t*)malloc(total_cmd);
    size_t ol=0,oo=0,on=0,oc=0;
    boffs.resize(results.size());
    for (size_t i=0;i<results.size();i++) {
        boffs[i].lit_off=ol; boffs[i].lit_sz=results[i].lit_size;
        boffs[i].off_off=oo; boffs[i].off_sz=results[i].off_size;
        boffs[i].len_off=on; boffs[i].len_sz=results[i].len_size;
        boffs[i].cmd_off=oc; boffs[i].cmd_sz=results[i].cmd_size;
        memcpy(raw_lit+ol,results[i].lit_buf,results[i].lit_size); ol+=results[i].lit_size;
        memcpy(raw_off+oo,results[i].off_buf,results[i].off_size); oo+=results[i].off_size;
        memcpy(raw_len+on,results[i].len_buf,results[i].len_size); on+=results[i].len_size;
        memcpy(raw_cmd+oc,results[i].cmd_buf,results[i].cmd_size); oc+=results[i].cmd_size;
        free(results[i].lit_buf);free(results[i].off_buf);
        free(results[i].len_buf);free(results[i].cmd_buf);
    }

    size_t zls,zos,zns,zcs;
    uint8_t *zl=lit_compress(raw_lit,total_lit,zls);
    uint8_t *zo,*zn,*zc;
    entropy_encode(raw_lit,total_lit,raw_off,total_off,raw_len,total_len,raw_cmd,total_cmd,
                   zl,zls,zo,zos,zn,zns,zc,zcs);
    free(raw_lit);free(raw_off);free(raw_len);free(raw_cmd);

    AetHeader hdr;
    memcpy(hdr.magic,"ACEPX2\0\0",8);
    hdr.version=2; hdr.orig_size=total_size;
    hdr.block_size=(uint32_t)CHUNK_SIZE; hdr.num_blocks=(uint32_t)results.size();
    uint64_t hv=0; memcpy(hdr.xxhash,&hv,8); // checksum skip for now
    hdr.zlit_sz=zls;hdr.zoff_sz=zos;hdr.zlen_sz=zns;hdr.zcmd_sz=zcs;

    FILE* fout=fopen(out_path,"wb");
    fwrite(&hdr,sizeof(hdr),1,fout);
    fwrite(boffs.data(),sizeof(BlockOffsets),results.size(),fout);
    fwrite(zl,1,zls,fout);fwrite(zo,1,zos,fout);
    fwrite(zn,1,zns,fout);fwrite(zc,1,zcs,fout);
    fclose(fout);

    size_t total_z=zls+zos+zns+zcs;
    fprintf(stderr,"  Ratio:  %.5fx\n",(double)total_size/total_z);
    fprintf(stderr,"  RAM:    ~%.0f MB (window only)\n", win_size/1e6);

    free(window);free(ht->pos);free(ht->epoch);free(ht->chain);free(ht);
    free(zl);free(zo);free(zn);free(zc);
    return 0;
}

int main(int argc, char** argv) {
    if (argc<4) { fprintf(stderr,"Usage: %s c --in <in> --out <out>\n",argv[0]); return 1; }
    const char* in=nullptr; const char* out=nullptr; int level=2;
    for(int i=2;i<argc;i++) {
        if (!strcmp(argv[i],"--in")&&i+1<argc) in=argv[++i];
        else if (!strcmp(argv[i],"--out")&&i+1<argc) out=argv[++i];
    }
    return encode_streaming_file(in, out, 1, level);
}
