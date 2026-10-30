# Part A handoff to Part B

Prepared 31 October 2026. Tested camera/front-end checkpoint: 30 October 2026.
Branch: `codex/echo7-part-a`. Human student/SID ownership and design review remain
pending; the implementation and verification are AI-assisted by OpenAI Codex.

The source in this branch provides camera configuration, colour segmentation,
causal cleanup, raw colour centroids and bounded component candidates. Part B
adds marker pairing/geometry, identity, decoy rejection and target selection.
No CNN or motion controller is implemented by the camera-only Part A top.

## What to get from Git

- Editable project: `../quartus/PartAPipeline.qpf` (Quartus 18.1).
- Top: `../rtl/part_a/top_level_part_a.sv`, module `top_level`.
- Front-end interface: `../rtl/part_a/partACapturePipeline.sv`.
- Complete packet specification: `../packet_schema.json`.
- Front-end explanation and tests: `../PART_A_README.md`.
- Measured physical results: [PHYSICAL-RESULTS.txt](PHYSICAL-RESULTS.txt).
- Frozen tested image, source copy, captures and all evidence:
  [ECHO7-PartA-bundle.zip](ECHO7-PartA-bundle.zip). Verify against
  [checksums.sha256](checksums.sha256), then extract it.

The archive is the immutable 30 October snapshot. Its internal notes saying
"not committed/pushed" describe its creation time. Use this Git branch for the
shared source. Its `part-a.patch` is already represented here; do not apply it
again to this branch.

Inside the extracted archive, use:

- `ECHO7-PartA/pipeline-v2/quartus/output_files/PartAPipeline.sof` to restore the
  tested image. SHA256:
  `5a4358722dbd798e7c8cc2eccb41a3147377872409e60c86d1bbf2ced337a8d5`.
- `ECHO7-PartA/INTEGRATION-HANDOFF.txt` for detailed clock, packet and consumer
  rules. Its absolute paths identify the original machine; equivalent paths in
  this checkout/archive should be used on another PC.
- `ECHO7-PartA/captures/` and `validation/` for measured packets, images,
  independent checks and final 17-input recorded replay.

The older tracked `Camera.sof` is not this tested EPA2 image. Use the exact
`PartAPipeline.sof` above for the handoff baseline.

## Physical kit transfer

If the team shares one kit, transfer the DE1-SoC, its power supply, OV7670 camera
with its current adaptor/loom, USB-Blaster cable and the size-checked paired
marker plus red/blue tiles. Provide the VGA lead/monitor or arrange access to
one. Photograph the working connector arrangement before moving the kit. Power
off before disconnecting or reconnecting the camera/adaptor.

The editable project is on the PC/Git, not recoverable as source from the FPGA.
The current `.sof` was loaded into volatile configuration; power-off clears it.
On the teammate's PC, install/use Quartus and the USB-Blaster driver, open
Programmer, select the DE-SoC USB-Blaster, and program the FPGA (ID 0x02D120DD,
device 2 in the tested chain, not the HPS) with the exact SOF above. No flash programming is
needed. After camera configuration, use SW4 ON, SW3 OFF, SW2 OFF, SW1 ON for the
calibrated ratio view. KEY0 resets; KEY1 requests a snapshot.

First reproduce the live image and paired marker in this known image before
debugging a new combined build. The camera-only image has all 20 noncamera GPIO
output enables disabled and cannot drive the chassis.

## How Part B builds on Part A

On a clean checkout, fetch and select `codex/echo7-part-a`, then create a Part B
development branch from it. Preserve any existing Part B work and bring it into
the integration branch deliberately. The submitted robot will run A, B and C
together on the same FPGA; handover is a transfer of kit access and a software
checkpoint, not a replacement of A by an unrelated standalone B image.

The current top connects `part_a_u.snapshot_results` to the held bus `stats`.
Part B can consume that bus directly in the FPGA; JTAG/laptop capture is only
for logging and verification. The bus contains 78 x 32 bits (EPA2/schema2), with
word0 most significant. A packet describes the just-ended native 320x240 frame.
It updates at `frame_start` in camera PCLK; another PCLK block must consume it
after that update, e.g. on a one-cycle-delayed strobe. Use a tested atomic
transfer if Part B runs on a different clock.

Require same-frame association and candidate-frame validity, then use counts
and slot valid bits. Candidate order is not target identity. Either capacity
overflow invalidates the whole candidate frame; zero valid counts can also
mean a valid empty scene, so check flags. Frame ID zero is legal after wrap.
Coordinates are native/unrotated; VGA rotates/scales the image. The VGA boxes
aggregate colours and do not show individual EPA2 candidates.

Part B should produce a defined selected-target interface for Part C: at least
validity, frame ID and native target coordinates, with agreed geometry/identity
fields. Define loss, stale data and reacquisition behaviour. Agree any need for
CNN image/ROI inputs before collecting training data; the candidate packet is
not a CNN image tensor.

Create a combined top/project that retains the tested front end, then recompile
and recheck timing/CDC and behaviour. Add targeted tests for the new consumer
and regression checks for A. Part C connects selected targets and the raw
centroid baseline to the same controller, with its agreed bypass and safety.

Member A can continue code review, simulation and captured-data analysis without
the board. New physical calibration/robustness trials need scheduled access to
the camera and FPGA.

## Confidence and remaining work

The fixed three-frame marker batch, separated red and blue tiles, blank scene
and correct active/completed overflow rejection were measured on hardware.
All measured EPA2 field comparisons match the independent model. Final recorded
RTL replay passes 265 checks on 17 inputs, including expected invalid frames
and an unsuccessful fixture attempt. Full-sensor integration and deliberate
cx+1 error detection pass; all 64 reported Quartus timing checks pass.

This is one indoor setup, not full robustness or robot acceptance. Hands can
become red candidates and underlit targets can be missed. Measured distance,
lighting/viewpoint coverage, marker identity, combined control and complete
robot tests remain. The native Windows fresh Part A suite took 197.359 seconds;
the course Linux/Ed route and full team's `run_all_tests.sh` still need their
own execution records. See `../OWNERS.md` for ownership/origin requirements.
