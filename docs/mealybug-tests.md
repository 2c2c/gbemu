# mealybug-tearoom-tests — grading harness & plan

The mealybug suite (`games/mealybug-tearoom-tests/*.gb`) checks **pixel-level PPU
rendering** when registers are written *mid-scanline* during STAT mode 3. There is
no machine-readable pass/fail — each test renders a screen and you compare it to a
reference image. This doc covers the grader that now exists, the vendored
references, and the per-test triage that drives the remaining PPU work.

The pixel-FIFO PPU (`docs/ppu-timing-tests.md` §"Tier 2") is the prerequisite, and
it landed: BGP/OBP/LCDC/SCX/SCY/WX are sampled **live per pixel**, so a mid-mode-3
write affects only the pixels drawn after it. mealybug exists to verify exactly
that, at single-pixel precision.

---

## How grading works

Upstream (`mattcurrie/mealybug-tearoom-tests`) ships, per device, the author's
known-correct screenshots. The relevant facts (from its README):

- Capture the screen when the ROM executes the **`LD B,B`** (opcode `$40`) software
  breakpoint — that's the suite's "screen is ready" marker.
- A DMG emulator's four shades must be exactly **`$00 / $55 / $AA / $FF`**. Our
  framebuffer already uses these (`GPU.to_color`, `src/gpu.zig`).
- Grade with imagemagick `compare -metric AE` — **0 differing pixels = pass**.

### Reference images (vendored)

- `tools/mealybug_fetch.sh` downloads the 24 DMG references
  (`expected/DMG-blob/*.png`) into
  `games/mealybug-tearoom-tests/expected/DMG-blob/`. They are tiny 160×144 2-bit
  greyscale PNGs (~400 B each, ~96 KB total). Note `games/` is gitignored (the
  test ROMs aren't committed either), so the references live alongside the ROMs
  and the fetch script *is* the reproducibility mechanism — rerun it to repopulate.
- The four 2-bit shades expand (×85) to exactly `0/85/170/255 = $00/$55/$AA/$FF`,
  i.e. byte-for-byte our palette — so the compare needs no colour mapping.

### Which tests are gradeable

- **24** tests have a DMG reference and are graded.
- **7** `*2` / `_change2` variants (`m3_lcdc_bg_en_change2`, `…bg_map_change2`,
  `…tile_sel_change2`, `…tile_sel_win_change2`, `…win_map_change2`,
  `m3_scx_high_5_bits_change2`, `m3_scy_change2`) have **only CGB references**
  upstream (`expected/CPU CGB C/`). They are CGB-only and **not gradeable on a DMG
  core** — reported `N/A`, structural like the Category-B model boot tests.

### The harness

Native, in `src/testrunner.zig` (read-only w.r.t. the core — cannot regress emulation):

- `testrunner mealybug <refdir> <rom...>` — run each ROM to its `LD B,B`
  breakpoint, quantise both framebuffer and reference PPM to the 4 DMG shades, and
  count differing pixels. `0` = `PASS`. Missing reference = `N/A`.
- `testrunner mbshot <rom> <out.ppm>` — dump the framebuffer captured at `LD B,B`
  (for building side-by-side diffs).
- `tools/mealybug.sh` — builds, converts the PNGs → PPM (ImageMagick), grades all
  24, and writes our screen + a red-highlighted `compare` diff per test into
  `/tmp/mealybug/{ref,shot,diff}/` for eyeballing.

```
tools/mealybug.sh
```

---

## Baseline scoreboard (first run on the FIFO PPU)

**1/24 pass.** This is the honest starting point: the FIFO renders the right
*content* for nearly every test, but the *exact pixel* where each mid-mode-3 write
takes effect is still off. Pixel-diff counts (lower = closer):

| test | px diff | root-cause bucket |
|---|---:|---|
| `m2_win_en_toggle` | **0** | ✅ pass |
| `m3_wx_4_change_sprites` | 10 | E (sprite) — near pass |
| `m3_lcdc_obj_en_change` | 256 | D (sprite) |
| `m3_obp0_change` | 290 | B (FIFO align) |
| `m3_scx_low_3_bits` | 324 | B |
| `m3_scx_high_5_bits` | 342 | B |
| `m3_lcdc_obj_size_change_scx` | 350 | D (sprite) |
| `m3_lcdc_obj_size_change` | 410 | D (sprite) |
| `m3_wx_4_change` | 229 | E (window/WX) |
| `m3_wx_5_change` | 638 | E |
| `m3_lcdc_obj_en_change_variant` | 1444 | D (sprite) |
| `m3_window_timing` | 1564 | E |
| `m3_lcdc_win_map_change` | 1906 | B |
| `m3_lcdc_bg_map_change` | 1984 | B |
| `m3_lcdc_tile_sel_change` | 2172 | B |
| `m3_lcdc_tile_sel_win_change` | 2488 | B |
| `m3_window_timing_wx_0` | 3034 | E |
| `m3_lcdc_bg_en_change` | 3160 | B |
| `m3_bgp_change` | 5084 | B |
| `m3_lcdc_win_en_change_multiple_wx` | 6041 | E |
| `m3_lcdc_win_en_change_multiple` | 8316 | E |
| `m3_bgp_change_sprites` | 9398 | B+D |
| `m3_scy_change` | 9661 | C (`%255`) |
| `m3_wx_6_change` | 13799 | E |

---

## Triage — root causes (drives the fix order)

### Bucket B — PPU write-phase (mid-mode-3 writes land ~6px too late) — **partially fixed**

The largest group. Initial horizontal-shift sweep of our output vs the reference:

| test | diff @ dx=0 | best shift | diff @ best |
|---|---:|:--:|---:|
| `m3_bgp_change` | 5082 | **+6** | 1294 |
| `m3_obp0_change` | 290 | 0 | 290 |
| `m3_scx_low_3_bits` | 324 | 0 | 324 |
| `m3_lcdc_bg_en_change` | 3160 | 0 | 3160 |

The reading (the CPU is **already cycle-accurate** — it steps the PPU one dot per
T-cycle interleaved with each access, per `docs/cycle-accurate-cpu-plan.md`; this is
not a CPU rewrite): `m3_bgp_change` writes BGP repeatedly to make full-width palette
bands. By tracing the dot each BGP write commits vs the pixel emitted (temporary
hook on the `0xFF47` store), our pixel N emits at dot `92+N` (mode 3 starts at dot
80 → a 12-dot pipeline fill). The CPU side is exact, so a write at dot D should
affect pixel `D−92` — but our bands landed **~6 px too far right** (too late), i.e.
the write took effect later than hardware.

**Root cause: tick-before-write ordering.** `tick_write` does `mcycle()` (tick the
PPU 4 dots) *then* the store, so a mid-mode-3 register write lands at the *end* of
its M-cycle — up to 4 dots later than hardware, where the store is on the M-cycle's
last T-cycle and the pixels after it see the new value. (A shift sweep first read
this as "+6 early"; the per-row trace showed the opposite — the global-shift sign
was misleading because the bands are content-modulated. The image/transition trace
is authoritative: writes were ~6 px **late**.)

**Partial fix landed (regression-free, `cpu.zig:tick_write`).** For the pure-render
palette registers (`BGP`/`OBP0`/`OBP1` — they never affect PPU *timing*), apply the
store *before* the M-cycle's PPU ticks. That moves the effect ~4 dots earlier (the
right direction): `m3_bgp_change` 5082→2218 px, `m3_window_timing` 1564→495,
`m3_bgp_change_sprites` 9398→7792, others improved; **no regression** (ppu 12/12,
blargg 25/25, emu-only 28/28, render goldens byte-identical). Timing-neutral, so the
contract is safe.

**Still open — two further layers (investigated, not landed).** After the reorder
our bands sit ~+2 px late, then a residual ±1 px on half the boundaries:

1. **~2-dot pixel-pipeline latency.** write-then-tick lands the store at the M-cycle
   *start* (the earliest point in that M-cycle), yet bands are still ~2 px late — so
   the gap is on the *emission* side: our pixel N leaves the FIFO at dot `92+N`, ~2
   dots earlier than hardware's output latch. A temporary first-pixel stall of 2
   dots (`EMIT_LEAD=2`) confirms this: it makes the main 60-px bands **pixel-exact**
   (`m3_bgp_change` 2218→798, `m3_scx_high_5_bits` 342→84, `m3_lcdc_bg_map_change`
   1984→700). **Not kept**, because as a global constant it is an empirical fudge:
   it perturbs `m3_scy_change` (worse) and shifts a real mid-mode-3 raster effect in
   `links_awakening` by 2 px, while passing no test. The principled form is to model
   the pixel-output latch in the FIFO, validated to be content-neutral for games.
2. **Irreducible ±1 px = a sub-dot CPU↔PPU phase (the actual PASS blocker).** With a
   BGP-write hook on `ly=40` the data is unambiguous: our BG emission is *perfectly
   linear* — `lcd_x = dot − 92` for every write (dots 96/108/168/180/240 →
   lcd_x 4/16/76/88/148). Yet the reference's visible band **widths** are non-uniform:
   ours are `12,60,12,60` px, the reference's are `13,60,11,60` (the 60s match; the
   two 12-dot short bands render as 13 and 11). Same CPU write spacing, so the
   boundary between the CPU-write dot and the pixel it first colours sits at a
   **non-integer (~2.5 dot)** offset on hardware. No integer knob reproduces that:
   the EMIT_LEAD sweep bottoms out at lead=2 → 796 px (≈0.9 px/boundary), with half
   the edges at +0 and half at +1 — exactly the rounding of a 2.5-dot offset. Closing
   it needs **sub-T-cycle write-commit placement** (tick the PPU to the store's exact
   T-cycle within its M-cycle, not the M-cycle boundary) and/or an explicit
   pixel-output latch — i.e. finer than the M-cycle granularity the cycle-accurate
   core currently runs at. This is research-grade PPU↔CPU phase work, entangled with
   the timer/PPU-timing contract, and is the true gate on the whole `m3_*` cluster
   reaching 0-diff.

Extending the reorder to the timing-bearing registers (`SCX`/`SCY`/`WX`/`LCDC`) is
also still needed for `m3_lcdc_*`/`m3_scx_*`/`m3_scy_change`, behind a `mode3_length()`
parity assert (those are *not* timing-neutral). Net: the write-phase is fully
characterised and the principled, regression-free half (palette reorder) is in; the
cluster won't reach 0-diff until the sub-T-cycle write-commit phase is modelled.

### Bucket C — `(ly+scy) % 255` off-by-one — **DONE**

`src/gpu.zig:645` computed the BG row as `(ly+scy) % 255`; hardware wraps mod **256**
(8-bit add). Fixed to `self.ly +% scy`. Verified: acceptance/ppu 12/12, blargg
25/25, emulator-only 28/28 all unchanged; render byte-compare changed exactly 4
ROMs that scroll past row 255 (`harvest_moon`, `links_awakening`, `lycscy`,
`instr_timing`) while `dmg-acid2` and all static games stayed byte-identical —
strong evidence the fix is a correctness improvement (acid2 would catch a
BG-addressing regression). Render goldens re-baselined for those 4.

**It did not move any mealybug test** — `m3_scy_change` keeps SCY small (ly+scy <
255), so it was unaffected (still 9661 px). That test actually belongs to Bucket B:
its failure is mid-line SCY *write timing*, not the wrap. So Bucket C is a real
hardware-correctness fix that happens not to be covered by a DMG mealybug test.

### Bucket D — sprite fetch timing / FIFO stalls

Per-sprite mode-3 fetch *stalls* live only in the analytic `mode3_length()`, not in
the FIFO's pixel pacing (`fifo_merge_sprites`, `src/gpu.zig:689`, merges without
pausing emission). So a mid-mode-3 write near a sprite lands on the wrong pixel.
Move the per-sprite stall into the FIFO while keeping total mode-3 length identical
to `mode3_length()` (the 12/12 timing contract). Affects `m3_lcdc_obj_en_change(+variant)`,
`m3_lcdc_obj_size_change(+scx)`, `m3_wx_4_change_sprites` (10 px — essentially there),
and the sprite half of `m3_bgp_change_sprites`.

### Bucket E — window activation / WX edges

Exact dot the window turns on, the WX<7 / WX=0 lead-in discard, and mid-line LCDC.5
toggles. `fifo_check_window` (`src/gpu.zig:579`) is close for the simple case
(`m2_win_en_toggle` passes) but off for the WX edges and multi-toggle cases. Worst
is `m3_wx_6_change` (13799). Affects `m3_window_timing(+wx_0)`, `m3_wx_4/5/6_change`,
`m3_lcdc_win_en_change_multiple(+wx)`.

---

## Status summary

| Item | State |
|---|---|
| Native grader (`testrunner mealybug`/`mbshot`, `tools/mealybug.sh`) | ✅ done |
| 24 vendored DMG references (`tools/mealybug_fetch.sh`) | ✅ done |
| Bucket C — `(ly+scy) %255 → %256` (`gpu.zig`) | ✅ done, regression-free |
| Bucket B — palette-write reorder (`cpu.zig:tick_write`) | ✅ done, regression-free |
| Bucket B — sub-T-cycle write commit + SCX/SCY/WX/LCDC extension | 📋 planned (below) |
| Bucket D — per-sprite FIFO stalls | 📋 planned |
| Bucket E — window/WX activation timing | 📋 planned |
| **mealybug score** | **1/24** (`m3_bgp_change` 5082→2218 px; cluster gated on Bucket B) |
| Regression net | ppu 12/12, blargg 25/25, emu-only 28/28, timer 13/13, render goldens identical |

Standing rule for every step below: re-run `tools/mealybug.sh` (score up, no test
regresses) **and** `tools/ppu_regress.sh` (ppu 12/12, blargg 25/25, emu-only 28/28,
render byte-compare). The timing contract stays owned by `mode3_length()`.

## Action plan to fix (implementer's recipe)

**Step 1 — sub-T-cycle write commit for palettes (unblocks `m3_bgp_change`,
`m3_obp0_change`).** The store currently lands at an M-cycle *boundary* (write-then-
tick = T0; tick-then-write = T4); hardware's effective commit is a non-integer ~2.5
dots, so neither boundary nor any integer `EMIT_LEAD` can hit 0-diff (proven: sweep
floors at 796 px). Fix: tick the PPU to the store's exact intra-M-cycle T-cycle
instead of 4-at-once.
- The PPU already advances one dot per `CPU.tick_peripherals_one()`; `mcycle()` just
  calls it 4×. Add a `tick_write_at(addr, value, k)` that ticks `k` dots, applies the
  store, then ticks `4−k` dots (so `inline_ticked` still += 4 and the overstep assert
  holds). Route `BGP/OBP0/OBP1` through it.
- Calibrate `k` (and any 1-dot pixel-output latch) against `m3_bgp_change` until the
  per-row transition trace matches the reference and the grader reports **0 px**.
  Use the `0xFF47` write hook + the row-40 transition compare from this doc as the
  bench. Expect `k`≈ the value that realises the measured ~2.5-dot net offset.
- Guard: timer writes (`FF04`–`FF07`) must keep tick-before-write (cycle-accurate
  plan pitfall #3) — scope `tick_write_at` to PPU render registers only.

**Step 2 — extend to the timing-bearing registers (`SCX`/`SCY`/`WX`/`LCDC`).**
Unblocks `m3_lcdc_bg_map_change`, `m3_lcdc_tile_sel_change(+win)`, `m3_scx_high_5_bits`,
`m3_scy_change`, `m3_lcdc_win_map_change`. These feed mode-3 length / mode transitions,
so they are *not* timing-neutral:
- Add a debug `mode3_length()` **parity assert** — the FIFO's produced mode-3 dot
  count must equal the analytic value every line — and keep it on through bring-up.
- `SCX&7` is latched at mode-3 start (leave it); only the live coarse fetch reads the
  reordered value. `LCDC` bits (`.0` bg-enable, `.3` bg-map, `.4` tile-data, `.5`
  window-enable, `.1/.2` obj) are already sampled live in the FIFO — the only change
  is *when* the write commits; verify the 12/12 mode-transition tests don't move.

**Step 3 — Bucket D, per-sprite FIFO stalls.** Move the per-object mode-3 penalty out
of analytic `mode3_length()` and into the FIFO's pixel pacing (`fifo_merge_sprites`,
`gpu.zig:689`): stall emission for the fetch cost when an object is due at `lcd_x`, so
a mid-mode-3 write near a sprite lands on the right pixel. Total length must still
equal `mode3_length()` (parity assert). Unblocks `m3_lcdc_obj_en_change(+variant)`,
`m3_lcdc_obj_size_change(+scx)`, `m3_wx_4_change_sprites` (10 px), the sprite half of
`m3_bgp_change_sprites`.

**Step 4 — Bucket E, window/WX activation.** In `fifo_check_window` (`gpu.zig:579`):
exact dot the window turns on, the `WX<7`/`WX=0` lead-in discard, and mid-line
`LCDC.5` toggles. Unblocks `m3_window_timing(+wx_0)`, `m3_wx_4/5/6_change`,
`m3_lcdc_win_en_change_multiple(+wx)` (`m3_wx_6_change`, 13799 px, is the worst).

Dependency note: Steps 3–4 also write registers mid-mode-3, so they inherit Step 1's
commit-phase fix — do Step 1 first.

## Regenerating references

```
tools/mealybug_fetch.sh     # re-download the 24 DMG PNGs from upstream
```
