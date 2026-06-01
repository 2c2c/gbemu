#!/usr/bin/env bash
# Full PPU regression net for the pixel-FIFO work. Builds the native testrunner,
# runs every gradeable suite, and renders all game ROMs comparing them byte-for-
# byte against the WASM-captured baselines in /tmp/gbshots/*.base.ppm.
#
#   tools/ppu_regress.sh
set -u
cd "$(dirname "$0")/.."
# macOS bash 3.2 has no globstar; enumerate the suite explicitly (top-level boot
# tests + one-dir-deep category tests).
ACCEPT="games/mooneye/acceptance/*.gb games/mooneye/acceptance/*/*.gb"
EMUONLY="games/mooneye/emulator-only/*/*.gb"
ZIG=~/.local/share/zigup/0.17.0-dev.633+9c5655093/files/zig

if ! "$ZIG" build testrunner 2>/tmp/ppu_build.err; then echo "BUILD FAILED"; cat /tmp/ppu_build.err; exit 1; fi
TR=./zig-out/bin/testrunner

echo "== mooneye acceptance/ppu (must be 12/12) =="
$TR mooneye games/mooneye/acceptance/ppu/*.gb 2>&1 | tail -1

echo "== blargg (must be 25/25) =="
$TR blargg games/blargg/*.gb games/blargg/apu/*.gb 2>&1 | tail -1

echo "== mooneye emulator-only (must be 28/28) =="
$TR mooneye $EMUONLY 2>&1 | tail -1

echo "== mooneye acceptance (fail set must match baseline) =="
$TR mooneye $ACCEPT 2>&1 | grep -E "FAIL|TIMEOUT" | sed 's/ :: .*//;s/^FAIL *//;s/^TIMEOUT *//' | sort -u > /tmp/cur_accept_fails.txt
$TR mooneye $ACCEPT 2>&1 | tail -1
if diff -q /tmp/baseline_accept_fails_unique.txt /tmp/cur_accept_fails.txt >/dev/null; then
  echo "acceptance fail set: UNCHANGED (no regression)"
else
  echo "acceptance fail set: CHANGED <<<<<<<<<<<"; diff /tmp/baseline_accept_fails_unique.txt /tmp/cur_accept_fails.txt
fi

echo "== rendering (byte-compare vs baseline) =="
match=0; diff=0; difflist=""
for f in games/*.gb; do
  rom=$(basename "$f" .gb)
  [ -f /tmp/gbshots/$rom.base.ppm ] || continue
  $TR render "$f" /tmp/gbshots/$rom.cur.ppm 600 >/dev/null 2>&1
  if cmp -s /tmp/gbshots/$rom.base.ppm /tmp/gbshots/$rom.cur.ppm; then
    match=$((match+1))
  else
    diff=$((diff+1)); difflist="$difflist $rom"
  fi
done
echo "rendering: $match match, $diff differ"
[ -n "$difflist" ] && echo "  DIFFER:$difflist"
exit 0
