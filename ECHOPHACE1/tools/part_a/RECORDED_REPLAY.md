# Part A recorded-input replay

Human owner: Member A (name/SID and review pending). AI-assisted by OpenAI Codex.

This test feeds **real recorded RGB565 inputs** through the EPA2 RTL in simulation.
Its expected EPA2 packets are independent software predictions. It does **not**
measure V2 FPGA outputs or replace a new board capture after programming V2.

From the `ECHOPHACE1` directory, use Python 3 with NumPy and Pillow. Every input
folder must contain the original `dump.bin` and its matching `frame.hex`.
Choose a fresh output directory and specify one mode for each folder:

```sh
python3 tools/part_a/export_recorded_replay.py \
  --out work/recorded_vectors_001 --red-min 64 --blue-min 32 \
  --captures /path/to/background /path/to/red /path/to/blue /path/to/paired \
  --modes 0 1 1 1
```

Mode `0` is Fixed, `1` Ratio, `2` HSV and `3` the selector's Fixed fallback.
Modes are deliberate replay inputs. The exporter ignores the old snapshot result
words when calculating new expected values, including old mode and thresholds.
It checks the GRAB transport header, exact length, CRC, 320x240 RGB565 geometry
and equality of `frame.hex` to the CRC-checked pixels. A bad input exits nonzero
before creating the output folder.

The exporter writes `frames.hex`, `modes.hex`, `expected.hex` and `metadata.json`.
The metadata records every input hash, mode, software model hash and the label
`PREDICTED EPA2 for recorded inputs; NOT measured V2 hardware outputs`.

With the course Linux/Ed Verilator 5.050 toolchain, build the replay bench once:

```sh
verilator --binary --timing --assert -Wno-fatal -j 4 \
  --top-module partARecordedReplay_tb \
  --Mdir work/recorded_replay_build -o "$PWD/work/recorded_replay_sim" \
  rtl/camera_pkg.sv \
  rtl/echo7/rgbFixedSeg.sv rtl/echo7/rgbRatioSeg.sv rtl/echo7/hsvSeg.sv \
  rtl/echo7/unsignedDivider.sv rtl/echo7/segmentationSelector.sv \
  rtl/part_a/part_a_pkg.sv rtl/part_a/rawColourCentroid.sv \
  rtl/part_a/causalMaskCleanup.sv rtl/part_a/boundedCandidates.sv \
  rtl/part_a/partACapturePipeline.sv \
  tb/part_a/partARecordedReplay_tb.sv
./work/recorded_replay_sim +VECTORS="$PWD/work/recorded_vectors_001" +CASES=4
```

Use the actual number of exported captures for `+CASES`; the bench supports 1 to
16 without rebuilding. The build above uses the frozen R64/B32 ratio profile.
If intentionally exporting another profile, build with matching
`-GRATIO_RED_MIN_VALUE=... -GRATIO_BLUE_MIN_VALUE=...`; otherwise the metadata word
comparison must fail.

Require exit status zero **and** the final `PASS partARecordedReplay:` line, with
every sample passing. The bench compares all public packet metadata and raw
centroids exactly, and valid candidate descriptors as unordered multisets. It
drives complete 640x480 sensor streams at two PCLK cycles per RGB565 pixel,
including discarded odd rows/pixels, without adding horizontal/vertical blanking.
It also checks that row housekeeping and final publication fit the available
sensor cadence. Invalid candidate-slot diagnostic fields are unspecified.

For a new held-out board capture, export all desired folders into a new vector
directory, update `+CASES`, and rerun the same binary while the profile is unchanged.
Keep the original captured result words as separate physical hardware evidence;
these prediction vectors never replace them.
