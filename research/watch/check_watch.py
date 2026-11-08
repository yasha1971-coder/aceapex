#!/usr/bin/env python3
"""Checks the script embedded in .github/workflows/watch-judges.yml (CI job watch-judges-check).
1) it is extracted (text between the "python3 - <<'PY'" line and the closing "PY" line, 8-space indent removed) and
   compiled; 2) its TB-TABLE parser runs on three saved benchmark.md files, with no network:
   normal  (be36e1d, names "aceapex-fast"), renamed (1c02a50, the same numbers, names "aceapex\\_fast"),
   broken  (7f0ad5b, every codec name replaced by escaped underscores),
   broken2 (87f1f88, names overwritten by fragments: "zlib 1urbo 12", "memcpyx\\\\_fast 1", "aceapex\\\\_fast");
3) normal -> renamed gives no notice (name normalization), broken and broken2 raise (an item error: the item keeps
   its last value and sends no notice); a normal table with one name "lzav 1x_fast 8" raises (name form guard);
   norm() removes any number of backslashes.
Exit 1 on any failure."""
import ast, os, sys
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
WF = os.path.join(ROOT, ".github/workflows/watch-judges.yml")
FX = os.path.join(ROOT, "research/watch/fixtures")

lines = open(WF).read().split("\n")
a = next(i for i, l in enumerate(lines) if l.strip() == "python3 - <<'PY'")
b = next(i for i in range(len(lines) - 1, a, -1) if lines[i].strip() == "PY")
src = "\n".join(l[8:] if l.startswith("        ") else l for l in lines[a + 1:b])
ast.parse(src)
print("1 embedded script: extracted and compiled,", len(src.splitlines()), "lines")

ns = {"__name__": "watch_check"}
exec(compile(src, "watch-judges.yml", "exec"), ns)
def load(name, edit=None):
    md = open(os.path.join(FX, name), encoding="utf-8").read()
    if edit: md = edit(md)
    ns["raw"] = lambda path: md
    return ns["item_tb"]()

fails = []
normal = load("benchmark-normal-be36e1d.md")
renamed = load("benchmark-renamed-1c02a50.md")
want = {"linux-aarch64 #1", "macos-aarch64 #1", "windows-x86_64 #1"}
names = {r["name"] for t in normal.values() for r in t["aceapex"]}
if set(normal) != want or names != {"aceapex_fast 1", "aceapex_fast 8"}:
    fails.append(f"normal: tables {sorted(normal)}, names {sorted(names)}")
D = {(k, r["name"]): r["D"] for k, t in normal.items() for r in t["aceapex"]}
D2 = {(k, r["name"]): r["D"] for k, t in renamed.items() for r in t["aceapex"]}
if D != D2:
    fails.append(f"renamed: rows differ after normalization {sorted(set(D) ^ set(D2))}")
print(f"2 normal: {len(normal)} tables, names {sorted(names)}; renamed: same rows and D after normalization: {D == D2}")

old_style = {k: {**t, "aceapex": [{**r, "name": r["name"].replace("_", "-")} for r in t["aceapex"]]} for k, t in normal.items()}
ref = {f"{k}|aceapex-fast {r['name'][-1]}": r["D"] for k, t in normal.items() for r in t["aceapex"]}
ref = {k.split("|", 1)[0] + "|" + ns["norm"](k.split("|", 1)[1]): d for k, d in ref.items()}
notes = ns["tb_notices"](old_style, renamed, ref)
if notes: fails.append(f"normal (old names) -> renamed: unexpected notice {notes}")
print(f"3 old names in the state -> renamed table: notices {notes or 'none'}")

for n, (label, name, edit) in enumerate([
        ("broken markup 7f0ad5b", "benchmark-broken-7f0ad5b.md", None),
        ("broken markup 87f1f88", "benchmark-broken2-87f1f88.md", None),
        ("negative control: normal table, one name 'lzav 1x_fast 8'", "benchmark-normal-be36e1d.md",
         lambda md: md.replace("|lzav 1|", "|lzav 1x_fast 8|", 1))], 4):
    try:
        load(name, edit); fails.append(f"{label}: no error raised")
    except RuntimeError as e:
        print(f"{n} {label}: RuntimeError ({e})")

got = [ns["norm"](x) for x in ("aceapex-fast 1", "aceapex\\_fast 1", "aceapex\\\\_fast 1", "aceapex\\\\\\_fast 1")]
if set(got) != {"aceapex_fast 1"}: fails.append(f"norm: {got}")
print(f"7 norm with 0-3 backslashes: {sorted(set(got))}")

if fails:
    print("FAIL:\n- " + "\n- ".join(fails)); sys.exit(1)
print("watch-judges check: pass")
