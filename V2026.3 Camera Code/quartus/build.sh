#!/bin/sh
# Compile the camera project from a Linux shell, with Quartus Prime Lite 18.1's quartus/bin folder on the PATH:
#     cd quartus && sh build.sh
# (On Windows, use the Quartus window, or C:\intelFPGA_lite\18.1\quartus\bin64\quartus_sh.exe --flow compile Camera
# in a Command Prompt in this folder: README.md has it.)
# It does what Processing > Start Compilation does in the Quartus window. Quartus generates the VGA system
# (vga_sink.qsys) itself, then synthesises, fits, assembles and runs the timing analysis. At the end it prints
# the resources, the worst timing slack and any critical warning, and checks that output_files/Camera.sof exists.
set -e
command -v quartus_sh > /dev/null 2>&1 || {
  echo "quartus_sh is not on the PATH: add Quartus 18.1's quartus/bin folder to it, or open Camera.qpf in Quartus"
  echo "and compile there. On Windows, README.md has the Command Prompt commands."
  exit 1
}
# vga_sink.qsys comes with the project; if it has gone missing, make it again from its script
[ -f vga_sink.qsys ] || qsys-script --script=make_vga_sink_qsys.tcl
quartus_sh --flow compile Camera

echo
echo "== Resources (output_files/Camera.fit.summary)"
grep -E "Logic utilization|Total registers|Total block memory bits|Total RAM Blocks|Total DSP Blocks" output_files/Camera.fit.summary || true
# Quartus finishes without an error even when the design fails timing, so look at the slack: every one must be >= 0
echo "== Timing (output_files/Camera.sta.summary: every clock, setup and hold, all four corners)"
worst=$(awk '/^Slack/ { print $3 }' output_files/Camera.sta.summary | sort -g | head -n 1)
case "$worst" in
  "")  echo "no timing results: is Camera.sdc in the project?" ;;
  -*)  echo "TIMING FAILED: worst slack $worst ns. Do not trust this .sof; find the failing path in output_files/Camera.sta.rpt" ;;
  *)   echo "timing met: worst slack $worst ns" ;;
esac
echo "== Critical warnings"
crit=$(cat output_files/Camera.*.rpt | grep -E "^ *Critical Warning \(" | sort -u || true)
if [ -n "$crit" ]; then echo "$crit"; else echo "none"; fi
echo
ls -l output_files/Camera.sof
echo "Program it with the Programmer (Tools > Programmer; the FPGA is device 2 on the JTAG chain, after the HPS), or:"
echo '    quartus_pgm -m jtag -o "p;output_files/Camera.sof@2"'
