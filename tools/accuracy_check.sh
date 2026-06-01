#!/usr/bin/env bash
# Quick accuracy validation net for the cycle-accurate CPU conversion.
# Builds the testrunner and runs blargg cpu, mooneye timer, and the target
# instruction-timing tests. Usage: tools/accuracy_check.sh
set -e
ZIG=~/.local/share/zigup/0.16.0/files/zig
cd "$(dirname "$0")/.."
$ZIG build testrunner 2>&1 | tail -5

echo ""
echo "############ BLARGG CPU (11 sub-tests + instr_timing = 12/12) ############"
./zig-out/bin/testrunner blargg games/blargg/0*.gb games/blargg/1*.gb 2>&1 | tail -2

echo ""
echo "############ MOONEYE TIMER (must stay 13/13) ############"
./zig-out/bin/testrunner mooneye games/mooneye/acceptance/timer/*.gb 2>&1 | tail -2

echo ""
echo "############ TARGET INSTRUCTION-TIMING TESTS ############"
./zig-out/bin/testrunner mooneye \
  games/mooneye/acceptance/call_timing.gb \
  games/mooneye/acceptance/call_timing2.gb \
  games/mooneye/acceptance/call_cc_timing.gb \
  games/mooneye/acceptance/call_cc_timing2.gb \
  games/mooneye/acceptance/jp_timing.gb \
  games/mooneye/acceptance/jp_cc_timing.gb \
  games/mooneye/acceptance/ret_timing.gb \
  games/mooneye/acceptance/ret_cc_timing.gb \
  games/mooneye/acceptance/reti_timing.gb \
  games/mooneye/acceptance/push_timing.gb \
  games/mooneye/acceptance/pop_timing.gb \
  games/mooneye/acceptance/rst_timing.gb \
  games/mooneye/acceptance/add_sp_e_timing.gb \
  games/mooneye/acceptance/ld_hl_sp_e_timing.gb \
  games/mooneye/acceptance/ei_sequence.gb \
  games/mooneye/acceptance/if_ie_registers.gb \
  games/mooneye/acceptance/ei_timing.gb \
  games/mooneye/acceptance/intr_timing.gb \
  games/mooneye/acceptance/div_timing.gb \
  games/mooneye/acceptance/oam_dma_timing.gb \
  games/mooneye/acceptance/oam_dma_start.gb \
  games/mooneye/acceptance/oam_dma_restart.gb \
  2>&1 | tail -25

echo ""
echo "############ BLARGG instr_timing ############"
./zig-out/bin/testrunner blargg games/instr_timing.gb 2>&1 | tail -2
