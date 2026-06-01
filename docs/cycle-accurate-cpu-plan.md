# Cycle-accurate CPU conversion — plan & recipe

Status: **DONE** (cycle-accurate core landed on `cycle-accurate-cpu`). The SM83
core now advances the timer/PPU/APU at M-cycle granularity, interleaved with each
memory access and internal cycle. The recipe below was followed; what shipped and
the remaining gaps are summarized here.

## Outcome (this pass)

Model implemented (transition form, lumps kept as clock source):
- `CPU.mcycle()` steps peripherals 4× (one M-cycle) and records `inline_ticked`;
  it also advances OAM DMA by one byte. `tick_read`/`tick_write` = `mcycle()` then
  the access (tick-before-access). The opcode fetch (+ CB op-byte fetch) tick in
  `step()`; every operand read, memory access, stack op and internal `[int]` cycle
  ticks in hardware order. `gameboy.frame()` reconciles `remaining =
  cpu_cycles_spent - inline_ticked` (== 0 for the now fully-converted core) and
  keeps the overstep assert (pitfall #2) as a permanent guard.
- Control flow restructured for correct ordering + not-taken operand reads
  (pitfall #4): `call` reads target before pushing; `jump`/`jump_relative` always
  read operands; `ret`/`reti`/`rst`/`push`/16-bit ALU place their `[int]` cycles.
- Interrupt dispatch is cycle-accurate (2 `[int]` + ticked push + 1 `[int]` = 20T).
- CB cycle accounting rewritten (it was inconsistent/double-counting): register
  ops = 2 fetch M-cycles, `(HL)` adds read(+write), BIT `(HL)` read-only.
- EI fixed so a run of consecutive EIs doesn't re-arm the 1-instruction delay.
- IF (FF0F) reads back bits 5-7 as 1.
- **Cycle-accurate OAM DMA** (memory_bus): 160-byte transfer over 160 M-cycles
  driven by `mcycle`, startup delay, restart, OAM-write block + read bus-conflict
  (non-HRAM reads return the in-flight byte). Fixed a latent OAM-readback bug
  (OAM lived in `gpu.vram` but reads returned the flat `memory` array). FF46 reads
  back its written value.

Results (native `zig build testrunner`):
- blargg CPU **12/12** (incl. `instr_timing`, which the old atomic core failed).
- mooneye timer **12/13** — `rapid_toggle` regressed (see gaps).
- mooneye flipped to PASS: `ei_sequence`, `if_ie_registers`, `pop_timing`,
  `oam_dma/basic` (plus `ei_timing`/`intr_timing`/`div_timing` stay green).
- Games verified rendering correctly via `tools/verify_wasm.sh` (re-baselined) and
  an 8-ROM smoke test (tetris, kirby, dr_mario, pokemon_blue, links_awakening,
  sml, sml2, donkey_kong). Native unit tests + `zig build check` green.

## Remaining gaps (need work beyond the CPU core)

- `rapid_toggle` (timer 12/13): timer-register accesses now step the timer to the
  exact access M-cycle (hardware-correct), but the `memory_bus` FF04/FF07
  falling-edge workaround was tuned for the *old* deferred-stepping model. The
  other 12 timer tests pass; reconciling this one needs a sub-M-cycle rework of the
  timer mux/edge model (a +1 T-cycle write-placement experiment did not fix it).
- The OAM-DMA-dependent timing tests — `jp/jp_cc/call/call2/call_cc/call_cc2/ret/
  ret_cc/reti/push/rst/add_sp_e/ld_hl_sp_e_timing` and `oam_dma_timing/start/
  restart`, `oam_dma/reg_read` — now *run to completion* (the bus conflict stopped
  the crashes) but still fail their precise assertions: they pin the DMA start/end
  to an exact T-cycle. A single startup-delay constant can't satisfy both
  `oam_dma/basic` and `oam_dma_timing`, so the DMA needs an exact hardware-T-cycle
  model (start latch + bus-hold boundary), not just M-cycle alignment.

Validation net: `tools/accuracy_check.sh` runs blargg CPU, mooneye timer, and the
target timing tests in one shot.

---

## Original plan & recipe (for reference)

This document was the recipe for a future, dedicated pass at making the SM83 core
cycle-accurate.

## Goal

Make the CPU advance the timer/PPU/APU at **M-cycle granularity**, interleaved
with each memory access and internal cycle — instead of executing an instruction
atomically and lumping all peripheral progress afterward.

Unlocks (currently failing because of atomic execution):
- blargg `instr_timing` (its "Timer doesn't work properly" is really an
  instruction-timing symptom now that the timer itself is hardware-correct).
- mooneye instruction-timing: `call_timing(2)`, `call_cc_timing(2)`, `jp_timing`,
  `jp_cc_timing`, `ret_timing`, `ret_cc_timing`, `reti_timing`, `push_timing`,
  `pop_timing`, `rst_timing`, `add_sp_e_timing`, `ld_hl_sp_e_timing`,
  `ei_sequence`, `if_ie_registers`.
- `oam_dma_timing`/`oam_dma_start`/`oam_dma_restart`, and timing-sensitive game
  effects (mid-scanline raster tricks, precise interrupts).

Definition of done: those tests pass **while** blargg stays 12/12 (CPU), mooneye
timer stays 13/13, and the golden games still run (re-baselined).

## Why the naive approaches fail (learned the hard way)

- **Atomic execution (today):** `cpu.step()` runs the whole instruction (all
  `self.bus.read_byte/write_byte`) and adds a lump `self.clock.t_cycles += N`;
  `gameboy.frame()` then steps peripherals N times *after*. Cycle counts are
  correct, but no instruction-internal timing is observable.
- **Bulk "tick at every memory access, defer internals to the end" shortcut:**
  attempted and reverted. Two showstoppers:
  1. It still **doesn't flip** the timing tests — they probe *internal*-cycle
     placement, which deferring-to-end gets wrong.
  2. It **regressed** `rapid_toggle` (a passing timer test): sampling the timer
     inline changes the timer state seen at a TAC write, and the write-edge logic
     didn't survive it. Cycle-accuracy is not additive on top of the current
     timer-write handling.
- So there is no shortcut: the internal cycles must be placed per-instruction,
  and the timer write path must be reworked.

## Foundation already in place (branch `cycle-accurate-cpu` @ `bd40b3d`)

Behavior-preserving scaffolding, validated green:
- `CPU.tick_peripherals_one()` — one T-cycle of `timer.step()` + `apu.step()` +
  `gpu.step(1)`, folds their IRQs into IF, sets `hit_vblank`. (Extracted verbatim
  from the old `gameboy.frame()` inner loop.)
- `CPU.inline_ticked: u64`, `CPU.hit_vblank: bool` fields; `step()` resets
  `inline_ticked = 0`.
- `gameboy.frame()` reconciliation: `remaining = cpu_cycles_spent - inline_ticked;`
  then steps `remaining` peripheral cycles. With nothing converted,
  `inline_ticked == 0` so it's identical to before.

This lets converted and unconverted instructions coexist during the transition.

## The model to implement

- `mcycle(self)`: `tick_peripherals_one()` ×4, `inline_ticked += 4`.
  - Transition option (keep lumps as clock source): `mcycle` does NOT touch
    `self.clock`. End-state option (cleaner): `mcycle` advances `clock += 4` and
    all lump `t_cycles += N` are removed. Pick the end-state for the final code;
    the transition form is only to convert incrementally.
- **Ordering: tick BEFORE the access.** A memory access is the *last* thing in
  its M-cycle, so peripherals advance first and the access observes post-step
  state. Helpers:
  - `tick_read(addr)  = { mcycle(); return self.bus.read_byte(addr); }`
  - `tick_write(a, v) = { mcycle(); self.bus.write_byte(a, v); }`
- Internal (non-memory) cycles: explicit `mcycle()` at the correct point.

## Pitfalls — must handle

1. **Never tick debug/non-instruction reads.** `cpu.beeg_print()` peeks 4 bytes
   (`self.bus.read_byte(self.pc ..)`) for a (suppressed) log line — Zig still
   evaluates the args, so converting these to `tick_read` over-steps peripherals
   (`inline_ticked` exceeds the instruction's cycles → `remaining` underflows
   `u64` → `gameboy.frame()` spins forever). Keep raw `self.bus.read_byte` in
   `beeg_print` and any memory-dump/peek helper. A blanket `replace_all
   bus.read_byte → tick_read` WILL hit these — exclude them.
2. **Add an overstep assert while converting:** in `gameboy.frame()`, if
   `inline_ticked > cpu_cycles_spent`, panic with `self.last_opcode`. It instantly
   pinpoints a stray ticking read (this is how `beeg_print` was found). Remove
   before shipping.
3. **Rework the timer write path (`memory_bus.write_io` FF04–FF07).** Inline
   stepping changes `timer.internal_clock` at the moment a TAC/DIV write applies
   its falling-edge check (`timer.clock_update` / `check_falling_edge`). Ensure
   the timer has been stepped up to exactly the write's M-cycle before applying
   the register change. Re-validate `rapid_toggle`, `div_write`, and `tim00..11`.
4. **Conditional branches read operands even when not taken** on hardware (e.g.
   `JP cc` is 3 M-cycles not-taken: fetch + 2 operand reads). The current
   `jump()`/`call()` helpers skip the reads when not taken. For accuracy, still
   consume those M-cycles (tick) even if the bytes are discarded.

## Per-instruction M-cycle reference (T = 4×M)

Internal cycles marked `[int]`. Order is the real execution order.

| Instruction | M-cycles |
|---|---|
| LD r,r' ; ALU r ; INC/DEC r ; DAA/CPL/CCF/SCF/RLA/RLCA/RRA/RRCA ; JP HL ; DI/EI ; NOP | fetch (1) |
| ALU n ; ALU (HL) ; LD r,(HL) ; LD r,n ; LD (HL),r ; LD A,(BC|DE) ; LD (BC|DE),A | fetch + 1 access (2) |
| LD (HL),n | fetch + read n + write (3) |
| INC/DEC (HL) | fetch + read + write (3) |
| LD rr,nn | fetch + read lo + read hi (3) |
| LD A,(nn) ; LD (nn),A | fetch + read lo + read hi + access (4) |
| LDH (n),A / A,(n) ; LD (C),A / A,(C) | fetch + [read n] + access (2–3) |
| LD (nn),SP | fetch + read lo + read hi + write lo + write hi (5) |
| LD SP,HL | fetch + [int] (2) |
| LD HL,SP+e | fetch + read e + [int] (3) |
| ADD SP,e | fetch + read e + [int] + [int] (4) |
| INC/DEC rr (16-bit) | fetch + [int] (2) |
| ADD HL,rr | fetch + [int] (2) |
| PUSH rr | fetch + [int] + write hi + write lo (4) |
| POP rr | fetch + read lo + read hi (3) |
| JP nn | fetch + read lo + read hi + [int set PC] (4); JP cc not-taken: fetch + read lo + read hi (3) |
| JR e | fetch + read e + [int] (3); JR cc not-taken: fetch + read e (2) |
| CALL nn | fetch + read lo + read hi + [int] + write hi + write lo (6); CALL cc not-taken: fetch + read lo + read hi (3) |
| RET | fetch + read lo + read hi + [int set PC] (4) |
| RET cc | taken: fetch + [int] + read lo + read hi + [int] (5); not taken: fetch + [int] (2) |
| RETI | fetch + read lo + read hi + [int] (4); set IME |
| RST | fetch + [int] + write hi + write lo (4) |
| CB reg op | fetch 0xCB + fetch op (2) |
| CB BIT (HL) | fetch 0xCB + fetch op + read (3) |
| CB RES/SET/shift (HL) | fetch 0xCB + fetch op + read + write (4) |
| Interrupt dispatch | [int] + [int] + push hi + push lo + [int set PC] (5 = 20T); only between instructions |
| HALT | fetch (1) then halt state |

Notes: the CB prefix is **two** fetch M-cycles (`step()` reads 0xCB, then the op
byte) — both tick. The interrupt dispatch (`CPU.handle_interrupt`) must also be
cycle-accurate (its `push` + internals).

## Execution plan (staged; validate after each stage)

1. Land `mcycle`/`tick_read`/`tick_write`; add the overstep assert (pitfall #2).
2. Tick the opcode fetch + CB op-byte fetch in `step()`. Exclude `beeg_print`
   (pitfall #1). Validate green.
3. Convert memory accesses to `tick_read`/`tick_write` (tick-before-access) per
   instruction group: loads → 8-bit ALU → INC/DEC → 16-bit → stack → control
   flow → CB → interrupt dispatch. Remove the corresponding lumps.
4. Place internal `mcycle()`s per the table (pitfall #4 for conditionals).
5. Rework the timer write path (pitfall #3); re-validate timer suite.
6. Re-baseline the wasm golden (`tools/verify_wasm.sh` will diff — intended) and
   confirm games still render correctly.

Validation net at every stage (all native via `zig build testrunner`):
- `testrunner blargg games/blargg/*.gb` → CPU must stay 12/12.
- `testrunner mooneye games/mooneye/acceptance/timer/*.gb` → must stay 13/13.
- target timing tests should flip on progressively.
- `tools/verify_wasm.sh <zig>` for game-behavior regression.

## Branch / state map (as of this session)

- `main` — Zig 0.14.1 → 0.16/0.17 migration; SDL via translate-c. (merged)
- `accuracy-tests` — **the banked wins**: timer fixes (`0bc8b36`, mooneye timer
  9/13 → 13/13, serial capture) + native accuracy harness `src/testrunner.zig` /
  `tools/*.mjs` (`f3babb0`). Branched off `main`.
- `cycle-accurate-cpu` @ `bd40b3d` — the green `tick()` foundation above.
- `backup/cycle-accurate-foundation` @ `6514228` — foundation + a NOP/PUSH/POP
  conversion spike (superseded; useful as worked examples of the tick pattern).

Toolchain: build with `~/.local/share/zigup/<ver>/files/zig`
(`0.16.0` or `master` = `0.17.0-dev`). `testrunner` grades blargg via serial /
`$A000`, mooneye via the register "fibonacci" magic.
