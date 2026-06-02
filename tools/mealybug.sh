#!/usr/bin/env bash
# Grade the mealybug-tearoom-tests DMG rendering suite.
#
# Builds the native testrunner, converts the vendored DMG reference PNGs to PPM
# (ImageMagick — the four shades expand to the same $00/$55/$AA/$FF bytes our
# framebuffer uses), runs every ROM to its `LD B,B` breakpoint and compares the
# screen to its reference. For each failing test it also writes our captured
# screen and a magick `compare` diff into /tmp/mealybug/ for inspection.
#
#   tools/mealybug.sh
set -u
cd "$(dirname "$0")/.."
ZIG=~/.local/share/zigup/0.17.0-dev.633+9c5655093/files/zig
REFPNG="games/mealybug-tearoom-tests/expected/DMG-blob"
REFPPM="/tmp/mealybug/ref"
SHOTS="/tmp/mealybug/shot"
DIFFS="/tmp/mealybug/diff"
mkdir -p "$REFPPM" "$SHOTS" "$DIFFS"

if ! "$ZIG" build testrunner 2>/tmp/mb_build.err; then echo "BUILD FAILED"; cat /tmp/mb_build.err; exit 1; fi
TR=./zig-out/bin/testrunner

# PNG -> PPM (once per run; cheap). magick expands 2-bit greyscale to 0/85/170/255.
for png in "$REFPNG"/*.png; do
  [ -f "$png" ] || continue
  b=$(basename "$png" .png)
  magick "$png" -depth 8 "ppm:$REFPPM/$b.ppm"
done

# Grade every ROM that has a reference (the 24 DMG tests; *2 variants report N/A).
$TR mealybug "$REFPPM" games/mealybug-tearoom-tests/*.gb

# For each test with a reference, dump our screen + a visual diff so failures can
# be eyeballed (red = differing pixels).
echo
echo "writing screenshots + diffs to /tmp/mealybug/ ..."
for ppm in "$REFPPM"/*.ppm; do
  b=$(basename "$ppm" .ppm)
  rom="games/mealybug-tearoom-tests/$b.gb"
  [ -f "$rom" ] || continue
  $TR mbshot "$rom" "$SHOTS/$b.ppm" >/dev/null 2>&1
  magick "$SHOTS/$b.ppm" "$SHOTS/$b.png" 2>/dev/null
  magick "$ppm" "$REFPPM/$b.png" 2>/dev/null
  magick compare -metric AE "$SHOTS/$b.png" "$REFPPM/$b.png" "$DIFFS/$b.png" 2>/dev/null
done
echo "done. ref=$REFPPM  shots=$SHOTS  diffs=$DIFFS"
