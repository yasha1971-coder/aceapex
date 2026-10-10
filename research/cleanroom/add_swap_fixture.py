"""add_swap_fixture.py - the swapped-blocks refusal case, run after add_hash_fixtures.py (whose own search over asmA finds
no usable pair): payload blocks 64 and 67 of asmC.q4k.hash.rr3 (both 5 B) swapped, block table and header untouched;
the frozen tool decodes both rANS streams and refuses on the block XXH3 (found by the same search over asmC: 1 of 1 289
equal-length pairs). Drops add_hash_fixtures' "not produced" note and appends the case to EXPECTED.json."""
import json, os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import add_hash_fixtures as H

P = H.P; exp = json.load(open(os.path.join(P, 'EXPECTED.json')))
exp['notes'] = [n for n in exp.get('notes', []) if not n.startswith('blocks_swapped')]
if not exp['notes']: exp.pop('notes')
src = os.path.join(H.A, 'asmC.q4k.hash.rr3'); g = H.geometry(src); base = open(src, 'rb').read()
blk = {i: (off, ln) for i, off, ln in g['blocks']}
(oi, li), (oj, lj) = blk[64], blk[67]; assert li == lj == 5
b = bytearray(base); b[oi:oi+li], b[oj:oj+lj] = base[oj:oj+lj], base[oi:oi+li]
path = os.path.join(P, 'corrupt', 'blocks_swapped.rr3'); open(path, 'wb').write(bytes(b))
code, msg, made = H.tool(path)
exp['corrupt'].append({'archive': 'corrupt/blocks_swapped.rr3', 'reference': 'reference/reference.fa', 'expect': 'refuse',
  'how': 'asmC.q4k.hash.rr3: payload blocks 64 and 67 (both 5 B) swapped; block table and header untouched; both rANS streams decode',
  'tool_response': {'exit': code, 'message': msg, 'output_written': made}})
json.dump(exp, open(os.path.join(P, 'EXPECTED.json'), 'w'), indent=1)
print(code, msg, made, len(exp['corrupt']), 'corrupt entries')
