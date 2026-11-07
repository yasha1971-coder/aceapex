#!/usr/bin/env python3
"""Checks the script embedded in .github/workflows/watch-judges.yml (CI job watch-judges-check).
1) it is extracted (text between the "python3 - <<'PY'" line and the closing "PY" line, 8-space indent removed) and
   compiled; 2) its TB-TABLE parser runs on three saved benchmark.md files, with no network:
   normal  (be36e1d, names "aceapex-fast"), renamed (1c02a50, the same numbers, names "aceapex\\_fast"),
   broken  (7f0ad5b, every codec name replaced by escaped underscores);
3) normal -> renamed gives no notice (name normalization), broken raises (the item keeps its last value).
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
def load(name):
    md = open(os.path.join(FX, name)).read()
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

try:
    load("benchmark-broken-7f0ad5b.md"); fails.append("broken: no error raised")
except RuntimeError as e:
    print(f"4 broken markup: RuntimeError ({e})")

if fails:
    print("FAIL:\n- " + "\n- ".join(fails)); sys.exit(1)
print("watch-judges check: pass")
