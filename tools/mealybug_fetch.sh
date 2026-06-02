#!/usr/bin/env bash
# Vendor the canonical mealybug-tearoom-tests DMG reference screenshots.
#
# These are the author's "known-correct" DMG outputs (expected/DMG-blob/*.png in
# the upstream repo). They are tiny 160x144 2-bit greyscale PNGs whose four shades
# are exactly $00/$55/$AA/$FF — identical to our framebuffer's palette — so the
# grader can compare them byte-for-byte (see docs/mealybug-tests.md).
#
# Only the 24 tests that have a DMG reference are fetched. The 7 *2/_change2
# variants are CGB-only in upstream (expected/CPU CGB C/) and are not gradeable on
# a DMG core, so they are deliberately skipped.
#
#   tools/mealybug_fetch.sh
set -eu
cd "$(dirname "$0")/.."
DEST="games/mealybug-tearoom-tests/expected/DMG-blob"
BASE="https://raw.githubusercontent.com/mattcurrie/mealybug-tearoom-tests/master/expected/DMG-blob"
mkdir -p "$DEST"

TESTS="
m2_win_en_toggle
m3_bgp_change
m3_bgp_change_sprites
m3_lcdc_bg_en_change
m3_lcdc_bg_map_change
m3_lcdc_obj_en_change
m3_lcdc_obj_en_change_variant
m3_lcdc_obj_size_change
m3_lcdc_obj_size_change_scx
m3_lcdc_tile_sel_change
m3_lcdc_tile_sel_win_change
m3_lcdc_win_en_change_multiple
m3_lcdc_win_en_change_multiple_wx
m3_lcdc_win_map_change
m3_obp0_change
m3_scx_high_5_bits
m3_scx_low_3_bits
m3_scy_change
m3_window_timing
m3_window_timing_wx_0
m3_wx_4_change
m3_wx_4_change_sprites
m3_wx_5_change
m3_wx_6_change
"

n=0
for t in $TESTS; do
  curl -fsS -m 30 -o "$DEST/$t.png" "$BASE/$t.png"
  n=$((n+1))
done
echo "fetched $n DMG reference PNGs into $DEST"
