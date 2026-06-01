# Remaining test failures — status & plan (PPU timing)

> **Update — Tier 1 complete: mooneye acceptance/ppu is now 12/12.** All seven
> Bucket-1 timing tests pass on the dot-stepped PPU. See "Tier 1 — DONE" below for
> what landed. The only remaining mooneye gaps are the other-hardware-model boot
> tests (structural, not real bugs) and the un-gradeable rendering suites
> (mealybug/microtests). No regressions across blargg (26/26), the rest of mooneye
> acceptance, or the MBC suite (28/28).

Snapshot after the APU work landed (`docs/apu-blargg-tests.md`). The emulator
now passes everything **except** a cluster of PPU cycle-timing tests plus a set
of other-hardware-model boot tests that can't pass structurally.

## Scoreboard

| suite | score | notes |
|---|---|---|
| blargg cpu + instr_timing + dmg_sound | **26/26** | done |
| mooneye acceptance/timer | **13/13** | done |
| mooneye acceptance/interrupts, instr, bits, serial, oam_dma | all pass | done |
| mooneye emulator-only (MBC1/2/5) | **28/28** | done |
| mooneye acceptance/ppu | **12/12** | ← Tier 1 done (was 5/12) |
| mooneye boot_* (our model: `dmgABCmgb`) | 1 fail | `boot_hwio-dmgABCmgb` |
| mooneye boot_* / misc (other models) | many fail | not real bugs (see below) |

Run the PPU suite:

```
./zig-out/bin/testrunner mooneye games/mooneye/acceptance/ppu/*.gb
```

---

## Bucket 1 — genuine PPU timing failures (7)

These target DMG-ABC and are real accuracy gaps. The current PPU
(`src/gpu.zig`) is a **dot-stepped mode approximation**: `tick_dot` advances a
per-line dot counter, derives the mode from `(ly, dot)`, latches `line3_len` at
the start of mode 3, and renders the **whole scanline at once** when mode 3 ends.
There is no pixel FIFO/fetcher, no per-sprite mode-3 penalty, no VRAM/OAM access
locking by mode, and no special handling for the frame the LCD is switched on.

| test | what it checks | current gap |
|---|---|---|
| `intr_2_mode0_timing` | exact dot mode 3→0 (HBlank) begins, synced off a mode-2 STAT IRQ | mode-3 length / boundary off by a few dots; STAT-vs-mode-change alignment |
| `intr_2_mode3_timing` | exact dot mode 2→3 begins | same boundary-alignment issue |
| `intr_2_oam_ok_timing` | OAM becomes inaccessible exactly when mode 2 starts | no VRAM/OAM access locking by mode (reads ignore mode) |
| `intr_2_mode0_timing_sprites` | mode-3 length grows with sprites on the line | `mode3_length()` only adds the `SCX&7` penalty — **no sprite penalty** |
| `lcdon_timing-GS` | first frame after LCDC.7 0→1: short first line, mode/LY/LYC startup | no LCD-on special-casing — PPU resumes as if mid-frame |
| `lcdon_write_timing-GS` | exact dot VRAM/OAM/regs become writable after LCD-on | same as above + no mode-gated writes |
| `stat_lyc_onoff` | LYC=LY STAT IRQ timing while toggling LYC / the LYC-enable bit mid-line | LYC compare is continuous; needs the 1-dot-delayed compare + write timing |

What already passes and constrains the fix (don't regress these):
`hblank_ly_scx_timing-GS`, `intr_1_2_timing-GS`, `intr_2_0_timing`,
`stat_irq_blocking`, `vblank_stat_intr-GS`. So the **mode-2 start** timing, the
SCX penalty, the STAT rising-edge "blocking", and the VBlank/OAM STAT pulse are
all correct — the gaps are specifically the **mode 2↔3↔0 boundaries**, **sprite
penalty**, **mode-gated memory access**, and the **LCD-on frame**.

---

## Bucket 2 — `boot_hwio-dmgABCmgb` (1, investigate)

Our model's only failing boot test. The `mismatch` debug mode reports
`addr=FF01 expected=80 actual=87`, i.e. a HWIO register read-back mismatch — but
that record may be unreliable for this test's HRAM layout. Two leads to check:
1. The post-boot value our DMG bootloader leaves in the sampled registers
   (serial `SB`/`SC`, or a PPU register whose value depends on the exact handoff
   dot — `LY`/`STAT.mode`).
2. The same boot-duration inaccuracy that forced `Timer.div_power_on = 0xEEB5`
   (see `src/timer.zig`): the calibration absorbs a ~4100-cycle boot error that
   comes from PPU timing during the logo-scroll VBlank waits. Fixing the PPU
   timing below should let this constant shrink toward its true value and may
   resolve this test as a side effect. Re-derive with `testrunner divsweep`.

---

## Not real failures — other hardware models

The emulator is a **DMG-ABC**. These check the boot state / quirks of other
revisions and can never match without emulating those models. Ignore unless we
decide to add model variants:

- `boot_div` / `boot_hwio` / `boot_regs` for `dmg0`, `S`/`sgb`/`sgb2` (Super GB),
  `mgb` (GB Pocket), `A` (AGB), `cgb*`/`C` (Game Boy Color)
- `misc/bits/unused_hwio-C`, `misc/ppu/vblank_stat_intr-C` (CGB-specific)

## Not gradeable by the current harness

- **mealybug-tearoom-tests** — PPU **rendering** tests, verified by comparing the
  framebuffer to reference PNGs. A pixel-accurate PPU (below) is what these need;
  they'd require a screenshot-diff harness (the WASM golden driver already hashes
  the framebuffer — extend it to dump/compare against the reference images).
- **microtests** (513 ROMs) — write their result to a fixed RAM location rather
  than the mooneye fib magic; need a small dedicated grader in `testrunner.zig`.

---

## Plan

Two tiers. Tier 1 is the cheap path to clear most of Bucket 1 on the existing
dot-stepped model; Tier 2 is the principled rewrite that also unlocks mealybug.

### Tier 1 — DONE (all 7 landed on the dot-stepped PPU)

What actually shipped (in `src/gpu.zig` + `src/memory_bus.zig`):

1. **STAT mode-read is delayed one dot.** `tick_dot` keeps the true current mode
   in `internal_mode` (drives interrupts, edges, rendering) and copies the
   *previous* dot's mode into the register field `stat.ppu_mode`. A CPU read
   latches near the end of its M-cycle, so it observes the prior dot — this is the
   exact boundary `intr_2_mode0_timing` / `intr_2_mode3_timing` pin. (Decoded the
   tests: the OAM STAT IRQ handler `ADD SP,2; RET` discards the HALT continuation
   and returns into `main`, so the measurement runs at a fixed offset from the IRQ;
   diagnosed with the new `testrunner ppudump`.)

2. **Mode-gated VRAM/OAM access, asymmetric & read/write-split** (`intr_2_oam_ok_timing`,
   `lcdon_timing-GS`, `lcdon_write_timing-GS`). `GPU.{oam,vram}_locked()` (reads) and
   `GPU.{oam,vram}_write_blocked()` (writes). Reads lock immediately on entering
   mode 2/3 (true `internal_mode`) but release one dot late (`stat.ppu_mode` lags) —
   the OR of the two. VRAM writes gate purely on the delayed register mode 3; OAM
   writes on `register==3 or (register==2 and internal==2)` (a one-dot write hole at
   the mode 2→3 edge). Rendering reads VRAM directly, so it is unaffected.

3. **Per-object mode-3 penalty** (`intr_2_mode0_timing_sprites`). `mode3_length()`
   adds 6 dots per fetched object (OAM x < 168, max 10 by the vertical OAM scan)
   plus `5 - min(5,(x+SCX)&7)` once per background tile column (a run sharing a
   column pays the BG-fetch wait once). Verified against all 35 testcases (the
   ROM's `D`/`E` are calibrated NOP-sled delays bracketing the mode-0 dot to ±4).

4. **Edge-aware LYC + STAT line** (`stat_lyc_onoff`). The combined STAT line is now
   computed by one helper `GPU.refresh_stat_line()` driven every dot *and* after the
   register writes that change it (LCD enable, and the LCD-off freeze). The LYC=LY
   register bit reads 0 on the first dot of each line (compare redone one dot in) via
   `internal_lyc_compare`; the interrupt source uses the immediate compare. LCD-off
   re-latches the line from the frozen LYC source (no spurious edge on re-enable);
   LCD-on re-evaluates against fresh LY=0 and fires immediately on a new match.

5. **LCD-on first frame** (`lcdon_timing-GS`, `lcdon_write_timing-GS`, `stat_lyc_onoff`).
   `lcd_first_line` flag: line 0 after enable has no OAM scan (the mode-2 window
   reads mode 0, fires no OAM IRQ), its pixel transfer starts one dot early (dot 79),
   and the line is 4 dots short (452, so LY reaches 1 at dot 452). Reverse-engineered
   the read/write measurement framework (offsets `nops*4+8` from the enable write)
   with the new `testrunner lcdondump`.

Diagnostics added to `testrunner.zig`: `ppudump` (dumps the mooneye reg-assert
framework's measured-vs-expected) and `lcdondump` (dumps the lcdon sample buffer
against its expected table). Both are read-only and don't touch the core.

---

### Tier 1 — original plan (for reference)

1. **Sprite mode-3 penalty** (`intr_2_mode0_timing_sprites`). In
   `mode3_length()`, after the `SCX&7` term, add the per-sprite penalty: scan
   the up-to-10 objects visible on the line and add each one's cost. The mooneye-
   accurate rule is the SameBoy/Pan Docs model — for each sprite, `6 - min(5,
   (x + SCX) & 7)` dots (plus the fixed costs), capped at 10 sprites. Latch this
   at the same `dot == MODE2_DOTS` point where `line3_len` is sampled today.

2. **Mode-gated VRAM/OAM access** (`intr_2_oam_ok_timing`,
   `lcdon_write_timing-GS`). In `memory_bus.zig` read/write paths, return `0xFF`
   (read) / drop (write) for VRAM during mode 3, and OAM during modes 2 and 3
   (and while OAM DMA is active, which is already handled). Gate on
   `gpu.lcdc.lcd_enable and gpu.stat.ppu_mode`.

3. **Exact mode-boundary / STAT alignment** (`intr_2_mode0_timing`,
   `intr_2_mode3_timing`). Verify the dot at which each mode is first *observable*
   vs. when its STAT source asserts. mooneye expects mode 3 to start at dot 80 and
   mode 0 at dot `80 + line3_len`; the STAT mode-0 source and the register read of
   `STAT.mode` may need a 1-dot offset relative to the internal transition. Bisect
   against the test's expected cycle counts (the ROM reports the off-by-N).

4. **LYC compare timing** (`stat_lyc_onoff`). The `LY==LYC` flag updates one dot
   into the line (not at dot 0), and writing `LYC`/toggling `STAT.6` re-evaluates
   the compare immediately. Replace the continuous compare with an edge-aware one.

5. **LCD-on frame** (`lcdon_timing-GS`, `lcdon_write_timing-GS`). On LCDC.7 0→1
   (handle in the `0xFF40` write in `memory_bus.zig`): reset `cycles=0`, `ly=0`,
   start the first line in mode 0 (not 2) with a shortened mode-3, suppress the
   first frame's output, and don't fire a mode-2 STAT on the enable line. On 1→0,
   blank LY/mode (already partly handled — verify reads return 0/mode 0).

After Tier 1, re-run `divsweep` to see whether `div_power_on` can drop and
whether `boot_hwio-dmgABCmgb` clears.

### Tier 2 — pixel-FIFO / fetcher PPU (the principled fix)

Replace `render_scanline`-at-mode-3-end with a real per-dot background/window/
sprite FIFO + fetcher state machine. This naturally produces correct mode-3
lengths (SCX, window-trigger, and sprite stalls all fall out), makes VRAM/OAM
locking exact, and is what the **mealybug** rendering tests require. It subsumes
Tier 1 items 1–3. Scope it as: fetcher (tile → data-low → data-high → push),
8-pixel BG FIFO, sprite FIFO with mid-line OBJ fetch stalls, and the window
mid-line activation. Keep the existing `tick_dot` mode/LY/STAT bookkeeping as the
outer loop and drive the FIFO inside mode 3.

### Suggested order

1. Tier 1 #2 (mode-gated access) + #1 (sprite penalty) — 2 tests, localized.
2. Tier 1 #3 (boundary alignment) — 2 tests, bisect against the ROM output.
3. Tier 1 #4 (LYC) + #5 (LCD-on) — 3 tests, trickiest.
4. Revisit `div_power_on` / `boot_hwio-dmgABCmgb`.
5. Tier 2 only if pixel-accurate rendering (mealybug) becomes a goal — otherwise
   Tier 1 is enough to clear the mooneye PPU suite.
