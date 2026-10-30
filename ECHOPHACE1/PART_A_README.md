# ECHO-7 Part A front end, EPA2

Open `quartus/PartAPipeline.qpf` for the camera-only Part A project. It processes
native 320x240 RGB565 pixels and records 78 result words with the same frame.
The original `Camera.qpf` project retains its legacy threshold defaults. This
Part A top selects calibrated ratio minima R64/B32, with dominance ratio 3/2.
The matching parameters also drive its VGA selector, and word77 records them.

The camera setting is 25 FPS, nominal 20 MHz PCLK with a 50 ns constraint.
Elaboration guards reject other FPS values or ratio parameters outside the
packet-byte ranges. Physical clock frequency requires measurement if claimed
as a measured target. Failed earlier timing attempts are retained in reports.

## Processing and coordinates

RGB565 -> existing fixed/ratio/HSV selector -> raw colour centroid and, in
parallel, causal cleanup -> exact bounded four-connected components. All new
processing runs in camera PCLK. The supplied framebuffer crosses into the VGA
clock domain. Recorded coordinates are unrotated x0..319/y0..239; VGA rotates
and scales them, so the two coordinate systems are different.

Raw centroids use floor(sum/area) over every pixel of each colour. Cleanup keeps
a pixel if its RAW left or upper neighbour has the same colour. A rectangle
loses its first corner pixel. Candidate area counts cleaned pixels; candidate
centres use floor((minimum+maximum)/2), a bounding-box midpoint.

EPA2 reclaims labels only after each row. It canonicalizes all320 stored label
references before freeing merged aliases, retires components absent from the
new row, applies MIN_AREA32, and stores up to8 completed candidates per colour.
CAP8 separately limits active handles, including aliases within the current
row. Either active-handle or completed-output overflow invalidates the whole
candidate frame. These limits remain explicit; invalid candidates are not used.

The row housekeeping interval requires W+CAP=328 idle clocks. Publication is
W+CAP+1=329 clocks after normal EOP. Early input is a flagged overrun. The full
sensor integration bench proves the skipped odd raw row alone is sufficient:
1283 interrow idle clocks with two PCLKs per RGB565 raw pixel, no added blanking.
It also checks the final packet before the next frame boundary. Frame IDs count
accepted SOPs modulo65536; zero after wrap is legal.

## Recorded interface and controls

`packet_schema.json` specifies EPA2, schema2, N_RESULTS78. Words2..76 retain the
EPA1 field positions; appended word77 packs R minimum, B minimum, numerator and
denominator as four bytes. Defaults64,32,3,2 encode0x40200302.

Word5 bit0 proves frame association; bit7 gives candidate-frame validity.
Counts, colour validity and Member B geometry/identity checks are still needed.
Results are held at camera frame_start; the supplied snapshot copies that
packet at the next raw pixel. Consume the interface in PCLK or add a tested
held-payload handshake for another consumer clock domain.

SW2:SW1 selects fixed00, ratio01, HSV10 or fixed fallback11. Ratio01 is the
calibrated pilot mode. SW3 controls VGA mask display and SW4 the ROI calibration
view; native processing always covers the complete native frame. KEY0 resets,
KEY1 snapshots. The VGA aggregate boxes are separate from the new measured
candidate boxes saved by the checker. All noncamera GPIO outputs are disabled.

## Tests and replay

On Linux/Ed with standard Verilator5.050, make, C++ and Python NumPy/Pillow:

    bash run_part_a_tests.sh

The runner uses fresh build directories, Python oracle/checker tests, module
and front-end benches, and a temporary deliberately incorrect cx+1 candidate
implementation that must be CAUGHT. Its overall deadline is300seconds. Actual
Windows execution uses the isolated CMake/Zig runtime recorded with the delivered
logs. The portable Linux/Ed route needs its own execution record; this Part A
suite does not certify the whole robot's R6 tests.

For a recorded frame after programming the matching image:

    quartus_stp -t tcl/grab_jtag.tcl captures/trial_001 --mvfp 0x07
    python tools/grab.py --file captures/trial_001/dump.bin --out captures/trial_001 --mvfp 0x07
    python tools/part_a/check_hardware_packet.py captures/trial_001

The checker reads and checks the binary CRC directly, recomputes classification,
cleanup and an independent BFS component model, and compares every valid measured
descriptor. EPA2 candidates compare as an unordered set because retirement order
can differ from first-seed order. It also saves measured-candidates.png.

EPA1/77-word legacy captures remain supported with their original lifetime-label
and R80/B80 semantics. Five-word course example captures are rejected as Part A
proof. A numerical replay PASS for an overflow frame means agreement about the
failure; it does not prove successful detection. Positive physical trials and
repeatability results are recorded separately from source and simulation evidence.

Code is AI-assisted. Human name/SID review is pending in OWNERS.md. Original
course camera, VGA and FrameGrab notices remain applicable.
