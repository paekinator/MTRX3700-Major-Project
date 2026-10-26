# AI assistance statement draft

Owner: MTRX3700 ECHO-7 team. Prepared with OpenAI Codex; human review pending.

The team authorized AI-assisted implementation of Phase 1 after reviewing the display-domain
architecture, SW[2:1] selection, SW0 reservation, mask encoding and frame-boundary control updates.
Codex generated the five new RTL modules, four testbench files, a reference package, a test runner,
an independent Python mathematical checker, and the limited integration edits listed in OWNERS.md.

Implementation choices to review: Fixed thresholds 160/100/100; Ratio 3:2 with minimum 80;
HSV integer rational comparisons with S>=96/255, V>=80, hue limits 85/1451 and 853/1109;
three classification pipeline stages plus one overlay register; 10 ms stable switch qualification.
These calibration values are initial engineering choices, not measured camera performance.

Validation must distinguish three separate levels:
1. Python exhaustive mathematical checks are not RTL simulation.
2. Quartus synthesis, fitting and timing analysis are not functional or board validation.
3. At the original Phase 1 delivery, the self-checking SystemVerilog tests required an existing working simulator. Verilator was
   not found in this environment, and the installed ModelSim tools failed to start with a DLL
   relocation error inside the sandbox. No RTL simulation PASS was claimed in that earlier delivery.

The team must review the code, run the testbenches using the course's Verilator 5.050 environment,
inspect timing reports, calibrate with real red/blue objects and record board observations.
The exact assignment rubric was not supplied, so this draft is not a claim of academic compliance.
No software was installed, no Git commit/push was made, and no board was programmed by Codex.

Phase 1.5 update (2026-10-22): the team authorized direct edits in ECHOPHACE1, without a new
backup. Codex added aggregate per-colour boxes, detected-pixel mean RGB and mean-RGB-to-HSV,
a shared iterative divider, a font/renderer, a frame-boundary barrier and aligned statistics
snapshots. Six benches and an independent diagnostics reference package were added.
ModelSim 10.5b was confirmed to work outside the sandbox with user approval; actual tests
and Quartus results are recorded in `work/phase15/verification.json`. Verilator 5.050 and
real-board validation remain outstanding. The first text-reference failure came from
ModelSim's decimal space padding and was corrected using explicit decimal characters.
`ECHO7_PHASE15.md` lists design choices and remaining risks. Human ownership and engineering
review are still required; simulation or synthesis does not establish course compliance.

Fixed ROI calibration update (2026-10-23): Codex implemented the user-approved
200x160 fixed display ROI and SW4 mode selection. Engineering choices for human
review: a central 20x20 display-pixel mean sample, a configurable 32-pixel combined
red/blue detection threshold, prior-frame measurements, and dashes while no matching
complete frame is available. Dynamic diagnostics remain a separate parallel path;
both paths accept identical stream transactions. The subsequent ROI Mask update
uses SW3 to apply colouring only inside the fixed ROI, retaining original pixels
for all measurement calculations. New RTL and tests
are AI-assisted, with source attribution comments. No camera configuration or capture
changes, installation, Git operations or board programming were performed.
ModelSim/Quartus execution and limitations are recorded in
`work/roi_calibration/verification.json`; human review remains pending.

ROI Mask update (2026-10-23): at the user's request, Codex connected the existing
frame-qualified overlay control to roiCalibration and added ROI-limited red/blue
pixel replacement before border/text rendering. No filtering, threshold changes,
additional pipeline stages or camera changes were introduced. Tests now exercise
SW3 off/on with each algorithm, non-primary target colours, all four ROI edges,
unchanged original-pixel means and randomized backpressure. Execution results for
this update are recorded separately in work/roi_mask/verification.json.

CCW rotation update (2026-10-23): at explicit user authorization, Codex added an
optional inverse coordinate mapping to camera_display, enabled it in top_level,
and added an independent full-frame integration reference test. The 320x240 buffer
is viewed counterclockwise as 240x320, nearest-neighbour scaled to 360x480 and
centered at x=140..499. Downstream ROI, masks and statistics use display coordinates.
No camera configuration or capture logic changes were made; MVFP stays 0x07.
The initial test fixture incorrectly selected DECIMATE=1, unsupported by the existing
framebuffer implementation; the fixture was corrected to the board's DECIMATE=2.
Actual validation is recorded in work/rotation/verification.json, not inferred from
the test's existence. Physical board validation remains the team's responsibility.

Emergency-stop update (2026-10-23): ECHO-7 team-owned, AI-assisted safety RTL in
rtl/safety and self-checking benches in tb/safety. Original supplied reference
sources are preserved under rtl/safety/reference with provenance and hashes in
work/safety/reference_sources.json. necDecoderSafe adds deterministic reset to
the supplied decoder. safeChassisCommand preserves the T:1 JSON protocol and
adds priority zero-speed frames; an in-flight line is completed, including on KEY0.
Top-level safety wiring, IR/HEX constraints, sonar CDC constraints, camera test
idle inputs, and test source lists were integrated. Camera/ROI/HSV/rotation RTL,
OV7670 configuration/capture and existing uart_tx were not changed.
POWER is unverified: the default programmable image inhibits movement and shows
received key codes. Synthetic A5 is used only in tests; hardware review and a new
compile with the measured POWER code are required before motion testing.
The watchdog monitors accepted control updates, not UART receipt or link health.
Ultrasonic Safety DISABLED; real measurements remain available. Software results,
initial failed attempts, timing limits and board test steps are recorded in
work/safety/report.txt and work/safety/verification.json. Student review pending.
