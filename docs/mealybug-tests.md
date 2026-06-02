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
| Bucket E — window/WX activation timing | ⏸️ state machine attempted + reverted (structural switch necessary but not sufficient — needs per-toggle fetch cadence; see Bucket E) |
| **mealybug score** | **3/24** (`m2_win_en_toggle`, `m3_scx_high_5_bits`, `m3_obp0_change`; closest next: `m3_wx_4_change_sprites` 10, `m3_lcdc_obj_size_change_scx` 190) |
| Regression net | ppu 12/12, blargg 25/25, emu-only 28/28, timer 13/13, render goldens identical |

Standing rule for every step below: re-run `tools/mealybug.sh` (score up, no test
regresses) **and** `tools/ppu_regress.sh` (ppu 12/12, blargg 25/25, emu-only 28/28,
render byte-compare). The timing contract stays owned by `mode3_length()`.

## Action plan to fix (implementer's recipe)

**Step 1 — model the FIFO output-latch depth (the real gate; supersedes "sub-T-cycle
write commit for palettes").** The calibration sweeps above (see "Calibration-sweep
findings") proved the residual is **not** fixable by tuning *when the store commits* —
because `LCDC` carries both fetch-stage bits (`.3/.4/.5`, want early commit) and
output-stage bits (`.0/.1/.2`, want late), one commit time can't satisfy both. The
root cause is that our FIFO emits ~1 M-cycle too eagerly, so the gap between the
fetch sample and the output sample is too small. Fix the *depth*, not the commit:
- The instrumentation already exists: `gpu.dbg_emit_lead` (output-latch dots) and
  `cpu.CPU.dbg_write_k` (intra-M-cycle commit via `tick_write_at`), both set from
  `$EMIT_LEAD`/`$WRITE_K` in `testrunner`, no-op by default. Use them as the bench.
- Add a **real** pixel-output latch in the FIFO (not the global first-pixel stall the
  `dbg_emit_lead` knob uses — that lets the fetcher run ahead and corrupts SCY
  content; that's why `m3_scy_change` worsens). Model it so fetch-stage and
  output-stage samples are separated by the hardware depth (~8–12 dots) *for the same
  commit time*, leaving `BGP`-vs-`bg_map` and `tile_sel`-vs-`bg_en` simultaneously
  correct. Validate against `m3_bgp_change` (output) **and** `m3_scx_high_5_bits`
  (fetch) at once — both must drop together, with the row-40 transition trace matching
  the reference 13/60/11/60 band widths.
- Content-neutrality: the latch shifts `links_awakening`'s mid-line SCX raster — that
  is expected and a *correctness* change, so re-baseline that one golden and eyeball
  it (as Bucket C did for the `%256` fix), don't gate on byte-identity.
- Guard: timer writes (`FF04`–`FF07`) must keep tick-before-write (cycle-accurate plan
  pitfall #3). Keep the `mode3_length()` parity assert on through bring-up.

(Per-register commit-time tuning — the old Step 1/2 — is a dead end for `LCDC`; it is
left available behind `$WRITE_K` only as a measurement tool.)

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
