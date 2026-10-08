import sys, subprocess, os
sys.path.insert(0, '.'); import specdec as S
W = os.path.expanduser('~/pubrepo/.wk/repro_g1c'); R, rs = S.load_ref(W + '/data/reference.fa'); tot = bad = 0
for f in sorted(os.listdir(W + '/arch')):
    X = S.open_archive(open(W + '/arch/' + f, 'rb').read(), R, rs); mine = []
    for b in range(X.nb):
        ops = []; S.decode_block(X, b, ops=ops)
        for o in ops:
            k = {'literal': 0, 'self': 2}.get(o[0]); 
            if k == 0: mine.append((b, 0, o[1], o[2]))
            elif k == 2: mine.append((b, 2, o[1] - o[3], o[1], o[2]))
            else: mine.append((b, 3 if o[4] else 1, o[3], o[1], o[2]))
    ref = []
    for l in subprocess.run([W + '/opdump', W + '/data/reference.fa', W + '/arch/' + f], capture_output=True, text=True).stdout.split('\n'):
        if not l: continue
        b, k, s, d, n = map(int, l.split()); ref.append((b, 0, d, n) if k == 0 else (b, k, s, d, n))
    tot += len(ref); bad += mine != ref
    print(f, len(ref), 'ops', 'EQUAL' if mine == ref else 'DIFFER')
print('archives with differing ops:', bad, '; ops total', tot)
