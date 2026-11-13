#!/usr/bin/env bash
# verify.sh — every published claim judged from the exact sources it was made with.
# Each tag is checked out into a detached worktree and judged by verify/judges/<tag>.sh
# from main: tags stay immutable, judges can improve. One results/<tag>.json per tag,
# carrying provenance and one record per claim (claim_id, level, expected, tolerance,
# measured, verdict, command). Usage: ./verify.sh [tag ...]   (default: verify/manifest.tsv)
# A tag passes only when its judge exits 0, every claim_id of verify/expected/<tag>.tsv is present (rows marked golden
# only when $GOLDEN/genome/chr1.fa exists, golden:<path> when $GOLDEN/<path> exists) and no record fails; only then results/<tag>.json is written, otherwise
# results/<tag>.failed.json (and results/<tag>.json is removed). scripts/verify_selftest.sh checks these rules
# (JUDGE_DIR / EXPECT_DIR point it at its own judges).
set -uo pipefail
ROOT=$(cd "$(dirname "$0")" && pwd); cd "$ROOT"
OUT=${OUT:-$ROOT/results}; WT=${WT:-/tmp/aceapex-verify}; mkdir -p "$OUT" "$WT"
TAGS=${*:-$(awk '!/^#/ && NF{print $1}' verify/manifest.tsv)}
FAILS=0; printf '%-14s %5s %5s %8s %9s %8s %6s\n' tag pass fail skipped declared unjudged known
for T in $TAGS; do
  J="${JUDGE_DIR:-$ROOT/verify/judges}/$T.sh"; E="${EXPECT_DIR:-$ROOT/verify/expected}/$T.tsv"; D="$WT/$T"; R="$D/_records.json"
  if [ ! -f "$J" ]; then printf '%-14s no judge\n' "$T"; continue; fi
  if [ "$T" != HEAD ] && ! git rev-parse -q --verify "refs/tags/$T^{commit}" >/dev/null; then printf '%-14s no tag\n' "$T"; continue; fi
  if [ "$T" = HEAD ]; then D="$ROOT"; R="$WT/HEAD_records.json"; else
    git worktree remove --force "$D" >/dev/null 2>&1 || true
    git worktree add --detach -q "$D" "$T"; fi
  rm -f "$R"   # records of an earlier run must not stand in for this one (HEAD_records.json of 08.11 did until 13.11)
  rm -f "$OUT/$T.json" "$OUT/$T.failed.json" "$OUT/$T.json.tmp"
  ( cd "$D" && ROOT="$ROOT" RECORDS="$R" GOLDEN="${GOLDEN:-$HOME/golden}" bash "$J" ) >"$WT/$T.log" 2>&1; JRC=$?
  [ $JRC = 0 ] || echo "$T: judge exit $JRC (see $WT/$T.log)"
  if [ ! -s "$R" ]; then echo '{"records":[]}' >"$R"; echo "$T: judge wrote no records (see $WT/$T.log)"; [ $JRC = 0 ] && JRC=99; fi
  GOLDEN="${GOLDEN:-$HOME/golden}" python3 - "$T" "$(git rev-parse "$T^{commit}")" "$R" "$OUT/$T.json.tmp" "$E" <<'PY'
import sys,json,subprocess,datetime,platform
tag,sha,rec,out,exp=sys.argv[1:]
body=json.load(open(rec))
def walk(o):
    if isinstance(o,dict):
        if "verdict" in o: yield o
        for v in o.values(): yield from walk(v)
    elif isinstance(o,list):
        for v in o: yield from walk(v)
recs=list(walk(body))
zv=(lambda h:".".join(next((l.split()[2] for l in h if l.startswith("#define ZSTD_VERSION_"+k)),"?") for k in ("MAJOR","MINOR","RELEASE")))(next((open(d+"/zstd.h").read().splitlines() for d in ("/usr/include","/usr/local/include") if __import__("os").path.exists(d+"/zstd.h")),[]))
# known deviations: a fail listed in verify/known/<tag>.tsv with a condition that holds here
# (e.g. libzstd!=1.4.8) becomes known-deviation, kept visible in its own column, never hidden.
import os
kf="verify/known/%s.tsv"%tag
if os.path.exists(kf):
    for line in open(kf):
        if line.startswith("#") or not line.strip(): continue
        cid,cond,reason=line.rstrip("\n").split("\t")[:3]
        k,op,val=cond.replace("!=","\t!=\t").replace("==","\t==\t").split("\t")
        cur={"libzstd":zv}.get(k,"")
        if (op=="!=" and cur!=val) or (op=="==" and cur==val):
            for r in recs:
                if r.get("claim_id")==cid and r.get("verdict")=="fail": r["verdict"]="known-deviation"; r["deviation"]="%s: %s"%(cond,reason)
vs=[r["verdict"] for r in recs]; c=lambda v: vs.count(v)
prov={"tag":tag,"commit":sha,"date":datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%MZ"),
      "host":platform.node(),"machine":platform.machine(),"cores":__import__("os").cpu_count(),
      "libzstd":zv,
      "compiler":subprocess.run(["g++","--version"],capture_output=True,text=True).stdout.split("\n")[0],
      "pass":c("pass"),"fail":c("fail"),"skipped":sum(c(v) for v in ("skipped-no-gpu","skipped-no-corpus","skipped-no-tool")),
      "declared":c("declared"),"unjudged":c("unjudged"),"known":c("known-deviation"),"build_failed":c("build-failed")}
# the required claim set: a judge that stops early, or a block that prints nothing, leaves a claim missing
missing=[]
if os.path.exists(exp):
    have={r.get("claim_id") for r in recs}; golden=os.path.exists(os.environ.get("GOLDEN","")+"/genome/chr1.fa")
    for line in open(exp):
        if line.startswith("#") or not line.strip(): continue
        cid,cond=(line.rstrip("\n").split("\t")+["always"])[:2]
        g=os.environ.get("GOLDEN","")   # golden:<path> = required when $GOLDEN/<path> exists (a corpus of the contract)
        need=cond=="always" or (cond=="golden" and golden) or (cond.startswith("golden:") and os.path.exists(g+"/"+cond[7:]))
        if need and cid not in have: missing.append(cid)
prov["missing"]=missing
json.dump({"provenance":prov,"result":body},open(out,"w"),indent=1)
print("%-14s %5d %5d %8d %9d %8d %6d"%(tag,prov["pass"],prov["fail"],prov["skipped"],prov["declared"],prov["unjudged"],prov["known"]))
if missing: print("%s: %d required claims missing: %s"%(tag,len(missing)," ".join(missing[:20])))
sys.exit(1 if prov["fail"] or prov["build_failed"] or missing else 0)
PY
  PRC=$?
  if [ $JRC = 0 ] && [ $PRC = 0 ]; then mv "$OUT/$T.json.tmp" "$OUT/$T.json"
  else FAILS=$((FAILS+1)); [ -f "$OUT/$T.json.tmp" ] && mv "$OUT/$T.json.tmp" "$OUT/$T.failed.json"
    echo "$T: FAIL (judge exit $JRC, records check $PRC) -> $OUT/$T.failed.json"; fi
done
echo "results in $OUT; worktrees in $WT"; [ "$FAILS" = 0 ]
