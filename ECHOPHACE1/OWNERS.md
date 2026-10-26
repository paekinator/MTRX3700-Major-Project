# ECHO-7 Phase 1 / 1.5 ownership record

Project: MTRX3700 ECHO-7. Responsible human team: ECHO-7 project team.
Named student owners/reviewers: pending team entry. No human review or authorship is implied by this file.

| Files | Responsibility and origin |
|---|---|
| `rtl/echo7/*.sv` | New AI-assisted implementation by OpenAI Codex at the team's request; human engineering review pending |
| `tb/echo7/*.sv` | AI-assisted self-checking testbenches and reference packages; Phase 1.5 execution is recorded in `work/phase15/verification.json` |
| `tools/echo7/*.py` | New AI-assisted standard-library-only test runner and mathematical checks |
| `rtl/top_level.sv` | Existing course/project source, with AI-assisted SW port and selector/diagnostics/overlay wiring additions |
| `quartus/Camera.qsf`, `quartus/Camera.sdc` | Existing course/project constraints, with AI-assisted source list, SW pins and asynchronous SW timing exception additions |
| `simulate.sh`, `tb/camera_system_tb.sv` | Existing course test infrastructure; updated source list and explicit SW=0 regression connection only |
| `OWNERS.md`, `AI_STATEMENT.md`, `ECHO7_PHASE1.md` | AI-assisted records for human review; not a certification of course compliance |

Original camera, framebuffer, display, IP, and other course authorship/license notices remain applicable.
OV7670 configuration/capture, camera_pkg, frame_buffer, UART and robot control sources were not edited.
The subsequent rotation update adds an optional display-coordinate mapping to camera_display.

Phase 1.5 adds seven RTL files (diagnostic package, region statistics, divider, mean/HSV,
font, renderer, and diagnostics wrapper), six self-checking benches, and a reference package.
The selector adds a frame-qualified mode output. The test runner adds an existing-ModelSim
backend; no simulator was installed. `ECHO7_PHASE15.md` documents the implementation,
one-frame latency, aggregate-target limitation, validation and human hardware checks.
All additions are team-owned AI-assisted work by OpenAI Codex; named student review is pending.

Fixed ROI calibration update (2026-10-23): `roiCalibration.sv`,
`roiCalibrationRenderer.sv`, `videoDiagnostics.sv` and two ROI self-checking benches
are team-owned, AI-assisted additions by OpenAI Codex. Selector control width,
font glyphs, top-level wiring, SW4 constraints and test source lists were updated.
Student engineering review and physical DE1-SoC validation remain required.
Actual execution records are in `work/roi_calibration/verification.json`.

ROI Mask update: AI-assisted edits to roiCalibration.sv, videoDiagnostics.sv and
the two ROI testbenches add SW3-controlled masking inside the fixed ROI. Ownership
remains with the ECHO-7 team; human review pending. See work/roi_mask/verification.json.

CCW rotation update (2026-10-23): AI-assisted optional 90-degree counterclockwise
read-coordinate mapping and black side bars in rtl/camera_display.sv; enabled in
rtl/top_level.sv. Added tb/echo7/rotation_tb.sv and a test-runner entry. No camera
register changes. Existing unrotated mode remains the default for legacy instances.
See work/rotation/verification.json; student review and board validation are pending.

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
