#!/bin/sh
# Chassis drive: chassis_drive.sv and the top level against the UGV02 chassis model (Verilator 5).
#   ./simulate.sh         every check; PASS or FAIL at the end, the chassis model's report in sim.log
#   ./simulate.sh wave    only the first command, into waveform.fst, then GTKWave with chassis.gtkw
set -e
export LC_ALL=C
[ "$1" = "wave" ] && plusargs="+wave" || plusargs=""
rm -rf obj_dir
# PROCASSINIT: the flip-flops' power-up values (Quartus loads them); WIDTHEXPAND: harmless comparisons in display.sv
# and uart_tx.sv. Both are switched off so that verilator.log shows only what matters.
verilator -Wall -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-PROCASSINIT -Wno-WIDTHEXPAND \
  --trace-fst --timing --assert \
  --top chassis_drive_tb --cc tb/chassis_drive_tb.sv tb/ugv02_model.sv \
  rtl/uart_tx.sv rtl/chassis_drive.sv rtl/seven_seg.sv rtl/display.sv rtl/top_level.sv \
  --main --exe -CFLAGS -O1 > verilator.log 2>&1 || { grep -E "%Error" verilator.log | head; exit 1; }
make -s -C obj_dir -f Vchassis_drive_tb.mk Vchassis_drive_tb VM_PARALLEL_BUILDS=0 > /dev/null \
  || { echo "The C++ compile failed (\"Killed\": out of memory; \"No space left on device\": out of disk)."; exit 1; }
./obj_dir/Vchassis_drive_tb $plusargs | tee sim.log | grep -E "^===|^  ok|^FAIL|^PASS|^FAILED|^wave"
if [ "$1" = "wave" ]; then
  echo "\n *** Note: run ./simulate.sh wave in a terminal to keep GTKWave open for longer. ***"
  echo "     Then, to open the display, click the display icon next to the terminal button at the top-right of the workspace."
  gtkwave waveform.fst chassis.gtkw
fi
