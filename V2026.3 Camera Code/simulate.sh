#!/bin/sh
# OV7670 camera project: unit benches with the camera model, then the whole system with the VGA monitor model.
#   ./simulate.sh            all benches
#   ./simulate.sh config     ov7670_config against the camera model (SCCB, resets, settle time)
#   FPS=25 ./simulate.sh config   the same with ov7670_config at 25 frames a second (top_level.sv's CAMERA_FPS)
#   ./simulate.sh capture    ov7670_capture: every pixel and coordinate checked against the model
#   ./simulate.sh buffer     frame_buffer: write at one clock, read at another
#   ./simulate.sh display    camera_display into the VGA Controller + monitor model (display_frame_*.png)
#   ./simulate.sh system     everything, pins to monitor: frame_*.png and camera.gif
#   ./simulate.sh barcode    a barcode reader on the live camera stream: barcode_frame_*.png and barcode.gif
#   ./simulate.sh handover   frame_buffer with 2 and 3 banks: the bank handover at its closest timings (not in "all")
# Verilator 5 (--timing). Run from the project root. Add "wave" as a second argument for a waveform.fst.
# Ed's workspaces have little memory and disk. VM_PARALLEL_BUILDS=0 compiles each bench's C++ as one file, with no
# precompiled headers (those alone would be about 190 MB of disk). That file stays small because the camera model
# keeps its two big tables out of line (no_inline_task in tb/ov7670_model.sv), and at -O1 the compiler needs about
# 350 MB in our tests.
set -e
export LC_ALL=C
what="${1:-all}"; wave="${2:-}"
FPS="${FPS:-50}"                                # the configuration bench's frame rate: 50, or FPS=25 ./simulate.sh config
RAN=""                                          # the logs of the benches this run, for the summary at the end
RTL="rtl/camera_pkg.sv rtl/clock_divider.sv rtl/i2c_master.sv rtl/ov7670_config.sv rtl/ov7670_capture.sv rtl/frame_buffer.sv rtl/camera_display.sv rtl/video_pll.sv rtl/top_level.sv"
MODELS="tb/ov7670_model.sv tb/vga_monitor_model.sv tb/vga_sink_sim.sv"
run() {  # $1 = testbench module, $2 = sources, $3 = plusargs, $4 = more Verilator options
  rm -rf obj_dir *frame_*.ppm sim_$1.log
  RAN="$RAN sim_$1.log"
  verilator -Wall -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-PINCONNECTEMPTY --trace-fst --timing --assert \
    --top "$1" --cc tb/$1.sv $2 $4 --main --exe -o V$1 -CFLAGS -O1 > verilator_$1.log 2>&1 || { grep -E "%Error" verilator_$1.log | head; exit 1; }
  make -s -C obj_dir -f V$1.mk V$1 VM_PARALLEL_BUILDS=0 > /dev/null || { echo "The C++ compile of $1 failed (\"Killed\": out of memory; \"No space left on device\": out of disk)."; exit 1; }
  ./obj_dir/V$1 $3 | tee sim_$1.log | grep -vE "^\[OV7670|Verilog \\\$finish|stopped mid-frame" | grep -E "PASS|FAIL|frame|config\]|ok:" || true
}
[ "$wave" = wave ] && PLUS="+wave" || PLUS=""
case "$what" in
  all|config)  run ov7670_config_tb  "rtl/clock_divider.sv rtl/i2c_master.sv rtl/ov7670_config.sv tb/ov7670_model.sv" "$PLUS" "-DCAMERA_FPS=$FPS" ;;
esac
case "$what" in
  all|capture) run ov7670_capture_tb "rtl/ov7670_capture.sv tb/ov7670_model.sv" "$PLUS" ;;
esac
case "$what" in
  all|buffer)  run frame_buffer_tb   "rtl/frame_buffer.sv" "$PLUS" ;;
esac
case "$what" in
  all|display) rm -f display_frame_*.png
               run camera_display_tb "rtl/camera_pkg.sv rtl/frame_buffer.sv rtl/camera_display.sv tb/vga_monitor_model.sv" "$PLUS"
               python3 tools/render_frames.py > /dev/null; rm -f *frame_*.ppm ;;
esac
case "$what" in
  all|system)  rm -f frame_*.png camera.gif
               run camera_system_tb  "$RTL $MODELS" "$PLUS"
               python3 tools/render_frames.py > /dev/null; rm -f *frame_*.ppm
               python3 tools/make_gif.py camera.gif frame_*.png > /dev/null || true ;;
esac
case "$what" in
  all|barcode) LIVE="rtl/live/hdiff.sv rtl/live/col_profile.sv rtl/live/pick_runs.sv rtl/live/bar_decode.sv rtl/live/cdc_latch.sv rtl/live/hex_glyph.sv rtl/live/live_reader.sv rtl/live/camera_barcode_display.sv"
               rm -f barcode_frame_*.png barcode.gif
               run camera_barcode_tb  "rtl/camera_pkg.sv rtl/ov7670_capture.sv rtl/frame_buffer.sv $LIVE tb/ov7670_model.sv tb/vga_monitor_model.sv" "$PLUS"
               python3 tools/render_frames.py > /dev/null; rm -f *frame_*.ppm
               python3 tools/make_gif.py barcode.gif barcode_frame_*.png > /dev/null || true ;;
esac
case "$what" in
  handover)    run frame_buffer_handover_tb "rtl/camera_pkg.sv rtl/frame_buffer.sv rtl/camera_display.sv" "$PLUS" ;;
esac
[ -n "$RAN" ] || { echo "usage: ./simulate.sh [all|config|capture|buffer|display|system|barcode|handover] [wave]"; exit 1; }
grep -h "PASS\|FAILED" $RAN
for f in $RAN; do grep -q "^PASS" "$f" || exit 1; done    # the exit status: 0 only if every bench passed
