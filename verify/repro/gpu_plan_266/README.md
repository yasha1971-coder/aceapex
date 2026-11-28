# gpu_plan_266 — the GPU host plan refuses what the CPU decoders refuse since 2.6.6 (2.6.7, PORT-266)

No archives of its own. `gpu_plan_266_test.cpp` builds the GPU library's host plan (`agp::build`, `src/aceapex_gpu_plan.h`)
of the 2.6.6 regression archives (`verify/repro/hdr_version`, `boffs_contig`, `stream_hdr`, `dna_exc`) and of the
version-2 conformance fixtures:
- refused before 2.6.7: the 8 header versions (E_HEADER), the 2 literal stored sizes with bit 63 and the DNA pack without
  exception frames (E_STREAM);
- refused since 2.6.7: the 3 block tables whose slices do not follow each other (E_TABLE), bit 63 of a token stream's first
  word and a tagged literal stream without the chunked layout (E_STREAM).
Negative control `-DAX_BOFFS_CONTIG_NO_CHECK -DAX_STREAM_HDR_NO_CHECK` (the plan of 2.6.6): the 5 new ones build a plan.
The device kernels are not run here (no GPU on the judge host); the GPU decode of the J3 mutants is a pod task.
