# PROTOCOL_CORRUPTION_APPLIED (M4) - one flipped bit in storage, per format, in use

Status: draft. Frozen before M4 (SHA-256 in `corruption/PROTOCOL_CORRUPTION_APPLIED.sha256`).

## 1. Stored objects (one assembly: HPRC HG00438.1)

| format | object(s) flipped | the user's task after the flip |
|---|---|---|
| FASTA BGZF (bgzip default, level 6) + `.fai` + `.gzi` | the `.gz` | 100 fixed regions via `faidx_fetch_seq64` + full decode (`bgzip -d`) |
| ACEAPEX 2.2.2 default archive | the `.aet` | the same 100 regions via `aceapex_decompress_region` + full decode (`aceapex_decompress`, header XXH3 checked) |
| refrel3 v1 q4k (with block XXH3) | the `.rr3` | the same 100 regions (window decode) + full decode with every check |
| AGC 3.2.4 (`agc create -d` T2T + HG00438.1, options of M1) | the `.agc` | the same 100 regions (`agc getctg`) + `agc getset` |

Regions: 100 regions of 1 000 - 100 000 bases of HG00438.1, `random.Random(20261009)`, written before the run.

## 2. Flips

- 100 positions per object: uniform byte position x bit in [0, size) x [0, 8), `random.Random(20261010 + format index)`;
  one bit per case, on a private copy (copy -> flip -> task -> delete); the clean object's SHA-256 checked before each case.
- Watchdog: 60 s per case (task process killed -> "hang").

## 3. Outcome per case

| outcome | meaning |
|---|---|
| refused | the tool reports an error before returning any answer bytes (open / header / index check) |
| caught | the task reports an error for at least one request / the full decode, and every answer it did return == truth |
| harmless | every answer and the full decode == truth, no error |
| SILENT | some returned answer or the full decode != truth with no error reported |
| crash | killed by a signal other than the watchdog's |
| hang | watchdog |

Truth: SHA-256 of the 100 regions and of the full FASTA from the uncompressed source (P5). Reported: counts per outcome
and format, positions of every SILENT case, tool versions.
