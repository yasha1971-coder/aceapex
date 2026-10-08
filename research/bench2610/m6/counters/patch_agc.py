"""patch_agc.py <copy of agc src/> - event counters for the hypotheses H1-H5 of G1, in a COPY of AGC e67e3fc sources
(the timed build is never patched). Each insertion is checked to apply exactly once."""
import sys
S = sys.argv[1]
def patch(rel, pairs):
    p = S + "/" + rel; s = open(p).read()
    for a, b in pairs:
        assert s.count(a) == 1, (rel, a[:60]); s = s.replace(a, b)
    open(p, "w").write(s)
patch("common/agc_decompressor_lib.cpp", [
 ("""	contig_task_t task{ id++, "", name_range_t(full_contig_name, start, end), contig_desc };""",
  """	AGCCNT("gcs_calls", 1);\n	contig_task_t task{ id++, "", name_range_t(full_contig_name, start, end), contig_desc };"""),
 ("""	contig_data.clear();
	contig_data.reserve(ctg.size());
	for (auto& c : ctg)
		contig_data.push_back(cnv_num[static_cast<uint8_t>(c)]);""",
  """	contig_data.clear();
	AGCCNT("conv_bytes", ctg.size());
	contig_data.reserve(ctg.size());
	for (auto& c : ctg)
		contig_data.push_back(cnv_num[static_cast<uint8_t>(c)]);"""),
 ("""	name_range_t &contig_name_range = contig_desc.name_range;
	vector<contig_t> v_segments_loc;

	bool need_free_zstd = false;
""", """	name_range_t &contig_name_range = contig_desc.name_range;
	vector<contig_t> v_segments_loc;
	AGCCNT("dc_calls", 1); AGCCNT(fast ? "dc_fast_true" : "dc_fast_false", 1); AGCCNT("dc_desc_segments", contig_desc.segments.size());

	bool need_free_zstd = false;
"""),
 ("""	for (auto seg : contig_desc.segments)
	{
		int32_t seg_len = seg.raw_length;

		if (curr_pos + seg_len < from)
		{
			from -= seg_len - kmer_length;
			to -= seg_len - kmer_length;
			continue;
		}
		else if (curr_pos > to)
			break;

		if(!fast)
			decompress_segment(seg.group_id, seg.in_group_id, ctg, zstd_ctx);
		else
			decompress_segment_fast(seg.group_id, seg.in_group_id, ctg, zstd_ctx);

		if (seg.is_rev_comp)
			reverse_complement(ctg);

		v_segments_loc.emplace_back(move(ctg));

		curr_pos += seg_len - kmer_length;
	}

	if (!v_segments_loc.empty())
	{""", """	for (auto seg : contig_desc.segments)
	{
		int32_t seg_len = seg.raw_length;
		AGCCNT("dc_desc_scanned", 1);

		if (curr_pos + seg_len < from)
		{
			from -= seg_len - kmer_length;
			to -= seg_len - kmer_length;
			continue;
		}
		else if (curr_pos > to)
			break;

		AGCCNT("dc_seg_decoded", 1); AGCCNT("dc_seg_raw_len", seg_len); AGCCNT(seg.in_group_id == 0 ? "dc_seg_is_group_ref" : "dc_seg_is_delta", 1);
		if(!fast)
			decompress_segment(seg.group_id, seg.in_group_id, ctg, zstd_ctx);
		else
			decompress_segment_fast(seg.group_id, seg.in_group_id, ctg, zstd_ctx);

		if (seg.is_rev_comp)
			{ AGCCNT("dc_seg_revcomp", 1); reverse_complement(ctg); }

		v_segments_loc.emplace_back(move(ctg));

		curr_pos += seg_len - kmer_length;
	}

	if (!v_segments_loc.empty())
	{"""),
 ("""		if (ctg.size() > (uint64_t)to + 1)
			ctg.resize((uint64_t)to + 1);

		if (from != 0)
			ctg.erase(ctg.begin(), ctg.begin() + from);""",
  """		AGCCNT("dc_assembled_bytes", ctg.size());
		if (ctg.size() > (uint64_t)to + 1)
			ctg.resize((uint64_t)to + 1);

		if (from != 0)
			ctg.erase(ctg.begin(), ctg.begin() + from);
		AGCCNT("dc_returned_bytes", ctg.size());"""),
])
patch("common/collection_v3.cpp", [
 ("""	if (sample_desc[p->second].contigs.empty())
		load_batch_contig_names(p->second / batch_size);

	if (sample_desc[p->second].contigs.empty() || sample_desc[p->second].contigs.front().segments.empty())
		load_batch_contig_details(p->second / batch_size);
	
	for (auto& x : sample_desc[p->second].contigs)
	{
		if (extract_contig_name(x.name) == short_contig_name)
		{
			contig_desc = x.segments;""",
  """	AGCCNT("desc_calls", 1);
	if (sample_desc[p->second].contigs.empty())
		{ AGCCNT("desc_batch_names_load", 1); load_batch_contig_names(p->second / batch_size); }

	if (sample_desc[p->second].contigs.empty() || sample_desc[p->second].contigs.front().segments.empty())
		{ AGCCNT("desc_batch_details_load", 1); load_batch_contig_details(p->second / batch_size); }
	
	for (auto& x : sample_desc[p->second].contigs)
	{
		AGCCNT("desc_contigs_scanned", 1);
		if (extract_contig_name(x.name) == short_contig_name)
		{
			AGCCNT("desc_segments_copied", x.segments.size());
			contig_desc = x.segments;"""),
 ("""void CCollection_V3::clear_batch_contig(size_t id_batch)
{""", """void CCollection_V3::clear_batch_contig(size_t id_batch)
{
	AGCCNT("batch_clear", 1);"""),
])
patch("common/segment.cpp", [
 ("""    lz_diff->Decode(ref_seq, delta_seq, ctg);""",
  """    AGCCNT("lz_decode_calls", 1); AGCCNT("lz_ref_bytes", ref_seq.size()); AGCCNT("lz_delta_bytes", delta_seq.size());
    lz_diff->Decode(ref_seq, delta_seq, ctg);
    AGCCNT("lz_out_bytes", ctg.size());"""),
 ("""bool CSegment::get_raw(const uint32_t id_seq, contig_t& ctg, ZSTD_DCtx* zstd_ctx)
{""", """bool CSegment::get_raw(const uint32_t id_seq, contig_t& ctg, ZSTD_DCtx* zstd_ctx)
{
    AGCCNT("seg_get_raw_calls", 1);"""),
 ("""bool CSegment::get(const uint32_t id_seq, contig_t& ctg, ZSTD_DCtx* zstd_ctx)
{""", """bool CSegment::get(const uint32_t id_seq, contig_t& ctg, ZSTD_DCtx* zstd_ctx)
{
    AGCCNT("seg_get_calls", 1); AGCCNT(id_seq == 0 ? "seg_get_ref_only" : "seg_get_delta", 1);"""),
])
print("patched")
