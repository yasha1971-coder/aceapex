#!/usr/bin/env bash
# Cross-version fixtures: a 4 MiB slice of chr1 (offset 100 MiB) archived on known libzstd
# versions, kept in verify/fixtures. Each fixture is decoded here and checked by sha256, then
# the decoded slice is re-encoded and compared with the fixture that matches this host's
# libzstd. No corpus needed. Output lines: claim_id <TAB> verdict <TAB> measured
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
  env -i PATH="$PATH" ACEAPEX_BS=16384 LIT_CHUNK=65536 FSE_CHUNK=4096 $B c --in $T/o_$ZV \
    --out $T/re.aet --threads 2 >/dev/null 2>&1
  cmp -s $T/re.aet $F/chr1_4MiB.zstd-$ZV.aet && r=pass || r=fail
  printf 'head_fixture_encode_determinism\t%s\tre-encode of decoded slice == fixture, libzstd %s\n' \
    "$r" "$ZV"
else
  printf 'head_fixture_encode_determinism\tdeclared\tno fixture for host libzstd %s yet\n' "$ZV"
fi
rm -rf $T
