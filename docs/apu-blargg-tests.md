# blargg APU tests — status & how to tackle each

The blargg `dmg_sound` suite (`games/blargg/apu/`) exercises the APU's obscure
timing/quirk behavior. Current score: **1/12 pass** (only `08-len ctr during
power`). The other 11 are the long-standing APU accuracy gaps.

Run them with:

```
find games/blargg/apu -name '*.gb' -print0 | xargs -0 ./zig-out/bin/testrunner blargg
```

The failures cluster into four root causes. Fixing the shared infrastructure
below knocks out most of the suite; the per-test notes then say what's left.

---

## Shared infrastructure (fix these first)

### A. APU power (NR52 bit 7) write-gating — unblocks `01`, `11`
`write_apu_register` (src/apu.zig) has its "ignore writes while powered off"
guard **commented out** (it was disabled because a naive version masked NRx1 and
killed SML's length-enabled SFX). On real DMG hardware, while the APU is off
(`NR52` bit 7 = 0):
- writes to **all** registers are ignored, **except** `NR52` itself, and — on
  DMG only — the **length-load** bytes `NR11/NR21/NR31/NR41` (the length
  counters keep working while off) and wave RAM.
- all registers read back as if cleared.

The power-off path already clears `$FF10–$FF25` by writing 0, so the missing
half is re-introducing the *correct* DMG write-gate: ignore writes when off
except the four length registers + `$FF26` + wave RAM. This is the single
highest-value APU fix.

### B. Frame-sequencer / DIV alignment — unblocks `03`, `07`, helps `02`
The 512 Hz frame sequencer is already clocked off the falling edge of DIV bit 4
(`step()` in src/apu.zig, `(div >> 4) & 1`), which is correct. What's missing:
- On **power-up** the code resets `frame_sequence = 0`, but the *next* step's
  timing must follow the **current** DIV phase, not a fresh counter — this is
  exactly what `07-len sweep period sync` measures.
- The **"extra length clock"** quirk: writing `NRx4` with length-enable going
  0→1 while the sequencer is in the *first half* of a length period clocks the
  length counter once immediately. Needed by `03` (and the reload edge cases in
  `02`).

These need the length counters to consult the frame-sequencer phase at the
moment of the `NRx1/NRx4` write, rather than only on the periodic step.

### C. Channel-1 sweep unit — unblocks `04`, `05`, `06`
The trigger path (`$FF14`) sets `shadow_frequency`, `sweep_timer` (already maps
period 0 → 8), and `sweep_enable`, but it **does not run the overflow
calculation on trigger**. Hardware does: on trigger, if sweep **shift > 0**, it
immediately computes `shadow ± (shadow >> shift)` and disables the channel if
that overflows (> 0x7FF). Also the periodic 128 Hz sweep step must do the full
"calculate → write back to frequency + shadow → calculate again for the
overflow check" sequence, with period 0 reloaded as 8 each time. Implementing
the sweep unit as a small state machine covers `04`, `05`, `06` together.

### D. Channel-3 wave-RAM access timing — unblocks `09`, `10`, `12`
`read_apu_register`/`write_apu_register` currently read/write `wave_ram.byte[]`
directly with no regard for whether channel 3 is playing. On DMG, while ch3 is
enabled:
- a CPU **read** returns `0xFF` except during the ~1-cycle window when the wave
  unit itself is fetching a byte (then you see *that* byte);
- a CPU **write** is dropped except in that same window (then it writes the
  byte currently being fetched);
- **triggering** ch3 while it is about to advance corrupts the first few bytes
  of wave RAM (the infamous DMG bug).

This requires tracking which wave-RAM byte the channel is reading each cycle
(`current_sample` position + the cycle phase) and routing CPU access through it.
This is the most involved item and is DMG-specific (CGB lets you read freely).

---

## Per-test breakdown

| test | fails at | root cause | covered by |
|---|---|---|---|
| `01-registers` | `#6` "When off, should ignore writes to registers" | writes not gated while powered off | **A** |
| `02-len ctr` | `#3` "Length can be reloaded at any time" | length reload + frame-seq phase on `NRx1/NRx4` | **B** |
| `03-trigger` | `#3` "Enabling in first half of length period should clock length" | missing extra-length-clock quirk | **B** |
| `04-sweep` | `#2` "If shift>0, calculates on trigger" | sweep overflow calc not run on trigger | **C** |
| `05-sweep details` | `#2` "Timer treats period 0 as 8" | sweep period-0→8 in the periodic step + reload details | **C** |
| `06-overflow on trigger` | (freq dump) | sweep overflow on trigger doesn't disable the channel | **C** |
| `07-len sweep period sync` | `#5` "Powering up APU MODs next frame time" | frame-seq not aligned to DIV phase on power-up | **B** |
| `08-len ctr during power` | — **passes** | — | — |
| `09-wave read while on` | (RAM dump all `00`) | CPU reads raw wave RAM instead of DMG-restricted `0xFF`/window | **D** |
| `10-wave trigger while on` | (RAM dump) | trigger-while-on doesn't corrupt the first wave bytes | **D** |
| `11-regs after power` | `#2` "Powering off should clear NR12" | write-while-off to NR12 not ignored, so it isn't seen as cleared | **A** |
| `12-wave write while on` | (RAM dump) | CPU writes land in wave RAM unconditionally instead of only in the access window | **D** |

### Notes on the individual checks

- **`01` / `11`** are two sides of root cause **A**. `11` writes a register
  *after* powering off and expects the value not to stick; `01` walks every
  register while off. Both pass once the write-gate is restored with the DMG
  length-register exception.
- **`02` / `03`** are the "length counter obscure behavior" tests. The hard part
  is the extra-length-clock: it depends on whether the frame sequencer's *next*
  step is one that clocks length, which means the length logic has to know the
  current `frame_sequence` parity at write time.
- **`04` / `05` / `06`** all live in the sweep unit. `06`'s dump of repeated
  `07FF` is the channel failing to shut off after an on-trigger overflow.
- **`07`** is purely about the DIV→frame-sequencer relationship at power-up —
  closely related to the DIV-offset work already done for `boot_div`/`boot_sclk`.
- **`09` / `10` / `12`** are the wave-RAM-while-on trio (root cause **D**) and
  are the most expensive: they need cycle-accurate channel-3 sample fetching.

---

## Suggested order (cheapest → priciest)

1. **A** (power write-gate): 2 tests (`01`, `11`), small + localized.
2. **C** (sweep unit): 3 tests (`04`, `05`, `06`), self-contained in channel 1.
3. **B** (frame-seq/length quirks): 2–3 tests (`03`, `07`, helps `02`), needs
   frame-sequencer phase plumbed into the length writes.
4. **D** (wave-RAM access timing): 3 tests (`09`, `10`, `12`), the biggest lift;
   requires modeling ch3's per-cycle wave fetch.

Watch for regressions in actual games (SML SFX especially) when touching the
power write-gate and length handling — that's what disabled the original guard.
