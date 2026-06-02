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

#### Calibration-sweep findings (the fetch-stage vs output-stage split)

Two **debug-only** knobs were added to drive the calibration empirically (both
default to a no-op, set only by `testrunner` from the environment, so production /
WASM / games are byte-for-byte unaffected — proven: full regression net green):

- `$EMIT_LEAD=N` — `gpu.dbg_emit_lead`, stalls the FIFO's first visible pixel by `N`
  dots (the pixel-output latch from layer 1 above), applied uniformly.
- `$WRITE_K=k` — `cpu.CPU.dbg_write_k`, commits the store for the fetch-stage PPU
  registers (`LCDC`/`SCY`/`SCX`/`WY`/`WX`) `k` dots into its write M-cycle via a new
  `tick_write_at(addr,value,k)` (k=0 ≈ write-before-tick = palette reorder; k=4 ≈
  current tick-before-write; 255 = disabled).

**`EMIT_LEAD` sweep (per-test min px).** No single value passes any test, and the
optima *disagree*, which is the irreducibility made concrete:

| test | L0 | L2 | L3 | L6 | best |
|---|--:|--:|--:|--:|--|
| `m3_bgp_change` | 2218 | **798** | 820 | 2694 | L2 |
| `m3_scx_high_5_bits` | 342 | **84** | 84 | 84 | L2 |
| `m3_window_timing` | 495 | 224 | **87** | 444 | L3 |
| `m3_obp0_change` | 280 | 256 | 238 | **158** | ≥L6 (monotone) |
| `m3_scy_change` | **9661** | 11313 | 11313 | 11254 | L0 (worsens) |
| `m3_lcdc_bg_en_change` | **3160** | 3413 | 3523 | 3247 | L0 (worsens) |
| flat (no response): `m3_scx_low_3_bits`, `m3_wx_4/5/6_change`, `m3_lcdc_win_map_change`, `m3_lcdc_win_en_change_multiple`, `m3_lcdc_tile_sel_win_change` | | | | | — |

**`WRITE_K` sweep (per-test px, K255 = current default).** `K0` (commit at M-cycle
*start*, the palette-reorder principle) cleanly helps the **fetch-stage** registers:

| test | K255 | **K0** | note |
|---|--:|--:|--|
| `m3_scx_high_5_bits` | 342 | **84** | SCX coarse — fetch-stage |
| `m3_lcdc_bg_map_change` | 1984 | **700** | LCDC.3 — fetch-stage |
| `m3_lcdc_tile_sel_change` | 2172 | **1536** | LCDC.4 — fetch-stage |
| `m3_lcdc_bg_en_change` | **3160** | 3605 | LCDC.0 — *output*-stage (K0 hurts) |
| `m3_scy_change` | **9661** | 10471 | (K0 hurts) |

**The key new insight — registers split by pipeline stage, and the split is the
gate.** Mode-3 registers are sampled at *two different points* of the FIFO pipeline:

- **Fetch-stage** (`fifo_fetch_tile`/`fifo_check_window`, upstream): `SCX`, `LCDC.3`
  (bg map), `LCDC.4` (tile data), `LCDC.5` (window enable). These want the **earliest**
  commit (`K0`) — a write affects the *next fetch*, which surfaces ~8–12 dots later.
- **Output-stage** (`fifo_emit_pixel`, downstream): `BGP`, `OBP0/1`, `LCDC.0` (bg
  enable), `LCDC.1/.2` (obj enable). These want a **later** effective sample
  (`EMIT_LEAD`) — a write affects the pixel emitted *now*.

A single register write commits at *one* time, but `LCDC` carries **both** kinds of
bit: `.3/.4/.5` want early, `.0/.1/.2` want late — so no commit time is right for
`LCDC` (`K0` fixes `bg_map`/`tile_sel` *and* regresses `bg_en`). That is not a tuning
problem; it means **our FIFO's fetch→output pipeline depth is ~1 M-cycle too short**.
On hardware the single commit naturally reaches the two stages ~8–12 dots apart
because the pixel at the output latch was fetched that long ago; our FIFO emits
~1 M-cycle too eagerly, so we have to fake the gap with per-register commit timing
and it collapses on `LCDC`. **The principled fix is to model the FIFO output latch
at the correct depth** (lengthen emit by the missing dots) so one hardware-accurate
commit time serves both stages — then `EMIT_LEAD`/`WRITE_K` become unnecessary. This
must be done content-neutral for games (it shifts `links_awakening`'s mid-line SCX
raster) and behind the `mode3_length()` parity assert.

Corollary, **structural vs phase**: the *flat* tests above don't respond to either
knob — their error is a genuine FIFO-structure gap (fine-scroll re-latch, window
re-trigger, multi-toggle), i.e. Buckets D/E, not the sub-dot phase. The
*phase-sensitive* tests are gated on the output-latch depth fix.

**Resolution — the output latch landed (after Bucket D).** Once Bucket D's sprite
stalls made the FIFO pace over the *full* mode-3 window, the emit latch stopped
being a content-corrupting fudge and became principled: re-sweeping `$EMIT_LEAD`
post-Bucket-D, **every** responsive test improves monotonically (incl. `m3_scy_change`,
which previously *worsened*), and the FIFO simply emits its first pixel ~1 dot too
early. Baking in `PIXEL_OUTPUT_LATCH = 1` (`fifo_start`) makes `m3_scx_high_5_bits`
**pixel-exact (35→0)** and improves the whole `m3_*` cluster — **regression-free AND
golden-neutral** (renders 29/29 byte-identical: no game's mid-mode-3 write crosses a
pixel boundary at 1 dot, and the latch is timing-neutral — `mode3_length()` still
owns mode-3 length, the line just completes 1 dot later via `fifo_flush`). Score
**1/24 → 2/24**. The `$EMIT_LEAD` knob now *overrides* the structural latch (sentinel
255 = use the default) for further sweeps. The old SCX-early-commit idea is retired —
the latch subsumes it without the golden churn.

**The obp0 gap — closed (output-stage delay line).** The fetch stage wants latch 1
(`scx_high` = 0 @ L1) but the output stage wants latch 3 (`m3_obp0_change` = 0 @ L3) —
a stable **+2 output-vs-fetch** offset = the FIFO fetch→output pipeline depth. Landed
as `OUTPUT_STAGE_DELAY = 2` (`fifo_emit_pixel`/`od_write`/`od_flush`): a small delay
line captures the BG colour-index and front OBJ pixel when a pixel is shifted out
(fetch-timed, latch 1) and applies `BGP`/`OBP`/`LCDC.0/.1/.2`/priority two dots later
(output latch 3). Passes `m3_obp0_change` (74→0) **and** keeps `m3_scx_high_5_bits` at
0, improves the cluster again (`bgp_change` 1508→820, `window_timing` 360→99,
`obj_en_change` 186→136), **regression-free and golden-neutral** (renders 29/29
byte-identical). Score **2/24 → 3/24**.

`m3_bgp_change`'s ~820 floor is the true fractional-dot residual (13/60/11/60 band
widths) that no integer latch reaches — the genuine sub-T-cycle phase, and the only
part of Bucket B still open. The rest of the failures are Bucket E (window) structure.

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

### Bucket D — sprite fetch timing / FIFO stalls — **DONE (regression-free)**

Per-sprite mode-3 fetch *stalls* used to live only in the analytic `mode3_length()`,
not in the FIFO's pixel pacing, so the FIFO emitted all 160 px ~`penalty` dots before
mode 3 actually ended and a mid-mode-3 write near a sprite landed on the wrong pixel.

**Fix landed (`src/gpu.zig`, `fifo_start`+`fifo_tick`).** `fifo_start` now precomputes
a per-object stall (`obj_stall[]`) using the *exact same* formula and selected-set/OAM
order as `mode3_length()`'s object term (so the sum is identical by construction), and
`fifo_tick` pays it back as an emission stall when the BG reaches each object's column.
The FIFO now paces over the full analytic mode-3 window. **Rendering-only** — the 12/12
timing contract stays owned by `mode3_length()`, untouched.

Results (regression-free: ppu 12/12, blargg 25/25, emu-only 28/28, acceptance
fail-set unchanged, **renders 29/29 byte-identical** — golden-neutral for games, since
a stall only delays *when* a static pixel emits, not *which*). 13 mealybug tests
improved, 0 regressed:

| test | before | after |
|---|--:|--:|
| `m3_scx_high_5_bits` | 342 | **35** |
| `m3_lcdc_bg_map_change` | 1984 | **320** |
| `m3_obp0_change` | 280 | **108** |
| `m3_lcdc_obj_size_change_scx` | 350 | **190** |
| `m3_lcdc_obj_en_change` | 256 | **200** |
| `m3_lcdc_tile_sel_change` | 2172 | **1404** |
| `m3_bgp_change_sprites` | 7792 | **1774** |
| `m3_lcdc_obj_en_change_variant` | 1444 | **630** |
| `m3_lcdc_obj_size_change` | 410 | **370** |
| `m3_lcdc_bg_en_change` | 3160 | **2686** |
| `m3_scy_change` | 9661 | **8037** |
| `m3_lcdc_win_map_change` | 1906 | **1778** |
| `m3_obp0`/`bg_map`/`scx_high` etc. | | |

Note the non-sprite improvements (`scx_high`, `bg_map`, `obp0`): emitting BG over the
*full* window (instead of finishing early) lands post-sprite content where hardware
does — the **content-correct** version of the emit-latch the global `EMIT_LEAD` fudge
could only fake. Remaining residuals are the sub-dot phase (e.g. `scx_high` 35 px = two
8-px tile columns scrambled at the SCX-write point). `m3_wx_4_change_sprites` stayed at
10 px (its residual is the window-edge sub-dot, Bucket E, not sprite pacing).

### Bucket E — window activation / WX edges — **deferred (state machine attempted)**

Exact dot the window turns on, the WX<7 / WX=0 lead-in discard, and mid-line LCDC.5
toggles. `fifo_check_window` (`src/gpu.zig`) is close for the simple case
(`m2_win_en_toggle` passes) but off for the WX edges and multi-toggle cases. Worst
is `m3_wx_6_change` (13799). Affects `m3_window_timing(+wx_0)`, `m3_wx_4/5/6_change`,
`m3_lcdc_win_en_change_multiple(+wx)`.

**Root cause (RLE-traced this session).** `fifo_check_window` latches `window_triggered`
once and never deactivates, so:
- `m3_lcdc_win_en_change_multiple` (8316) matches the reference exactly to x≈49, then the
  reference shows an **8-px-periodic on/off striping** (LCDC.5 toggled rapidly mid-line)
  that we render as a solid window — we hold it on after the first trigger.
- `m3_wx_6_change` (13799) is almost entirely wrong: mid-line `WX` changes that the
  once-only trigger never re-evaluates.

**Attempted, reverted (the every-dot state machine isn't enough).** Built the
re-evaluate-**every-dot** window: switch the fetcher window↔BG on each edge, with the
BG-resume column (`fetch_col = ((lcd_x+scx)>>3)−(scx>>3)`, re-align discard `(lcd_x+scx)&7`)
and a window restart at col 0 on each activation; deactivation gated on the *enable* bits
only (LCDC.5/.0, LY≥WY) — a one-way `lcd_x≥WX-7` activation trigger, since a mid-line WX
*increase* must **not** turn an already-on window off (gating deactivation on `lcd_x≥win_x`
instead blew up `m3_wx_4/5_change` to 10k+). With that corrected, `m2_win_en_toggle` stays
0 and `m3_wx_4/5_change` stay at baseline — but the multi-toggle target **did not improve**
(`win_en_multiple` 8316→8334, `wx_6` unchanged). So the structural switch is necessary but
not sufficient: the rapid-toggle result is dominated by the **per-toggle window-fetch
timing** (how many dots the fetcher stalls on each re-activation, and the exact sub-dot
restart phase) — the same fractional-dot class as `m3_bgp_change`'s 820 floor. Reverted;
the state-machine sketch is correct and worth reusing, but it needs the per-toggle fetch
cadence modelled before it pays off. Code parked in this commit's history.

Closest window targets if revisited: `m3_window_timing` (99 px) and
`m3_wx_4_change_sprites` (10 px). Both probed with a `lcd_x > win_x` (window 1 px
later) diagnostic:
- `m3_wx_4_change_sprites` is **not** a window-position bug — the diagnostic left it at
  10 px. Its 10 diffs (all on `x = y−7`) are *sprite visibility*: behind-priority sprites
  that hardware shows for 1 px where the BG/window colour at the activation column is 0,
  but we hide because our colour there is non-zero — i.e. the window *content* at the
  mid-line activation column is off by the sub-dot phase, not the edge.
- `m3_window_timing` (99→78), `m3_lcdc_win_map_change` (1778→284), `m3_lcdc_tile_sel_win_change`
  (2360→1170) all *want* the window 1 px later — but that **breaks the passing
  `m2_win_en_toggle`** (0→3797). So the steady-state window edge and the mid-line window
  content are entangled at the same sub-dot phase: no integer window shift satisfies both.
Both reduce to the fractional-dot wall (`m3_bgp_change`'s 820 floor), now the single
open problem across Buckets B and E.

#### Window line-start activation latch — **landed (regression-free, golden-neutral)**

`m3_window_timing` was fully root-caused this session via `mbtrace`. It is **not** a
window-edge test — it's a BGP-timing test on a *uniform-white window backdrop*. The
window covers the line (WX swept 0..N per row), and BGP is toggled at **fixed dots**
(80→`$FF`, 93→`$00`, 105→`$FF`); the visible white band is where BGP=`$00` (dots
93–105). The reference shows a **constant 3-px** white band on every row, so hardware's
first window pixel emits at a **fixed dot (102)** regardless of WX. Ours emitted at
`89 + discard` (discard = `7−WX`), so the band grew with WX (9,10,11,12,…).

**Root cause + fix (`fifo_check_window`).** For a window activating at the **start of the
line** (`lcd_x==0`, i.e. WX≤7 so it covers from the left edge), the activation refetch on
hardware **absorbs** the WX<7 lead-in discard instead of delaying emission by it. Modelled
by padding the emit stall so `discard + extra` is a **constant** (`f.warmup += 13 + win_x`,
which cancels the `discard = −win_x` term → constant 13). The `13` is the window line-start
refetch cost, calibrated to the dot-102 reference. Gated on `lcd_x==0` so a window toggled
on **mid-line** (`m2_win_en_toggle`) keeps the normal cadence and stays at 0.

Result: `m3_window_timing` **99→15**, `m3_window_timing_wx_0` **1490→634**,
**regression-free** (ppu 12/12, blargg 25/25, emu-only 28/28, acceptance fail-set
unchanged) and **golden-neutral** (renders 29/29 byte-identical — delaying *when* a
static window's identical pixels emit doesn't change *which* value lands where). The
remaining 15 px in `m3_window_timing` are row 0 (window inactive — possible WY/first-line
edge, 3 px) and a rows-11→17 diagonal where the **WX≥7 mid-line** window edge is 1 px late
— the same sub-dot edge wall (`lcd_x>win_x` would help it but breaks `m2_win_en_toggle`).

Note this latch is the line-start half of the "window content latch" (Approach 1.2). It
did **not** move `m3_wx_4/5/6_change` or the `win_en_multiple` cluster: those are dominated
by mid-line WX re-evaluation / wrong window content (see next), not line-start timing.

#### `m3_wx_6_change` reads the wrong window tile (structural, needs a reference emu)

`mbtrace` on the captured (steady-state) frame shows our window **does** trigger at `lcd_x=0`
(WX=6) and fetches in window mode, but reads tile `$57` row 4 (`lo=FF hi=95` →
`{3,1,1,3,1,3,1,3}`) at every column, while the reference shows a clean `7×0,1×255`
vertical stripe — **different tile data entirely**. So either our window row counter
(`internal_window_counter`, gave `wrow=36`), the tile-map select, or the VRAM state differs
from hardware. This is a structural content bug, not the sub-dot phase, but root-causing it
needs cross-checking against SameBoy's window fetcher (don't guess). It is the bulk of
`m3_wx_6_change`'s 13799 px.

#### SameBoy reference oracle — set up + the validated window algorithm

A SameBoy oracle is now built and instrumented (clone in `/tmp/SameBoy`; rebuild with
`brew install rgbds && make -C /tmp/SameBoy tester` — it builds its own DMG boot ROM).
Run a mealybug ROM with `build/bin/tester/sameboy_tester --dmg --length 4 <rom.gb>` →
writes `<rom>.bmp` (top-down 32bpp; SameBoy's DMG palette is greenish, **3 shades** here,
so quantise by luminance rank — it then matches the mealybug greyscale reference exactly,
**confirmed for wx_6/window_timing/win_en_multiple**). `Core/display.c` has a `getenv("SBTRACE")`
hook (set `SBTRACE=<ly>`) that dumps per-tile `line/pos/win/window_y/win_tile_x/tile/lo/hi`
at the window/BG fetch — the ground-truth for the algorithm below.

**The DMG window engine, traced from SameBoy (`Core/display.c`), validated against ours:**

1. **`position_in_line`** starts at **−16** at mode-3 start; the SCX fine-scroll discard
   advances it to −8; it then increments **once per pixel shifted out** through −7…159
   (`lcd_x` only counts the visible 0…159). So in the visible region **`position == lcd_x`**.
2. **Window activation is an *equality* check, live every pixel:** `WX == (uint8_t)(position
   + 7)` (plus `wy_triggered` and `LCDC.5`). Not a threshold. A *transient* WX whose match
   position has already passed never triggers; a later WX triggers at *its* position.
3. On activation: **`window_y++`** (frame-scoped row counter, init −1), `window_tile_x = 0`,
   clear BG FIFO, restart fetcher. The fetch row is `window_y` (`window_y/8` map row,
   `window_y&7` tile row); `window_tile_x` is the map column.
4. **Deactivation:** when `LCDC.5` (WIN_ENABLE) is cleared, `wx_triggered = false` (it can
   re-trigger later) — this is what the rapid-toggle `win_en_multiple` cluster needs.

**Why our model diverges (and only here).** Our trigger is a threshold (`lcd_x >= win_x`,
latched once), and our `internal_window_counter` is *predictive* (incremented per line in
`fifo_start`). For **stable per-line WX** (games, `window_timing`, `m2_win_en_toggle`) this
is *equivalent* — SameBoy traces confirm window triggers at `lcd_x == WX−7` and `window_y ==
ly`, exactly matching us — which is why those render correctly. The divergence is **only**
mid-line WX/enable changes:

- `m3_wx_6_change` ly=40 (SameBoy): WX=6 is transient (its match position −1 is passed
  before WX settles), then WX→40 triggers the window at **pos=33** with **window_y=34**,
  reading tile `0x57` row 2 (`lo=FF hi=9D`). For x0–32 it shows **BG** (tile `0x42` = the
  `{3,3,3,3,3,3,3,0}` stripe). Ours triggers at `lcd_x=0` on the transient WX=6 → window
  everywhere, `wrow=36` (row 4, `lo=FF hi=95`). The stripe is **background**, not window —
  we had it backwards.

**The window state machine landed (`fifo_check_window`), in three commits:**

1. *Equality trigger + per-activation `window_y` + deactivation.* The one-shot threshold
   (`lcd_x >= win_x`, latched) became a per-dot machine: activate when live `WX == lcd_x+7`
   (visible region; WX<7 still matches at line start), `internal_window_counter++` **on each
   activation** (so a mid-line re-trigger reads the next window row), and **deactivate** the
   window when `LCDC.5` is cleared (revert the fetcher to BG). Golden-neutral *by
   construction* — for stable per-line WX the equality fires once at `lcd_x==WX-7` and the
   deactivation path is dead (games never clear LCDC.5 mid-line), so renders stay 29/29
   byte-identical. → `win_en_multiple` 8316→2502, `..._wx` 6013→1713, `win_map_change`
   1778→630, `tile_sel_win_change` 2360→1336.
2. *FIFO-drain (not flush) on deactivation.* SameBoy's deactivation only clears the window
   flag — the window pixels already in the FIFO **drain**, then BG resumes; the next fetch
   targets screen column `lcd_x + bg_len`. We were flushing + force-refetching, which
   mis-phased the BG by up to a tile. → `win_en_multiple` 2502→**1**, `..._wx` 1713→**915**.

**Remaining window residuals (all the harder wall now):**

- **WX<7 line-start transient = the sub-dot WRITE-PHASE, not the pre-visible region.**
  Initially this looked like a missing pre-visible position counter (for WX<7 the window
  triggers at `pos=WX-7 ∈ [-7,-1]`, and we trigger unconditionally at `lcd_x==0`). But the
  SameBoy `position`/`lcd_x` trace + a `$WRITE_K` sweep proved the gate is **when the WX/LCDC.5
  write lands relative to the PPU**, which a pre-region can't fix:
  - `m3_wx_6_change` (13799): hardware activates at pos=33 on WX→40; the x0–32 stripe is BG.
    SameBoy's WX=6→40 write lands *before* `pos=−1`, so WX=6 never triggers; **our** WX=6→40
    write lands at dot 97 (*after* the first emit), so we wrongly trigger at line start. `K0`
    (early commit) does **not** fix it (still 13799) — the WX-write phase is off by more.
  - `m3_lcdc_win_en_change_multiple_wx` rows 44–49 (~700px): hardware activates at x38 on
    WX=45; **we don't activate at all** there — LCDC.5/WX isn't aligned at `lcd_x=38` in our
    timing (the enable toggle lands at the wrong dot).
  - The `$WRITE_K` sweep is **mixed and register-specific**: `K0` helps `win_en_wx`
    (915→437) but **wrecks** `win_en_multiple` (1→522) and doesn't touch `wx_6`. No single
    commit time works — the exact same sub-T-cycle wall as `m3_bgp_change`'s 820 floor. So a
    pre-visible position counter would **not** pay off; the real gate is the write-phase.
    Conclusion: do NOT build the −16…−1 pre-region for these; they need sub-T-cycle write
    commit (the Bucket-B core problem).
- **Fetch-stage write-phase**: `win_map_change` (630) / `tile_sel_win_change` (1336) are a
  flat ~8px/row at a fixed column — the mid-line LCDC.6/.4 (window map / tile-data select)
  write taking effect ~1 tile off, the same fetch-stage timing as `m3_lcdc_bg_map_change`.
- **Row-0 CPU↔PPU timing** (`win_en_multiple`'s lone pixel `(56,0)` — the only thing between
  it and a pass at 4/24). Diagnosed against the SameBoy oracle and **confirmed a real CPU
  timing bug, but out of reach**:
  - On row 0 our CPU writes the LCDC.5 toggles **4 dots earlier** than every other row (off
    at dot 149/lcd_x 49 + on at 165, vs 153/lcd_x 53 + 169 on row 8 — identical 16-dot shape,
    shifted 4). SameBoy (`SBDEACT` trace) deactivates at **pos=50 on *both* rows** — its CPU
    writes at the same position every line. So the 4-dot row-0 shift is ours.
  - It is **not** the 452-dot first line: row 0 of the captured frame is `lcd_first_line=false`
    (the ROM keeps the LCD on). It's a VBlank→line-0 boundary phase error — row 0 is the only
    visible line whose previous line is VBlank, so the test's per-line PPU sync lands 4 dots
    off there.
  - **No window-side fix exists**: the 4-dot shift puts the LCDC.5 clear at a different fetch
    phase, so `bg_len` (0 vs 4) and the BG-resume column genuinely differ; SameBoy is right
    only because its CPU isn't shifted. The fix must correct the row-0 CPU phase.
  - **Risky / deferred**: we pass mooneye acceptance/ppu **12/12**, which pins VBlank/STAT
    timing tightly, so this 4-dot error is *beyond* mooneye's coverage — perturbing the
    VBlank→line-0 path to fix 1px would likely disturb the 12/12 contract. Not worth it until
    there's a reason to revisit frame-boundary timing broadly.

---

## Status summary

| Item | State |
|---|---|
| Native grader (`testrunner mealybug`/`mbshot`, `tools/mealybug.sh`) | ✅ done |
| 24 vendored DMG references (`tools/mealybug_fetch.sh`) | ✅ done |
| Bucket C — `(ly+scy) %255 → %256` (`gpu.zig`) | ✅ done, regression-free |
| Bucket B — palette-write reorder (`cpu.zig:tick_write`) | ✅ done, regression-free |
| Bucket B — calibration benches (`$EMIT_LEAD`, `$WRITE_K`) + fetch/output split characterised | ✅ done (debug-only, no-op in prod) |
| Bucket B — **pixel-output latch (`PIXEL_OUTPUT_LATCH=1`, `gpu.zig`)** | ✅ done, regression-free — passes `m3_scx_high_5_bits` (35→0) |
| Bucket B — **output-stage delay line (`OUTPUT_STAGE_DELAY=2`, `gpu.zig`)** | ✅ done, regression-free — passes `m3_obp0_change` (74→0) |
| Bucket D — per-sprite FIFO stalls (`fifo_start`/`fifo_tick`) | ✅ done, regression-free (13 tests improved, 0 regressed) |
| Bucket E — window **line-start** activation latch (`fifo_check_window`, `warmup += 13+win_x`) | ✅ done, regression-free + golden-neutral — `m3_window_timing` 99→15, `m3_window_timing_wx_0` 1490→634 |
| Bucket E — window/WX **mid-line** state machine (`fifo_check_window`) | ✅ **landed**, regression-free + golden-neutral. Equality trigger on live WX, `window_y`-on-activation, deactivate-on-`LCDC.5`-clear, FIFO-drain (not flush) on deactivation. `win_en_change_multiple` **8316→1**, `..._wx` **6013→915**, `win_map_change` **1778→630**, `tile_sel_win_change` **2360→1336**. Residuals are write-phase / WX<7-transient / row-0 timing (below) |
| **mealybug score** | **3/24** (`m2_win_en_toggle`, `m3_scx_high_5_bits`, `m3_obp0_change`; **closest next: `m3_lcdc_win_en_change_multiple` = 1px** (row-0 timing), `m3_wx_4_change_sprites` 10, `m3_window_timing` 15, `m3_lcdc_obj_en_change` 136) |
| Regression net | ppu 12/12, blargg 25/25, emu-only 28/28, timer 13/13, render goldens identical |

Standing rule for every step below: re-run `tools/mealybug.sh` (score up, no test
regresses) **and** `tools/ppu_regress.sh` (ppu 12/12, blargg 25/25, emu-only 28/28,
render byte-compare). The timing contract stays owned by `mode3_length()`.

## Plan of attack (current — for the next session)

**State: 3/24** (`m2_win_en_toggle`, `m3_scx_high_5_bits`, `m3_obp0_change`). Landed,
all regression-free + golden-neutral: Bucket C (`%256`), Bucket D (sprite FIFO stalls),
the **pixel-output latch** (`PIXEL_OUTPUT_LATCH=1`), the **output-stage delay line**
(`OUTPUT_STAGE_DELAY=2`), the **window line-start latch** (`warmup += 13+win_x`), and the
**SameBoy-faithful window state machine** (equality trigger / `window_y`-on-activation /
deactivate-on-`LCDC.5` / FIFO-drain — see Bucket E). The FIFO now models the fetch→output
pipeline as fetch latch 1 / output latch 3, and the window engine is correct & validated.

### Current scoreboard (px diff; ✅ = pass)

| test | px | | test | px |
|---|--:|---|---|--:|
| `m2_win_en_toggle` | ✅ | | `m3_lcdc_obj_size_change_scx` | 190 |
| `m3_obp0_change` | ✅ | | `m3_lcdc_obj_en_change_variant` | 236 |
| `m3_scx_high_5_bits` | ✅ | | `m3_scx_low_3_bits` | 324 |
| `m3_lcdc_win_en_change_multiple` | **1** | | `m3_lcdc_obj_size_change` | 370 |
| `m3_wx_4_change_sprites` | 10 | | `m3_bgp_change_sprites` | 536 |
| `m3_window_timing` | 15 | | `m3_window_timing_wx_0` | 634 |
| `m3_lcdc_obj_en_change` | 136 | | `m3_wx_5_change` | 638 |
| `m3_lcdc_bg_map_change` | 192 | | `m3_lcdc_win_en_change_multiple_wx` | 915 |
| `m3_wx_4_change` | 229 | | `m3_lcdc_tile_sel_change` | 1276 |
| `m3_lcdc_obj_en_change` | 136 | | `m3_lcdc_tile_sel_win_change` | 1336 |
| `m3_lcdc_win_map_change` | 630 | | `m3_lcdc_bg_en_change` | 1330 |
| `m3_bgp_change` | 820 | | `m3_scy_change` | 6916 |
| | | | `m3_wx_6_change` | 13799 |

### Everything left is one of two timing walls (the window engine is no longer the gate)

The window cluster fix (Bucket E) made the remaining failures resolve to **two CPU↔PPU
timing problems**, both finer than the 1-dot granularity the PPU steps at:

1. **Sub-T-cycle write-phase** (Bucket B core). The mid-mode-3 register write lands at the
   wrong sub-M-cycle dot. Drives `m3_bgp_change` (820, the ±0.5-dot band-width wobble),
   `m3_lcdc_bg_map_change`/`tile_sel`/`win_map`/`tile_sel_win` (LCDC.3/.4/.6 ~1 tile off),
   `m3_scx_low_3_bits`, `m3_scy_change`, and the **WX<7-transient** window cases
   (`m3_wx_6_change` 13799, `win_en_wx` rows 44–49) — proven write-phase-gated, *not* a
   missing pre-visible region (a `$WRITE_K` sweep is mixed/register-specific; do NOT build
   the −16…−1 pre-region). No integer latch/commit-time reaches it.
2. **VBlank→line-0 4-dot phase**. `m3_lcdc_win_en_change_multiple`'s lone pixel `(56,0)`:
   our CPU writes LCDC.5 4 dots early on row 0 only (SameBoy writes at the same position
   every row). Beyond mooneye's 12/12 coverage, so risky to touch.

Both need sub-T-cycle CPU↔PPU phase work that re-validates the 12/12 contract — the deep,
deferred core. The structural Buckets (C/D/E) are done.

### Ground-truth findings recorded this session (don't re-derive)

- **`m3_bgp_change` is genuinely sub-dot.** From `mbtrace ly=40`: writes commit at fixed
  dots, our emission is perfectly linear (`emit_x = dot−96`), but the reference's effect
  per write is `effect_x = dot − {95 or 96}` — a **±0.5-dot wobble that is *not* a function
  of the dot residue** (same `dot mod 8/12/24` gives both Δ0 and Δ+1). So it needs real
  per-pixel fetcher cadence or sub-T-cycle commit; no integer latch reaches it (820 floor).
- **The `$WRITE_K` winners flipped** after the output-stage delay line landed. The old
  sweep said fetch-stage regs want `K0` (early commit); re-sweeping now, `K0` **regresses**
  the ones that pass (`scx_high` 0→159, `bg_map` 192→956) because the latch already supplies
  their delay. `K0` still helps `scy_change` (6916→2227) and `bg_en` — but mixed, no single
  K wins. The old "fetch-stage wants K0" note is **stale**; the knob stays measurement-only.
- **`m3_window_timing` is a BGP-timing test on a white window backdrop**, not an edge test
  (see Bucket E). Its WX<7 half is now exact; the residual is the WX≥7 sub-dot edge.

### The one remaining problem

Every remaining failure is the **fractional (sub-T-cycle) CPU↔PPU phase** — finer than
the 1-dot granularity the PPU steps at. Confirmed from three independent directions:

1. **BGP band widths** (`m3_bgp_change`, 820 px floor). Writes are spaced a uniform 12
   dots, but the reference's two short bands render **13 and 11** px wide (ours 12/12).
   13+11 = 24 = 2×12, so it's a ±1 oscillation with a 24-dot period — the write-dot→
   first-coloured-pixel boundary sits at a **non-integer (~2.5 dot)** offset. No integer
   latch reaches it (proven by the `$EMIT_LEAD` sweep: floors at ~796–820).
2. **Window edge vs content** (`m3_window_timing` 99, `m3_lcdc_win_map_change` 1778,
   `m3_lcdc_tile_sel_win_change` 2360). A `lcd_x > win_x` (window 1 px later) diagnostic
   *helps* all three (99→78, 1778→284, 2360→1170) but **breaks the passing
   `m2_win_en_toggle`** (0→3797). The steady-state window edge and the mid-line window
   content are at the same sub-dot phase — no integer window shift satisfies both.
3. **Sprite-at-activation** (`m3_wx_4_change_sprites`, 10 px). Not a position bug (the
   diagnostic left it at 10); the 10 diffs on `x=y−7` are behind-priority sprites that
   hardware shows for 1 px where the window *content* colour at the activation column is
   0 — again the sub-dot content phase.

### Guardrails (must stay green at every step)

`tools/ppu_regress.sh` → ppu **12/12**, blargg **25/25**, emu-only **28/28**, acceptance
fail-set unchanged, **renders 29/29 byte-identical**. `tools/mealybug.sh` → score up, no
test regresses. Timing owned by `mode3_length()`. The render byte-compare is the only
guard on game windows, so watch it like a hawk when touching `fifo_check_window`.

### Tooling already in place

- `testrunner mbtrace <rom> <ly>` — dumps the exact dot/lcd_x of every BGP write and the
  dot/bgp applied to every emitted pixel of a scanline. The ground-truth bench.
- `$EMIT_LEAD` (overrides `PIXEL_OUTPUT_LATCH`) and `$WRITE_K` (intra-M-cycle commit via
  `cpu.CPU.dbg_write_k` / `tick_write_at`) — calibration knobs, no-op by default.
- `/tmp/rle.py <test> <rows>` and `/tmp/diffpx.py <test>` (rebuild as needed) — RLE a row
  of shot-vs-ref, and list every differing pixel. Indispensable for reading residuals.

### Approach 1 — window cluster — ✅ DONE (SameBoy-faithful window state machine)

Landed (regression-free + golden-neutral): `win_en_change_multiple` 8316→**1**, `…_wx`
6013→**915**, `win_map_change` 1778→**630**, `tile_sel_win_change` 2360→**1336**,
`window_timing` 99→**15**, `window_timing_wx_0` 1490→**634**. The every-dot state machine
*was* the right skeleton; the pieces that made it work (validated against the SameBoy
oracle, see "SameBoy reference oracle" above):
- **Equality trigger** on live `WX == lcd_x+7` (not threshold), `window_y`++ **on each
  activation**, **deactivate** on LCDC.5-clear.
- **FIFO-drain on deactivation** (not flush): the in-FIFO window pixels drain, then BG
  resumes at column `lcd_x + bg_len`. This was the big one (`win_en_multiple` 2502→1).

What's left in the cluster is **not** the engine — it's the write-phase / VBlank-boundary
walls above (`wx_6`, `win_en_wx` band, `win_map`/`tile_sel_win` ~1-tile, the row-0 pixel).
Do NOT build a pre-visible position region for `wx_6`/`win_en_wx`: proven write-phase-gated.

### Approach 2 — the fractional-dot core (the hard wall: `bgp` 820 and the residuals)

The non-uniform 13/11 band widths can only come from **non-uniform pixel emission** — i.e.
the real BG fetcher does *not* emit a clean 1 px/dot; it has a sub-dot cadence we flattened.
Two ways in, in order of preference:

1. **Model the real fetcher cadence.** Replicate the DMG pixel-FIFO fetcher dot-for-dot
   (tile/low/high/push with the exact push-stall rule) so steady-state emission is
   naturally non-uniform and reproduces 13/11. This is content-neutral for static frames
   (renders stay byte-identical) by construction — verify that first, then check `bgp`.
   Use `mbtrace` to confirm the per-pixel emit dots become non-linear in the right places.
2. **Half-dot PPU stepping** (last resort, invasive). Step the PPU at 2× (half-dot) and
   commit writes at the true sub-dot, directly modelling the ~2.5-dot offset. High blast
   radius — re-validates every timing test — so only if (1) can't reproduce 13/11.

Definition of done for the core: `m3_bgp_change` → 0 **and** `m3_scx_high_5_bits`/
`m3_obp0_change` stay 0, with `tools/ppu_regress.sh` fully green (re-baseline only the
game goldens that a *proven* accuracy change shifts, eyeballing each, as Bucket C did).

### Dead ends (don't repeat)

- **Per-register commit-time tuning** (`$WRITE_K`) for the cluster: `LCDC` mixes fetch
  (`.3/.4/.5`) and output (`.0/.1/.2`) bits, so no single commit dot satisfies both. The
  knob stays only as a measurement tool.
- **A global `EMIT_LEAD` > 1**: passes one of `{scx_high@1, obp0@3}` at the cost of the
  other; the split (latch 1 + delay 2) is what gets both. Already landed.
- **Shifting the window edge** (`lcd_x>win_x`) to fix content: helps content tests but
  breaks `m2_win_en_toggle`. Shift *content*, not the edge (Approach 1.2).
- **The naive `EMIT_LEAD` warmup as the latch model**: it lets the fetcher run ahead and
  corrupts SCY. The shipped latch only works because Bucket D paced the FIFO first.

## Regenerating references

```
tools/mealybug_fetch.sh     # re-download the 24 DMG PNGs from upstream
```
