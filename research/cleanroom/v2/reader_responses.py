"""reader_responses.py <tmp dir> <reference> <archive>... - response of the v1 reader with the two stricter checks
(panvram CPU path) to each archive: refused at open, failed on decode, or decoded (FASTA SHA-256). JSON lines on stdout.
Run with the panvram environment's python. Not shipped."""
import hashlib, json, os, sys
import panvram

T, ref = sys.argv[1], os.path.abspath(sys.argv[2])
for k, a in enumerate(sys.argv[3:]):
    d = os.path.join(T, "case%d" % k); os.makedirs(d, exist_ok=True)
    link = os.path.join(d, "x.q4k.rr3")
    if not os.path.lexists(link): os.symlink(os.path.abspath(a), link)
    r = {"archive": os.path.basename(a)}
    try: c = panvram.Cohort.open(d, device="cpu", dataset="q4k", reference=ref)
    except Exception as e: r.update(stage="open", refused=True, message=str(e)); print(json.dumps(r)); continue
    try:
        fa = c.fasta("x"); r.update(stage="decoded", refused=False, fasta_sha256=hashlib.sha256(fa).hexdigest())
    except Exception as e: r.update(stage="decode", refused=True, message=str(e))
    print(json.dumps(r)); del c
