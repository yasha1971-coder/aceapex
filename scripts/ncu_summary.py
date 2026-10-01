#!/usr/bin/env python3
# ncu_summary.py - one line per kernel (first launch of each kernel name + grid) from `ncu --csv --page details`:
# where the kernel is bound - DRAM / memory pipes against SM throughput, occupancy achieved against theoretical,
# global load and store sectors per request (coalescing: 4 = 32-bit words of 32 lanes in 4 sectors), warp stall
# reasons (% of active warps). Usage: ncu_summary.py <ncu.csv> <label>
import csv, sys
rows = list(csv.reader(open(sys.argv[1], errors='replace')))
hdr = next((r for r in rows if 'Kernel Name' in r and 'Metric Name' in r), None)
if not hdr:
    print(f"ncu {sys.argv[2]}: no metrics (ncu output not CSV - see the log above)"); sys.exit(0)
ix = {k: hdr.index(k) for k in hdr}
gk = 'Grid Size' if 'Grid Size' in ix else None
kern = {}; order = []
for r in rows[rows.index(hdr) + 1:]:
    if len(r) != len(hdr): continue
    key = (r[ix['ID']], r[ix['Kernel Name']].split('(')[0], r[ix[gk]] if gk else '')
    if key not in kern: kern[key] = {}; order.append(key)
    kern[key][r[ix['Metric Name']]] = (r[ix['Metric Value']].replace(',', ''), r[ix['Metric Unit']])
seen = set()
want = [('Duration', 'dur'), ('DRAM Throughput', 'dram%'), ('Memory Throughput', 'mem%'), ('Compute (SM) Throughput', 'sm%'),
        ('Achieved Occupancy', 'occ%'), ('Theoretical Occupancy', 'theo%'), ('Registers Per Thread', 'regs'),
        ('L1/TEX Hit Rate', 'L1hit%'), ('L2 Hit Rate', 'L2hit%'), ('Warp Cycles Per Issued Instruction', 'cyc/issue')]
stalls = [('long_scoreboard', 'LSB'), ('barrier', 'bar'), ('short_scoreboard', 'SSB'), ('lg_throttle', 'lg'), ('mio_throttle', 'mio'), ('wait', 'wait')]
print(f"== ncu {sys.argv[2]}: first launch of each kernel (grid); stalls in % of active warps")
for key in order:
    name = key[1] + (f" grid {key[2]}" if key[2] else '')
    if (key[1], key[2]) in seen: continue
    seen.add((key[1], key[2])); m = kern[key]
    def g(n):
        v = m.get(n); return v[0] + ('' if v[1] in ('%', '', 'register/thread', 'cycle') else v[1]) if v else '-'
    parts = [f"{lab} {g(n)}" for n, lab in want]
    def ratio(a, b):
        try: return f"{float(m[a][0]) / float(m[b][0]):.1f}"
        except Exception: return '-'
    parts.append("ld sect/req " + ratio('l1tex__t_sectors_pipe_lsu_mem_global_op_ld.sum', 'l1tex__t_requests_pipe_lsu_mem_global_op_ld.sum'))
    parts.append("st sect/req " + ratio('l1tex__t_sectors_pipe_lsu_mem_global_op_st.sum', 'l1tex__t_requests_pipe_lsu_mem_global_op_st.sum'))
    st = [f"{lab} {float(m[k][0]):.0f}" for s, lab in stalls for k in [f"smsp__warp_issue_stalled_{s}_per_warp_active.pct"] if k in m]
    if st: parts.append("stalls " + " ".join(st))
    print(f"ncu {sys.argv[2]} {name}: " + ", ".join(parts))
