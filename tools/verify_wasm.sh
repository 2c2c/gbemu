#!/usr/bin/env bash
# Build the WASM core with the given zig, run the strict golden driver over a set
# of ROMs in Node, and diff against the golden captured on known-good 0.14.1.
# Exact match => the toolchain upgrade preserved emulation behavior bit-for-bit.
# This verifies the emulator with no SDL involved at all.
#
# usage: tools/verify_wasm.sh /path/to/zig
set -u
ZIG="${1:?usage: verify_wasm.sh <zig-binary>}"
cd "$(dirname "$0")/.."

echo "== zig $("$ZIG" version) (wasm) =="
if ! "$ZIG" build wasm; then echo "WASM BUILD FAILED"; exit 1; fi

ROMS=(tetris kirby_dream_land dr_mario)
fail=0
for rom in "${ROMS[@]}"; do
    out="tools/golden/$rom.wasm.cur.txt"
    if ! node tools/wasm_golden.mjs "games/$rom.gb" 900 30 > "$out" 2>&1; then
        echo "$rom: golden driver failed:"; tail -3 "$out"; fail=1
    fi
    if diff -q "tools/golden/$rom.wasm.txt" "$out" >/dev/null 2>&1; then
        echo "$rom: MATCH golden ($(grep -c '^frame=' "$out") samples)"
    else
        echo "$rom: DIFFERS from golden:"; diff "tools/golden/$rom.wasm.txt" "$out" | head -25; fail=1
    fi
done

[ "$fail" -eq 0 ] && echo "ALL WASM GAMES MATCH GOLDEN — upgrade preserved behavior" || echo "WASM VERIFICATION FAILED"
exit $fail
