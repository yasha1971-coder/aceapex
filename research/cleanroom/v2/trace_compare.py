"""trace_compare.py <work> <trace binary> <TEST_VECTORS.json> - see trace_check.sh."""
import json, os, subprocess, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__))); import specdec as S
W, T, TV = sys.argv[1:4]
AB = sys.argv[4]; d = json.load(open(TV)); tot = bad = 0
for fx in d['fixtures']:
    f = fx['archive'].split('/')[1]; adir, rp = (W + '/arch', W + '/data/reference.fa') if 'reference_abs' not in fx['reference'] else (AB, AB + '/reference_abs.fa')
    R, rs = S.load_ref(rp); X = S.open_archive(open(adir + '/' + f, 'rb').read(), R, rs)
    for bv in fx['blocks']:
        b = bv['block']; tr = []; S.decode_block(X, b, trace=tr)
        mine = [('I', t['x']) if t['event'] == 'init' else ('S', t['ctx'], t['sym'], t['x'], t['pos']) if t['event'] == 'symbol' else ('B', t['n'], t['value'], t['x'], t['pos']) for t in tr]
        ref = [tuple([p[0]] + [int(x) for x in p[1:]]) for p in (l.split() for l in subprocess.run([T, rp, adir + '/' + f, str(b)], capture_output=True, text=True).stdout.split('\n')) if p and p[0] != 'N']
        vec = [('I', bv['rans_init_state'])] + [tuple(['S' if v['event'] == 'symbol' else 'B'] + list(v.values())[1:]) for v in bv['rans_events_first'][1:]]
        ok = mine == ref and vec == ref[:len(vec)]; bad += not ok; tot += len(ref)
        print(f, 'block', b, len(ref), 'events', 'EQUAL' if ok else 'DIFFER')
print('events compared', tot, 'blocks differing', bad); sys.exit(1 if bad else 0)
