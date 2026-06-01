# Remaining accuracy tests — status & plan

Written after the Tier-1 PPU-timing work landed (`docs/ppu-timing-tests.md`,
commit `7bd02f6`). This catalogues **everything still failing or un-graded** across
the test suites in `games/`, classifies each by whether it's a real bug, a
structural impossibility, or a harness gap, and lays out how to tackle each one
**without regressing** the large body of passing tests.

Run everything with the native runner (ReleaseFast):

```
zig build testrunner
./zig-out/bin/testrunner mooneye games/mooneye/acceptance/**/*.gb
./zig-out/bin/testrunner blargg  games/blargg/*.gb games/blargg/apu/*.gb
```

---

## Current scoreboard (measured)

| suite | score | notes |
|---|---|---|
| blargg cpu_instrs + instr_timing | **2/2** (12/12 sub-tests) | done |
| blargg dmg_sound (APU) | **12/12** | done |
| mooneye acceptance/ppu | **12/12** | Tier 1 done |
| mooneye acceptance/timer | **13/13** | done |
| mooneye acceptance/{bits,interrupts,instr,oam_dma,serial} | all pass | done |
| mooneye acceptance (top-level, 41) | **31/41** | 10 fails = boot_* for other models + our `boot_hwio-dmgABCmgb` |
| mooneye emulator-only (MBC1/2/5, 28) | **28/28** | done (MBC2 now passes — the old "unimplemented" note was stale) |
| mooneye misc (8) | **0/8** | all CGB/AGB/SGB-model tests |
| mooneye madness (1) | 0/1 | `mgb_oam_dma_halt_sprites` (GB-Pocket model) |
| mooneye manual-only (1) | n/a | `sprite_priority` — needs visual inspection |
| mooneye utils (2) | 1/2 | dumpers, not pass/fail tests |
| mealybug-tearoom-tests (31) | **un-graded** | PPU *rendering* tests; no harness, no reference PNGs locally |
| microtests (513) | **un-graded** | custom result protocol; no grader |

So of the things the harness *can* grade, the only **non-structural** failure is
`boot_hwio-dmgABCmgb`. The big un-graded frontiers are mealybug (rendering) and
microtests (need a grader).

---

## Category A — `boot_hwio-dmgABCmgb` (1 test, our model, real)

This is the **only** failing test that targets our actual model (DMG-ABC). The
`mismatch` debug mode reports `addr=FF01 expected=80 actual=87` — i.e. a HWIO
register read-back disagreement. Two caveats and two leads:

- The `mismatch` record reads a fixed HRAM slot (`FF80`/`FF82`/`FF83`) that is the
  *boot_regs/boot_div* framework's convention; for `boot_hwio` the failing
  register it points at may be unreliable. **First step: trust the data less, dump
  more.** `testrunner bootdump games/mooneye/acceptance/boot_hwio-dmgABCmgb.gb`
  already prints our full `FF00..FF4B` at handoff — diff that against the
  expected-HWIO table the ROM embeds (the suite's `dump_boot_hwio` /
  `bootrom_dumper` utils, and gekkio's reference dumps, give the canonical values).
- **Lead 1 — serial/PPU handoff value.** If the real disagreement is `SB`/`SC` or a
  PPU register whose value depends on the exact handoff dot (`LY`/`STAT.mode`),
  the Tier-1 PPU changes may already have moved it; re-confirm and, if it's an
  `STAT`/`LY` value, check it against where our PPU sits at `PC=0x0100`.
- **Lead 2 — boot duration.** `src/timer.zig` carries `div_power_on = 0xEEB5`, a
  calibration that absorbs a ~4100-cycle boot-timing error coming from PPU timing
  during the logo-scroll VBlank waits. Now that the PPU is cycle-accurate, that
  constant should be able to shrink toward its true value and may move/clear this
  test as a side effect. Re-derive with
  `testrunner divsweep <rom> <start> <end> <step>` for `boot_div-dmgABCmgb` and
  `boot_hwio-dmgABCmgb`, then set the narrowest constant that keeps **all** of
  `boot_div`/`boot_hwio`/`boot_sclk_align`/timer green.

**Regression guard:** `div_power_on` is load-bearing for the whole boot/timer
family. Any change must keep `acceptance/timer` 13/13, `serial` 1/1, and the
already-passing `boot_*-dmgABCmgb` (div, regs) green. Sweep before/after.

---

## Category B — other hardware models (≈26 tests, structural)

These verify the boot state / quirks of revisions we do not emulate. They can
**never** pass while the core is a fixed DMG-ABC:

- `acceptance/`: `boot_div-dmg0`, `boot_div-S`, `boot_div2-S`, `boot_hwio-dmg0`,
  `boot_hwio-S`, `boot_regs-dmg0`, `boot_regs-mgb`, `boot_regs-sgb`,
  `boot_regs-sgb2`
- `misc/`: `boot_div-A`, `boot_div-cgb0`, `boot_div-cgbABCDE`, `boot_hwio-C`,
  `boot_regs-A`, `boot_regs-cgb`, `bits/unused_hwio-C`, `ppu/vblank_stat_intr-C`
- `madness/mgb_oam_dma_halt_sprites` (GB-Pocket)

**Plan: leave them out of the pass target.** The clean fix is *model variants* —
parameterise the power-on register file (`AF/BC/DE/HL/SP`, `DIV`), the boot-ROM
image, and the handful of model-specific HWIO/STAT quirks behind a `Model` enum
(`dmg0`, `dmgABC`, `mgb`, `sgb`, `sgb2`, `agb`, `cgb`). Only worth doing if the
project wants multi-model support; it's orthogonal to emulation correctness and
**not** required for any game.

**Regression guard:** if model variants are added, gate every model-specific value
behind the enum with `dmgABC` as the unchanged default, so the existing
`*-dmgABCmgb` results don't move. CGB tests additionally need a CGB PPU/DMA, which
is a much larger effort — treat separately.

---

## Category C — mealybug-tearoom-tests (31, rendering — the Tier-2 frontier)

These are **pixel-level PPU rendering** tests (`m3_*` = mid-mode-3 register writes:
BGP/LCDC/SCX/SCY/WX/OBP changed *while a scanline is being drawn*; `m2_*` = a
window-enable toggle). They pass by comparing the framebuffer to a reference PNG.
Two things are missing:

1. **A pixel-accurate PPU.** Our PPU renders each scanline *all at once* when mode 3
   ends, so a register written mid-scanline applies to the whole line, not the
   pixels after the write. mealybug exists precisely to catch that. The fix is the
   **Tier-2 pixel-FIFO/fetcher** rewrite (see `docs/ppu-timing-tests.md` §"Tier 2"):
   a per-dot background/window fetcher + 8-pixel BG FIFO + sprite FIFO with mid-line
   OBJ-fetch stalls and mid-line window activation, driven inside mode 3.
2. **A screenshot-diff harness.** No reference PNGs ship in the repo
   (`find games/mealybug-tearoom-tests -name '*.png'` → 0). The mealybug repo ships
   `expected/DMG-blob/*.png`; we'd vendor those, then extend the existing WASM
   golden driver (which already hashes the framebuffer in `tools/wasm_golden.mjs`)
   to dump the 160×144 buffer and compare it to the reference — or grade natively
   by hashing `gpu.canvas` against a stored per-test hash.

**Plan (ordered):**

1. **Harness first, on what we have.** Add a `testrunner render <rom> <hash>` mode
   that runs N frames and prints/compares a hash of `gpu.canvas`. Capture current
   hashes for dmg-acid2 + a few games as a *baseline* so the FIFO rewrite can be
   checked for "no visual change on already-correct ROMs" before mealybug refs even
   arrive.
2. **Vendor the DMG reference PNGs** and add a PNG→hash compare (or pixel diff with
   a small tolerance for the known palette).
3. **Build the pixel FIFO** keeping the existing `tick_dot` mode/LY/STAT bookkeeping
   as the *outer* loop and driving the FIFO *inside* mode 3. This subsumes Tier-1
   items (sprite penalty, SCX penalty, mode-3 length) — they fall out of the FIFO
   naturally — so delete the analytic `mode3_length()` penalty only **after** the
   FIFO reproduces the same lengths.

**Regression guard (critical — this rewrite touches the hottest path):**
- The 12/12 `acceptance/ppu` timing tests are the contract: the FIFO must produce
  the **same mode-3 lengths** the analytic model now produces (SCX&7 + the
  per-object 6 + `5−min(5,(x+SCX)&7)`-per-tile-column penalty). Keep both
  implementations behind a flag during bring-up and assert they agree dot-for-dot
  before deleting the old one.
- Keep `internal_mode` / `stat.ppu_mode` (1-dot read delay), the read/write access
  gating helpers (`{oam,vram}_locked` / `{oam,vram}_write_blocked`), and
  `refresh_stat_line` exactly as-is — they are observation-timing, independent of
  *how* pixels are produced.
- Run the **WASM golden** (`tools/verify_wasm.sh`) before/after; the static screens
  of tetris/kirby/dr_mario must stay byte-identical (animated frames may drift only
  if timing changes — they should not, since the FIFO must match current mode-3
  lengths). Note the committed `tools/golden/*.wasm.txt` are currently stale
  (pre-date this branch) — **re-baseline them once** at the start of Tier 2 on a
  known-good build so the diff is meaningful.

---

## Category D — microtests (513, need a grader)

A large suite of focused single-behaviour ROMs (`000-oam_lock`, `001-vram_unlocked`,
`002-vram_locked`, `007-lcd_on_stat`, `500-scx-timing`, `800-ppu-latch-*`,
`div_inc_timing_*`, `dma_*`, …). Many overlap behaviours we *already* implement
correctly (OAM/VRAM lock windows, LCD-on STAT, DMA) — we just can't read their
verdict because they don't use the mooneye fib magic or blargg serial.

**Plan:**
1. **Reverse-engineer the result protocol** for this specific suite (these are not
   gekkio mooneye ROMs). Typical microtest conventions: a result byte written to a
   fixed RAM/HRAM address, or a solid screen colour (green=pass / red=fail). Pick
   2–3 ROMs whose answer we know (e.g. `001-vram_unlocked`, `002-vram_locked`),
   step them in `testrunner watch`, and find where the verdict lands.
2. **Add `testrunner microtest <rom...>`** grading by that convention (a RAM
   location or a framebuffer-colour check, reusing the Category-C hash plumbing).
3. Triage: expect a high pass rate immediately from the Tier-1 work (the lock/STAT
   timing tests), with the `8xx-ppu-latch-*` family gated on the Tier-2 FIFO.

**Regression guard:** the grader is read-only test tooling — it cannot regress
emulation. The risk is mis-grading (false pass/fail); validate the grader against
ROMs with a known verdict before trusting the aggregate number.

---

## Category E — not auto-gradeable (leave as-is)

- `manual-only/sprite_priority` — designed for visual inspection; no magic value.
  Best handled by the Category-C render harness as a screenshot check, if at all.
- `utils/bootrom_dumper`, `utils/dump_boot_hwio` — tools, not tests (the latter
  happens to reach fib magic and "passes"). Ignore for scoring.

---

## Suggested order of work

1. **Category A** — `boot_hwio-dmgABCmgb` + `divsweep` re-derivation. Small, real,
   and validates that the PPU timing changes tightened the boot clock. (Hours.)
2. **Category D harness** — the microtest grader. Cheap, and likely converts a big
   chunk of 513 to green immediately, giving a wide regression net for step 3.
3. **Category C** — the pixel-FIFO rewrite + render harness + mealybug refs. The
   large, high-value item; the microtest `8xx-ppu-latch-*` family and mealybug both
   depend on it. Do it behind a parity flag against the analytic mode-3 model.
4. **Category B** — model variants, only if multi-model support becomes a goal.

## The standing regression rule

Before and after **every** change, run the full native sweep and require no
movement except the intended deltas:

```
./zig-out/bin/testrunner blargg  games/blargg/*.gb games/blargg/apu/*.gb     # 25/25
./zig-out/bin/testrunner mooneye games/mooneye/acceptance/**/*.gb            # ppu 12/12, timer 13/13, …
./zig-out/bin/testrunner mooneye games/mooneye/emulator-only/**/*.gb         # 28/28
tools/verify_wasm.sh ~/.local/share/zigup/0.17.0-dev.633+9c5655093/files/zig # games render unchanged
```

The 31/41 acceptance and 0/8 misc lines are the structural (Category B) baseline —
they should stay exactly there unless model variants are deliberately added.
