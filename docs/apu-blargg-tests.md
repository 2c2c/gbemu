# blargg APU tests — status & implementation notes

The blargg `dmg_sound` suite (`games/blargg/apu/`) exercises the APU's obscure
timing/quirk behavior. Status: **12/12 pass** (all of `01`–`12`).

Run them with:

```
find games/blargg/apu -name '*.gb' -print0 | xargs -0 ./zig-out/bin/testrunner blargg
```

The suite was brought from 1/12 to 12/12 by the four fixes below (all in
`src/apu.zig`). They're grouped by the root cause they addressed; the per-test
table at the bottom maps each ROM to the fix that unblocked it.

---

## A. APU power write-gate — `01`, `11`
While the APU is off (`NR52` bit 7 = 0) `write_apu_register` now ignores writes
to every register **except** `NR52` itself, wave RAM, and — on DMG — the
length-load bytes `NR11/NR21/NR31/NR41` (length portion only; the duty bits of
NRx1 stay locked while off). Power-off clears `$FF10–$FF25` but **preserves** the
length counters (DMG keeps them; saved/restored around the clear loop).

`11` additionally needed two enable rules that were missing: a trigger only keeps
a channel enabled if its **DAC** is on (NRx2 upper 5 bits non-zero for the square/
noise channels), and `11 #3` relies on the sweep-on-trigger overflow check from C.

## C. Channel-1 sweep unit — `04`, `05`, `06`
Implemented as `sweep_calculate` + `sweep_clock` (state-machine):
- On trigger, if shift > 0 the overflow check runs immediately and can disable
  the channel (`06`, `04 #2`).
- The 128 Hz step does calculate → write-back (shadow + live freq + NR13/NR14) →
  calculate-again-for-overflow, with period 0 reloaded as 8 (`05 "period 0 as 8"`).
- The negate-mode quirk: a `sweep_negate_used` flag set whenever a calc runs in
  negate mode (cleared on trigger); clearing NR10's negate bit afterwards
  disables the channel (`05 #4/#5`), while period-0 / shift-0 cases that never
  actually calc do **not** (`05 #6`).

## B. Frame sequencer / length quirks — `02`, `03`, `07`
The 512 Hz frame sequencer is now derived from the **system DIV counter** (the
timer's `internal_clock`, passed into `apu.step`), tracked via `prev_div_bit` +
an explicit `frame_step` (0-7). This makes DIV writes shift its phase, which the
`sync_apu`/`sync_sweep`/`delay_apu` test helpers depend on (`07`, and the precise
sweep-clock placement in `05 #6`). Power-up resets `frame_step` to 0 but leaves
`prev_div_bit` alone, so the first step fires at the next DIV bit-12 falling edge.

Length handling was rebuilt to match hardware:
- Writing NRx1 reloads the length counter immediately (`02 #3`).
- Length counters are clocked centrally (in `apu.step`) so they keep counting
  even while a channel is disabled (`02 #11`).
- The "extra length clock" quirk: enabling length (NRx4 0→1) — or triggering a
  zero-reloaded length — while the frame sequencer's next step won't clock length
  (`extra_length_clock`, odd `frame_step`) applies one immediate clock (`03`).
- Trigger only reloads the length counter when it's zero (`02 #5/#6`).

## D. Channel-3 wave-RAM access timing — `09`, `10`, `12`
Modeled after binjgb's cycle-exact behavior:
- A monotonic `current_tick` and a per-channel `sample_time` (the tick of the
  last wave fetch). While ch3 plays, a CPU read of wave RAM returns `0xFF` unless
  `current_tick == sample_time` (then it returns the byte at `current_sample/2`);
  writes follow the same window (`09`, `12`).
- The first fetch after trigger is delayed `+6` ticks; re-triggering while
  playing and exactly 2 ticks from a fetch corrupts the first bytes of wave RAM
  (copy of the aligned 4-byte block / single byte) — the DMG bug (`10`).

These three are CRC tests sweeping the access window 2 ticks per iteration, so
they require the relative trigger→read cycle timing to be exact (it is, via the
cycle-accurate instruction timing).

---

## Per-test breakdown

| test | root cause |
|---|---|
| `01-registers` | A |
| `02-len ctr` | B (+ A for power, DAC-disable) |
| `03-trigger` | B |
| `04-sweep` | C |
| `05-sweep details` | C (+ B for sweep-clock timing) |
| `06-overflow on trigger` | C |
| `07-len sweep period sync` | B |
| `08-len ctr during power` | A (length preserved across power-off) |
| `09-wave read while on` | D |
| `10-wave trigger while on` | D |
| `11-regs after power` | A (+ C for the on-trigger sweep overflow) |
| `12-wave write while on` | D |

No regressions: blargg CPU 12/12, mooneye timer 13/13, and the tetris / kirby /
dr_mario WASM traces are byte-identical to before these changes.
