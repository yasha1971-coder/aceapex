#!/usr/bin/env bash
# Cross-version fixtures: a 4 MiB slice of chr1 (offset 100 MiB) archived on known libzstd
# versions, kept in verify/fixtures. Each fixture is decoded here and checked by sha256, then
# the decoded slice is re-encoded and compared with the fixture that matches this host's
# libzstd (the fixtures predate ADR-020: re-encoded with the chain matcher, AX_ENC=chain). No corpus needed. Output lines: claim_id <TAB> verdict <TAB> measured
set -uo pipefail; shopt -s nullglob
B=${BIN:-./aceapex}; F=verify/fixtures; EXP=$(cat $F/chr1_4MiB.sha256); T=$(mktemp -d)
ZV=$(for d in /usr/include /usr/local/include; do [ -f $d/zstd.h ] || continue
  awk '/#define ZSTD_VERSION_(MAJOR|MINOR|RELEASE) /{v=v (v?".":"") $3} END{print v}' \
    $d/zstd.h; break; done)
for a in $F/chr1_4MiB.zstd-*.aet; do
  v=${a##*zstd-}; v=${v%.aet}
  env -i PATH="$PATH" $B d --in $a --out $T/o_$v --threads 2 >/dev/null 2>&1
  got=$(sha256sum $T/o_$v 2>/dev/null | cut -c1-64)
  [ "$got" = "$EXP" ] && r=pass || r=fail
  printf 'head_fixture_decode_zstd_%s\t%s\tsha256 %s.. on host libzstd %s\n' \
    "$v" "$r" "${got:0:16}" "$ZV"
done
if [ -f $F/chr1_4MiB.zstd-$ZV.aet ] && [ -s $T/o_$ZV ]; then
  env -i PATH="$PATH" AX_ENC=chain ACEAPEX_BS=16384 LIT_CHUNK=65536 FSE_CHUNK=4096 $B c --in $T/o_$ZV \
    --out $T/re.aet --threads 2 >/dev/null 2>&1
  cmp -s $T/re.aet $F/chr1_4MiB.zstd-$ZV.aet && r=pass || r=fail
  printf 'head_fixture_encode_determinism\t%s\tre-encode of decoded slice == fixture, libzstd %s\n' \
    "$r" "$ZV"
else
  printf 'head_fixture_encode_determinism\tdeclared\tno fixture for host libzstd %s yet\n' "$ZV"
fi
# empty archive: one header, num_blocks 0 (28.09). Decode gives 0 bytes; encode of an empty
# input reproduces the fixture byte for byte on every libzstd (no zstd frames inside).
if [ -f $F/empty.aet ]; then
  : > $T/e0; env -i PATH="$PATH" $B d --in $F/empty.aet --out $T/e0.out --threads 2 >/dev/null 2>&1
  [ "$(stat -c%s $T/e0.out 2>/dev/null)" = 0 ] && r=pass || r=fail
  printf 'head_fixture_empty_decode\t%s\tempty.aet -> %s bytes\n' "$r" "$(stat -c%s $T/e0.out 2>/dev/null)"
  env -i PATH="$PATH" $B c --in $T/e0 --out $T/e0.aet --threads 2 >/dev/null 2>&1
  cmp -s $T/e0.aet $F/empty.aet && r=pass || r=fail
  printf 'head_fixture_empty_encode\t%s\tencode of 0 bytes == empty.aet (68 B)\n' "$r"
fi
# conformance set (docs/FORMAT_ACEPX2.md s7): every archive in verify/fixtures/conf decodes to the
# sha256 in the manifest; the 4th column is the decode environment a LEGACY archive needs.
if [ -f $F/conf/manifest.tsv ]; then
  ok=0; n=0; bad=""
  while IFS=$'\t' read -r name sz sha denv; do
    n=$((n+1)); E=""; [ "$denv" != "-" ] && E="$denv"
    env -i PATH="$PATH" $E $B d --in $F/conf/$name.aet --out $T/c_$name --threads 2 >/dev/null 2>&1
    got=$(sha256sum $T/c_$name 2>/dev/null | cut -c1-64)
    if [ "$got" = "$sha" ]; then ok=$((ok+1)); else bad="$bad $name"; fi
  done < $F/conf/manifest.tsv
  [ $n -gt 0 ] && [ $ok = $n ] && r=pass || r=fail
  printf 'head_conformance_cli\t%s\t%d/%d fixtures decode to manifest sha256%s\n' "$r" $ok $n "${bad:+; failed:$bad}"
fi
rm -rf $T
