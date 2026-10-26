`timescale 1ns/1ps
/* verilator lint_off PROCASSINIT */
/* verilator lint_off IMPLICITSTATIC */
/* verilator lint_off WIDTHTRUNC */
/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNUSEDPARAM */
/* verilator lint_off BLKSEQ */
/* verilator lint_off MULTIDRIVEN */
/* verilator lint_off SYNCASYNCNET */
/* verilator lint_off REALCVT */
/* verilator lint_off UNSIGNED */
/* verilator lint_off ZERODLY */
// (This file is a simulation model. It is never synthesised, so the lint rules
//  that matter for synthesisable code are relaxed to keep your terminal clean.)
/*
 * ============================================================================
 *  ov7670_model.sv  --  Behavioural simulation model of the OV7670 camera
 * ============================================================================
 *
 *  WHAT IS THIS?
 *  -------------
 *  The OV7670 on the robot is a chip on the far end of a ribbon cable. Your
 *  FPGA can talk to it (the SCCB control bus) and watch it (the 8-bit video
 *  port), but it cannot see *inside* it: whether the register write landed,
 *  what output format the chip thinks it is in, why the picture is green, why
 *  the first column is missing. This model can. It is the datasheet written
 *  down so that a machine can check your design against it:
 *
 *      your camera code  ==SIO_C/SIO_D==>  [ the camera's SCCB + 256 registers ]
 *                        <=PCLK/VSYNC/HREF/D[7:0]==  [ timing generator + scene ]
 *
 *    - Every SCCB transaction is decoded the way the chip decodes it, and
 *      every write is printed in words from Table 5, whatever the register
 *      ("WRITE COM7 (0x12) <= 0x04: VGA, RGB output (bit 2), colour bar overlay
 *      off (bit 1)").
 *    - The registers have the datasheet's reset values, COM7[7] resets them,
 *      PID/VER read back 0x76/0x73, reserved registers are stored and named.
 *    - Once the chip is out of reset and XCLK is running, it produces the
 *      PCLK / VSYNC / HREF / D[7:0] stream with the timing of Figure 6 (VGA
 *      frame timing) and the byte packing of Figures 11-13 (RGB565/555/444)
 *      or the YUV 4:2:2 orders of TSLB[3]/COM13[0], for whatever the registers
 *      currently say: PLL and prescaler (PCLK rate and frame rate), window
 *      (HSTART/HSTOP/VSTRT/VSTOP), mirror/flip (MVFP), test patterns,
 *      QVGA/CIF/QCIF (COM7[5:3]), PCLK divider (COM14), polarities (COM10),
 *      soft sleep (COM2[4]), and the simple picture controls: brightness,
 *      contrast, negative image and fixed U/V. A change to the gamma curve,
 *      the colour matrix or the fixed gains is shown as an estimate (see
 *      FIDELITY).
 *    - What the camera *sees* comes from the testbench: a picture file, or one
 *      of the built-in scenes (colour bars, shapes, a chequerboard, a barcode)
 *      that the testbench can pan across the sensor to make things move.
 *
 *  The model is written from the OV7670/OV7171 datasheet, version 1.4 (2006),
 *  the one attached to the Ed lesson:
 *    - pins and their meaning:          Table 1, p.4
 *    - XCLK, reset settling, SCCB and video-port timing limits: Table 4, p.6
 *    - VGA frame timing (3/17/480/10 lines, 784 tP per line, 640 tP of HREF,
 *      tP = 2 tPCLK for YUV/RGB and 1 tPCLK for raw): Figure 6, p.7
 *    - QVGA / QQVGA / CIF / QCIF line subsampling: Figures 7-10, p.8
 *    - byte packing of RGB565 / RGB555 / RGB444: Figures 11-13, p.9-10
 *    - every register, its default and what its bits do: Table 5, p.11-26
 *    - SCCB addresses 0x42 (write) / 0x43 (read): p.11
 *  Board-level facts: the Robot Adaptor Board wires the module to GPIO_1[10..25]
 *  (the camera project's rtl/top_level.sv lists which pin is which), SIO_C and SIO_D need pull-ups
 *  (the adaptor's, and the FPGA's weak pull-ups that the course's .qsf turns on),
 *  and the camera's XCLK comes from the FPGA (10 MHz from the video PLL, which
 *  the sensor's own PLL multiplies by 4 for a 40 MHz PCLK, with CLKRC bit 7
 *  left set: see "Measured").
 *
 *  FIDELITY (what is and is not modelled)
 *  ---------------------------------------
 *  Modelled:   SCCB 3-phase write, 2-phase write + 2-phase read, address
 *              check, the "don't care" 9th bit (the chip does pull it low),
 *              400 kHz limit, the 1 ms settling time after any reset (writes
 *              that arrive earlier are DROPPED and reported, as a real chip
 *              can lose them and end up half configured), XCLK must
 *              be running, PWDN and RESET# pins; the full register file with
 *              Table 5 defaults, COM7[7] soft reset, read-only registers;
 *              the PCLK (the rule under "Measured") [/ COM14 divider], VGA
 *              frame timing to the PCLK, the output window registers, dummy
 *              pixels (EXHCH/EXHCL) and dummy lines (ADVFH/ADVFL and
 *              DM_LNH/DM_LNL), which slow the frame rate, soft sleep (COM2[4]:
 *              the video port stops, the SCCB still works); 2 bytes per pixel
 *              with the datasheet's bit assignment for RGB565/555/444 and the
 *              four YUV orders, raw Bayer (1 byte per pixel), output range
 *              (COM15[7:6]), QVGA/CIF/QCIF and DCW down-sampling, COM10
 *              polarity, HSYNC and PCLK-gating options, tPDV/tPHL output
 *              delays; the picture: mirror and flip (MVFP), pixel delay
 *              (PSHFT), negative image (TSLB[5]), contrast and brightness
 *              (CONTRAS, BRIGHT, CONTRAS-CENTER, MTXS[7]), fixed U/V (TSLB[4]
 *              with MANU and MANV), and the test patterns (COM7[1], COM17[3],
 *              SCALING_XSC[7] and SCALING_YSC[7]).
 *  Measured:   On a DE1-SoC with an OV7670, XCLK 10 MHz, on 18 October 2026,
 *              where the datasheet is silent or the model had guessed. The
 *              model follows these numbers:
 *              - The clock. PCLK = XCLK / P x PLL / H, with PLL 1 (bypassed),
 *                4, 6 or 8 (DBLV[7:6]); P = 1 with CLKRC[6] set, else
 *                CLKRC[5:0] + 1; H = 2 only when CLKRC[7] and CLKRC[6] are
 *                both clear, else 1. Table 5 calls bit 7 reserved (it is set
 *                after a reset) and does not mention the halving. Measured
 *                (DBLV, CLKRC: PCLK): 0A,80: 10.000 MHz; 0A,00: 5.00; 0A,40
 *                and 0A,C0: 10.006; 4A,00: 20.000; 4A,80 (the course's),
 *                4A,40, 4A,C0, 4A,41 and 4A,C1: 40.000; 4A,01: 10.0; 4A,02:
 *                6.667; 4A,81: 20.000; 4A,82: 13.333; 8A,00: 30.000; CA,01:
 *                20.000; CA,02: 13.333; CA,00: about 41.5, wandering. The PLL
 *                comes after the prescaler and did not lock at 80 MHz (x8
 *                from 10 MHz: PCLK wandered 1 to 5 % fast) where 60 and 40
 *                MHz were exact; the model's PCLK is always exact, and its
 *                printout says when the PLL makes more than 60 MHz.
 *              - The frame: 799,680 PCLKs, 1,568 a line, 480 lines of 1,280
 *                bytes for the course's list; VSYNC 3 lines.
 *              - HREF rises 2 x HSTART PCLKs into the line (VGA; plus
 *                HREF[2:0]), and a window that runs past the line's end goes
 *                on into the next line: the course's HREF runs from PCLK 320
 *                to PCLK 31 of the next line. No HREF from 207 to 273 PCLKs
 *                into a line: a window's bytes that fall there are lost (a
 *                window from HSTART 136 sends 639 pixels), and the first
 *                pixels after the gap, up to 286, are white. On the window's
 *                first line HREF starts no earlier than PCLK 139.
 *              - The window is placed on the readout after the mirror and the
 *                flip, so a larger HSTART or VSTRT moves the picture left or
 *                up, mirrored or not. Readout rows 2 to 9 are not picture
 *                (black, black, dark red, light green), row 10 is dark blue
 *                (so the course's window starts at row 11, VREF 0x0F: with
 *                0x0A, the Linux driver's, the top row is a dark blue line;
 *                from row 11 it is picture), and the readout ends at row 495:
 *                rows 18..498 send 478 lines. (Measured with the course's
 *                mirror and flip on, every second row.)
 *              - COM7's scaled modes divide PCLK themselves (QVGA and CIF by
 *                2, QCIF by 4; COM14[4] set uses COM14's divider instead), so
 *                a line stays 1,568 PCLKs and the frame rate 50 fps. Through
 *                the course's window (measured from row 10, VREF 0x0A; the
 *                model keeps the same lines of the window from row 11): QVGA
 *                320 x 240 (every second line, from the second), CIF 320 x
 *                290 and QCIF 159 x 145 (290 of 480 lines, QCIF of the line
 *                pairs: which ones fitted to the board's first 64 rows), HREF
 *                a PCLK later (QVGA, CIF) or three (QCIF).
 *              - Dummy pixels come out inside HREF at the end of each line;
 *                ADVF's dummy lines lengthen VSYNC at the frame's start;
 *                DM_LN's come between VSYNC and the first line.
 *              - The test patterns: SCALING_YSC[7] alone gives 8 bars (white,
 *                yellow, cyan, green, magenta, red, blue, black; 654 pixels
 *                for the eight, from 23 pixels before the course's window's
 *                first column, so a white sliver shows at the right edge), in
 *                the colours in bar_colour(); COM17[3] the same bars in the
 *                DSP's duller colours, which brightness, contrast, the
 *                negative and fixed U/V change; both SCALING bits fade the
 *                bars towards a light grey (166, 205, 206) down the frame,
 *                starting again every 376 rows; SCALING_XSC[7] alone, the
 *                shifting 1, holds each pin for two bytes: 01 02 02 04 04 ...
 *                80 80 01 01 ... None of them is mirrored or flipped. COM7[1]
 *                is not a test pattern but an overlay on the picture: in 8
 *                bars of 80 pixels, turned round with the picture, a channel
 *                in the bar's colour becomes about 0.71 x + 69 (R), 0.73 x +
 *                61 (G) or 0.57 x + 91 (B), and the others about 0.87 x - 7,
 *                0.87 x - 11 and 0.79 x - 7.
 *              - Fixed U/V in RGB output: R becomes MANV and B MANU, exactly,
 *                and G is kept.
 *              - With AWB off (COM8[1] = 0), GGAIN is a green gain: 0x40 is
 *                x1, 0x80 x2, 0x00 none (an estimated stage, as BLUE and RED).
 *              - Contrast: CONTRAS / 64 exactly; with MTXS[7] set (the
 *                course's list sets it) the centre is the picture's own mean
 *                luma, not 128 (measured 109 to 118 for a picture whose mean
 *                was 105; the model takes the last frame's mean, over 40 x 30
 *                of its pixels: which frame the chip uses was not measured).
 *                The negative comes after brightness and
 *                contrast: BRIGHT +48 with the negative gives 207 - Y.
 *              - A register written during a frame takes effect from the line
 *                after the write, mirror and flip included; the model applies
 *                it at the next line start, as the board did.
 *              - The automatic loops (not modelled): with exposure on, a
 *                brightness change shows in full on the next frame and is
 *                about half taken back after 12 frames, all but 1 or 2 levels
 *                after 32 (0.65 s); a white balance knocked over by writing
 *                BLUE and RED is put back before any frame shows it.
 *  Estimated:  gamma (COM13[7], SLOP, GAM1..GAM15), the colour matrix
 *              (MTX1..MTX6, their signs in MTXS[5:0], COM16[1]) and the gains
 *              Table 5 gives as multipliers: GFIX, REG74's digital gain
 *              (REG74[4] = 1), and BLUE and RED while automatic white balance
 *              is off (COM8[1] = 0). The scene is the picture the course's
 *              register list gives (the camera project's
 *              rtl/ov7670_config.sv), so these stages show only a CHANGE from
 *              that list's values (est_ref() below). Each scene colour is
 *              taken back to what the chip had before its matrix: Table 5's
 *              luma weights and the list's two matrix rows make a 3 x 3 that
 *              has an inverse, which gives the curved sensor colour (R', G',
 *              B') that the list turns into the scene colour. That goes back
 *              through the list's gamma curve (Table 5's default) to the
 *              light, through the gains (clipped at full scale), the new
 *              curve and the new matrix. So the matrix doubled (COM16[1])
 *              doubles the colour, and Table 5's default matrix, about half
 *              the list's, about halves it. A register the design does not
 *              write keeps its Table 5 default, as on the chip: a design that
 *              sends only the list's first 17 entries (TUNING = 0) gets Table
 *              5's matrix and about half the colour, and one that writes the
 *              list's values gets exactly the scene. The evidence: Table 5
 *              gives the gamma curve (an output at each of 15 fixed inputs,
 *              and the top slope, SLOP = (256 - GAM15) x 4/3, which is the
 *              slope x 64) and the GFIX and REG74 multipliers. The Linux
 *              ov7670 driver gives the matrix's order (v-red, v-green,
 *              v-blue, u-red, u-green, u-blue: 9-bit signed, the signs in
 *              MTXS), and Table 5's default matrix, +64 -52 -12 / -23 -41
 *              +64, is the BT.601 colour-difference matrix x 128 to within 2,
 *              so 128 is x1. The driver's matrix for RGB output is its YUV
 *              one x 1.40 (first row) and about x 1.78 (second), the factors
 *              that turn V and U into R - Y and B - Y. So in RGB output the
 *              model takes the two rows as R - Y and B - Y, with G keeping
 *              the luma Y; in YUV output as V and U. On a board (18 October)
 *              the estimates held: predicted from the board's own picture,
 *              gamma off, the Linux driver's curve, Table 5's matrix (half
 *              the colour, as here), the matrix doubled, the driver's RGB
 *              matrix, a hue turned 30 degrees, GFIX, REG74's x2 and x4, and
 *              BLUE and RED came within 2 to 8 levels of the board, for
 *              changes of 6 to 108. Where the colour rises, the model's rises
 *              5 to 15 % more than the chip's (perhaps COM13[6], the UV
 *              saturation auto-adjust, which the model leaves out). The
 *              printout still says "estimated" for these registers.
 *  NOT modelled: anything optical or analogue: exposure (AEC), gain (AGC),
 *              automatic white balance, saturation, edge enhancement, de-noise,
 *              lens correction, black level, banding filter, night mode,
 *              strobe. Their registers are stored and described in the
 *              printout; the picture is the scene as given (plus optional
 *              random noise). Also not modelled: the scaling factors and their
 *              clock (SCALING_XSC/YSC[6:0], SCALING_PCLK_DIV, SCALING_PCLK_DELAY,
 *              COM3[3], COM14[3]: Table 5 gives no formula), CCIR656 (COM1[6]),
 *              the output MSB/LSB swap (COM3[6]: Table 5 does not say whether
 *              bits or bytes swap), tri-state in power-down (COM3[5:4]), output
 *              drive (COM2[1:0]), the HREF options (HREF[7:6], COM6[7],
 *              COM12[7]), the HSYNC edge delays (HSYST, HSYEN, EXHCH[3:0]) and
 *              the automatic window (TSLB[0]). SCCB electrical timing beyond
 *              the clock rate is not checked.
 *  The printout of a write says "not simulated" for what the model stores
 *  but ignores, and "estimated" for the stages above. For a reserved
 *  register it gives the Table 5 default and says whether the value is
 *  OmniVision's (the value the Linux ov7670 driver sends, which the course's
 *  register list copies). For a register with reserved bits it says which
 *  of them differ from the default.
 *
 *  Choices the datasheet leaves to us (the simplifications):
 *    - Test patterns: as measured (above). Choices: SCALING_XSC/YSC win over
 *      COM17[3]; nothing applies to their patterns; the measured colours are
 *      used in every output format; the bars sit on the readout, so moving the
 *      window moves them; expected_rgb() gives the colour the shifting 1's
 *      bytes mean in RGB565; in raw Bayer it holds each pin for two pixels.
 *      COM7[1]'s overlay comes after the estimated stages and before the
 *      picture controls, and the estimated stages do not apply to COM17[3]'s
 *      bars.
 *    - The rows above the picture are the measured colours in every output
 *      format, flip or not; rows 0 and 1 are black; rows 3, 5, 7 and 9 take
 *      the colour of the row above them (the board showed every second row).
 *      Columns and rows past the array's edge repeat its last ones.
 *    - The estimated stages come first. The scene colour is taken back
 *      through the course's matrix and curve (Estimated, above), then: the
 *      gains (on the light, before the curve, as the chip's fixed and
 *      white-balance gains act on the sensor's signal), gamma (each of R, G
 *      and B through the curve; Table 5's inputs are on a 0-255 scale and the
 *      model clips the light there), then the colour matrix (on the curved
 *      R', G', B'). The order, the curve acting on each of R, G and B, and
 *      the luma weights (BT.601) are our choices. GFIX's two green gains
 *      (Gr, Gb) become one, their mean. Raw Bayer gets the gains and the
 *      curve, not the matrix (each of its pixels has one colour). A test
 *      pattern gets none of them.
 *    - Then the picture controls, in this order (measured). Contrast and
 *      brightness act on the luma Y: Y' = centre + (Y - centre) x CONTRAS /
 *      64 + brightness, and R, G and B all move by Y' - Y, so colours keep
 *      their hue. CONTRAS 0x40 is x1. BRIGHT is a sign and a size, as the
 *      Linux driver writes it: bits 6:0 are 0 to 127 levels, bit 7 set makes
 *      it darker. The centre is CONTRAS-CENTER, or the picture's mean luma
 *      when MTXS[7] says the chip sets it itself (the course's list does).
 *      Then the negative: each colour becomes 255 minus itself. Then fixed
 *      U/V: in RGB output R is MANV and B is MANU (measured); in YUV output
 *      the U and V bytes are MANU and MANV exactly, and the model's RGB keeps
 *      Y (BT.601, a choice). The model applies all of these in every output
 *      format, raw Bayer included. On the chip, automatic exposure (COM8[0])
 *      takes a brightness change back over about 32 frames (measured); the
 *      model has no exposure loop, so it shows the change in full.
 *    - PSHFT n: output pixel x shows what pixel x - n would have shown, so the
 *      picture moves n pixels to the right, and the first n pixels of each
 *      line show what lies just outside the window.
 *    - Soft sleep stops the video port at the next PCLK, with every output
 *      low. Clearing COM2[4] starts a new frame.
 *  Like every model, it is only as correct as our reading of the datasheet
 *  and of one board. Where neither settles a question (where column 0 of the
 *  array sits relative to HSTART, whether the chip acknowledges the
 *  don't-care bit) the header of the code that makes the choice says so.
 *  When the board and the model disagree, the board is right: fix the model.
 *
 *  HOW TO USE
 *  ----------
 *    ov7670_model cam (
 *        .sio_c(GPIO_1[25]), .sio_d(GPIO_1[24]),          // SCCB (needs `pullup(GPIO_1[24]);` in the bench)
 *        .xclk(GPIO_1[20]), .reset_n(GPIO_1[11]), .pwdn(GPIO_1[10]),
 *        .pclk(GPIO_1[21]), .vsync(GPIO_1[23]), .href(GPIO_1[22]), .d(GPIO_1[19:12]),
 *        .scene_mode(3), .scene_x0(x_pan), .scene_y0(0), .scene_code(8'hA5)   // what the camera sees
 *    );
 *  Parameters: SCENE_FILE (a .hex of 24-bit RGB words, SCENE_W x SCENE_H, row
 *  major, made by the camera project's tools/make_scene.py; "" = the built-in scenes), NOISE (random
 *  +-LSBs per channel), VERBOSE. Hooks for benches: cam.frames_done,
 *  cam.expected_rgb(col,row) and cam.expected_word(col,row) say what the chip
 *  is outputting for output pixel (col,row) under the current registers, so a
 *  capture module can be checked pixel by pixel; cam.ctrl.refuse[r] = n makes
 *  the next n writes to register r go unacknowledged, so a bench can check
 *  that the design sends a refused write again. cam.set_course_tuning() writes
 *  the rest of the course's list (its tuning and colour blocks), for a bench
 *  that sets the format and the window with set_reg: without it the chip
 *  keeps Table 5's colour matrix, as it would on the board.
 *  cam.print_summary() at the end describes the state the chip is in;
 *  cam.check_course_config() checks it against what the Major Project camera
 *  code expects.
 *
 *  The two halves can be used separately: ov7670_sccb_if (the control bus and
 *  registers) and ov7670_video (the video port, driven from a register array
 *  you fill yourself, no SCCB needed).
 * ============================================================================
 */

package ov7670_pkg;

    localparam logic [6:0] SCCB_ADDR = 7'h21;      // write byte 0x42, read byte 0x43 (p.11)

    // Registers the model refers to by name (Table 5). Every register is stored, and every write is described.
    localparam logic [7:0] R_GAIN = 8'h00, R_BLUE = 8'h01, R_RED = 8'h02, R_VREF = 8'h03, R_COM1 = 8'h04,
        R_COM2 = 8'h09, R_PID = 8'h0A, R_VER = 8'h0B, R_COM3 = 8'h0C, R_COM4 = 8'h0D, R_COM5 = 8'h0E,
        R_COM6 = 8'h0F, R_AECH = 8'h10, R_CLKRC = 8'h11, R_COM7 = 8'h12, R_COM8 = 8'h13, R_COM9 = 8'h14,
        R_COM10 = 8'h15, R_HSTART = 8'h17, R_HSTOP = 8'h18, R_VSTRT = 8'h19, R_VSTOP = 8'h1A, R_PSHFT = 8'h1B,
        R_MIDH = 8'h1C, R_MIDL = 8'h1D, R_MVFP = 8'h1E, R_AEW = 8'h24, R_AEB = 8'h25, R_EXHCH = 8'h2A,
        R_EXHCL = 8'h2B, R_ADVFL = 8'h2D, R_ADVFH = 8'h2E, R_HSYST = 8'h30, R_HSYEN = 8'h31, R_HREF = 8'h32,
        R_TSLB = 8'h3A, R_COM11 = 8'h3B, R_COM12 = 8'h3C, R_COM13 = 8'h3D, R_COM14 = 8'h3E, R_EDGE = 8'h3F,
        R_COM15 = 8'h40, R_COM16 = 8'h41, R_COM17 = 8'h42, R_MTX1 = 8'h4F, R_MTX2 = 8'h50, R_MTX3 = 8'h51,
        R_MTX4 = 8'h52, R_MTX5 = 8'h53, R_MTX6 = 8'h54, R_BRIGHT = 8'h55, R_CONTRAS = 8'h56, R_CONTRAS_CENTER = 8'h57,
        R_MTXS = 8'h58, R_MANU = 8'h67, R_MANV = 8'h68, R_GFIX = 8'h69, R_GGAIN = 8'h6A, R_DBLV = 8'h6B, R_SCALING_XSC = 8'h70,
        R_SCALING_YSC = 8'h71, R_SCALING_DCWCTR = 8'h72, R_SCALING_PCLK_DIV = 8'h73, R_REG74 = 8'h74,
        R_RGB444 = 8'h8C, R_DM_LNL = 8'h92, R_DM_LNH = 8'h93, R_SCALING_PCLK_DELAY = 8'hA2;

    // Reset value of every register (Table 5, "Default" column). Unlisted addresses are
    // reserved and default to 0x00 here (the datasheet says "XX").
    function automatic logic [7:0] reset_value(input logic [7:0] a);
        /*verilator no_inline_task*/   // one copy (see reg_name)
        case (a)
            8'h01, 8'h02, 8'h27, 8'h28, 8'h2C, 8'h32, 8'h57, 8'h67, 8'h68, 8'hAD, 8'hAE, 8'hAF, 8'hB3: return 8'h80;
            8'h09, 8'h0E, 8'h22, 8'h38, 8'h76, 8'h1E: return 8'h01;
            8'h0A: return 8'h76;  8'h0B: return 8'h73;  8'h0F: return 8'h43;  8'h10: return 8'h40;
            8'h11: return 8'h80;  8'h13: return 8'h8F;  8'h14: return 8'h4A;  8'h17: return 8'h11;
            8'h18: return 8'h61;  8'h19: return 8'h03;  8'h1A: return 8'h7B;  8'h1C: return 8'h7F;
            8'h1D: return 8'hA2;  8'h20: return 8'h04;  8'h21: return 8'h02;  8'h24: return 8'h75;
            8'h25: return 8'h63;  8'h26: return 8'hD4;  8'h30: return 8'h08;  8'h31: return 8'h30;
            8'h33: return 8'h08;  8'h34: return 8'h11;  8'h37: return 8'h3F;  8'h3A: return 8'h0D;
            8'h3C: return 8'h68;  8'h3D: return 8'h88;  8'h40: return 8'hC0;  8'h41: return 8'h08;
            8'h43: return 8'h14;  8'h44: return 8'hF0;  8'h45: return 8'h45;  8'h46: return 8'h61;
            8'h47: return 8'h51;  8'h48: return 8'h79;  8'h4F: return 8'h40;  8'h50: return 8'h34;
            8'h51: return 8'h0C;  8'h52: return 8'h17;  8'h53: return 8'h29;  8'h54: return 8'h40;
            8'h56: return 8'h40;  8'h58: return 8'h1E;  8'h64: return 8'h50;  8'h65: return 8'h30;
            8'h6B: return 8'h0A;  8'h6C: return 8'h02;  8'h6D: return 8'h55;  8'h6E: return 8'hC0;
            8'h6F: return 8'h9A;  8'h70: return 8'h3A;  8'h71: return 8'h35;  8'h72: return 8'h11;
            8'h75: return 8'h0F;  8'h77: return 8'h10;  8'h7A: return 8'h24;  8'h7B: return 8'h04;
            8'h7C: return 8'h07;  8'h7D: return 8'h10;  8'h7E: return 8'h28;  8'h7F: return 8'h36;
            8'h80: return 8'h44;  8'h81: return 8'h52;  8'h82: return 8'h60;  8'h83: return 8'h6C;
            8'h84: return 8'h78;  8'h85: return 8'h8C;  8'h86: return 8'h9E;  8'h87: return 8'hBB;
            8'h88: return 8'hD2;  8'h89: return 8'hE5;  8'h94: return 8'h50;  8'h95: return 8'h50;
            8'h9D: return 8'h99;  8'h9E: return 8'h7F;  8'h9F: return 8'hC0;  8'hA0: return 8'h90;
            8'hA2: return 8'h02;  8'hA5: return 8'h0F;  8'hA6: return 8'hF0;  8'hA7: return 8'hC1;
            8'hA8: return 8'hF0;  8'hA9: return 8'hC1;  8'hAA: return 8'h14;  8'hAB: return 8'h0F;
            8'hB5: return 8'h04;  8'hC9: return 8'hC0;
            default: return 8'h00;
        endcase
    endfunction

    function automatic bit is_read_only(input logic [7:0] a);
        return (a == R_PID) || (a == R_VER) || (a == R_MIDH) || (a == R_MIDL);
    endfunction

    // The registers Table 5 lists as RSVD, with default "XX", and the factory-reserved ones above 0xC9.
    function automatic bit is_reserved(input logic [7:0] a);
        case (a)
            8'h16, 8'h29, 8'h35, 8'h36, 8'h49, 8'h4A, 8'h4D, 8'h4E, 8'h78, 8'h79, 8'h8A, 8'h8B,
            8'h8D, 8'h8E, 8'h8F, 8'h90, 8'h91, 8'h96, 8'h97, 8'h98, 8'h99, 8'h9A, 8'h9B, 8'h9C,
            8'hA1, 8'hA3, 8'hB0, 8'hB2, 8'hB4, 8'hB6, 8'hB7, 8'hB8, 8'hB9, 8'hBA, 8'hBB, 8'hBC, 8'hBD,
            8'hC2, 8'hC3, 8'hC4, 8'hC5, 8'hC6, 8'hC7, 8'hC8: return 1;
            8'h59, 8'h5A, 8'h5B, 8'h5C, 8'h5D, 8'h5E, 8'h5F, 8'h60, 8'h61: return 1;   // "AWB Control", no bit definitions
            default: return (a > 8'hC9);
        endcase
    endfunction

    // OmniVision's value for a register whose bits Table 5 does not describe, as the Linux ov7670 driver sends
    // it ("the default register settings, as obtained from OmniVision"; the course's register list copies them).
    // -1: OmniVision gives no value.
    function automatic int ov_value(input logic [7:0] a);
        case (a)
            8'h0E: return 'h61;  8'h16: return 'h02;  8'h21: return 'h02;  8'h22: return 'h91;  8'h29: return 'h07;
            8'h33: return 'h0B;  8'h34: return 'h11;  8'h35: return 'h0B;  8'h37: return 'h1D;  8'h38: return 'h71;
            8'h39: return 'h2A;  8'h43: return 'h0A;  8'h44: return 'hF0;  8'h45: return 'h34;  8'h46: return 'h58;
            8'h47: return 'h28;  8'h48: return 'h3A;  8'h4D: return 'h40;  8'h4E: return 'h20;  8'h59: return 'h88;
            8'h5A: return 'h88;  8'h5B: return 'h44;  8'h5C: return 'h67;  8'h5D: return 'h49;  8'h5E: return 'h0E;
            8'h6C: return 'h0A;  8'h6D: return 'h55;  8'h6E: return 'h11;  8'h6F: return 'h9F;  8'h78: return 'h04;
            8'h8D: return 'h4F;  8'h8E, 8'h8F, 8'h90, 8'h91, 8'h96: return 'h00;
            8'h97: return 'h30;  8'h98: return 'h20;  8'h99: return 'h30;  8'h9A: return 'h84;  8'h9B: return 'h29;
            8'h9C: return 'h03;  8'hA1: return 'h03;  8'hB0: return 'h84;  8'hB2: return 'h0E;  8'hB8: return 'h0A;
            default: return -1;
        endcase
    endfunction

    // The reference for the estimated stages (FIDELITY in the header): the course's register list
    // (rtl/ov7670_config.sv in the camera project) for the registers those stages read, Table 5's default for
    // the ones it leaves alone (the gamma curve, GFIX). The scene is the picture these values give.
    function automatic logic [7:0] est_ref(input logic [7:0] a);
        /*verilator no_inline_task*/
        case (a)
            R_COM8:  return 8'hE7;   R_COM13: return 8'hC0;   R_COM16: return 8'h18;   R_REG74: return 8'h10;
            R_BLUE:  return 8'h40;   R_RED:   return 8'h60;   R_GGAIN: return 8'h40;   R_MTXS:  return 8'h9E;
            R_MTX1:  return 8'h80;   R_MTX2:  return 8'h80;   R_MTX3:  return 8'h00;
            R_MTX4:  return 8'h22;   R_MTX5:  return 8'h5E;   R_MTX6:  return 8'h80;
            default: return reset_value(a);
        endcase
    endfunction

    function automatic string reg_name(input logic [7:0] a);
        /*verilator no_inline_task*/   // one copy: Verilator would inline this table, and decode's, into every caller,
                                       // which makes the model's C++ several times bigger
        case (a)
            8'h00: return "GAIN";    8'h01: return "BLUE";    8'h02: return "RED";     8'h03: return "VREF";
            8'h04: return "COM1";    8'h05: return "BAVE";    8'h06: return "GbAVE";   8'h07: return "AECHH";
            8'h08: return "RAVE";    8'h09: return "COM2";    8'h0A: return "PID";     8'h0B: return "VER";
            8'h0C: return "COM3";    8'h0D: return "COM4";    8'h0E: return "COM5";    8'h0F: return "COM6";
            8'h10: return "AECH";    8'h11: return "CLKRC";   8'h12: return "COM7";    8'h13: return "COM8";
            8'h14: return "COM9";    8'h15: return "COM10";   8'h17: return "HSTART";  8'h18: return "HSTOP";
            8'h19: return "VSTRT";   8'h1A: return "VSTOP";   8'h1B: return "PSHFT";   8'h1C: return "MIDH";
            8'h1D: return "MIDL";    8'h1E: return "MVFP";    8'h1F: return "LAEC";    8'h20: return "ADCCTR0";
            8'h21: return "ADCCTR1"; 8'h22: return "ADCCTR2"; 8'h23: return "ADCCTR3"; 8'h24: return "AEW";
            8'h25: return "AEB";     8'h26: return "VPT";     8'h27: return "BBIAS";   8'h28: return "GbBIAS";
            8'h2A: return "EXHCH";   8'h2B: return "EXHCL";   8'h2C: return "RBIAS";   8'h2D: return "ADVFL";
            8'h2E: return "ADVFH";   8'h2F: return "YAVE";    8'h30: return "HSYST";   8'h31: return "HSYEN";
            8'h32: return "HREF";    8'h33: return "CHLF";    8'h34: return "ARBLM";   8'h37: return "ADC";
            8'h38: return "ACOM";    8'h39: return "OFON";    8'h3A: return "TSLB";    8'h3B: return "COM11";
            8'h3C: return "COM12";   8'h3D: return "COM13";   8'h3E: return "COM14";   8'h3F: return "EDGE";
            8'h40: return "COM15";   8'h41: return "COM16";   8'h42: return "COM17";   8'h43: return "AWBC1";
            8'h44: return "AWBC2";   8'h45: return "AWBC3";   8'h46: return "AWBC4";   8'h47: return "AWBC5";
            8'h48: return "AWBC6";   8'h4B: return "REG4B";   8'h4C: return "DNSTH";   8'h4F: return "MTX1";
            8'h50: return "MTX2";    8'h51: return "MTX3";    8'h52: return "MTX4";    8'h53: return "MTX5";
            8'h54: return "MTX6";    8'h55: return "BRIGHT";  8'h56: return "CONTRAS"; 8'h57: return "CONTRAS-CENTER";
            8'h58: return "MTXS";    8'h62: return "LCC1";    8'h63: return "LCC2";    8'h64: return "LCC3";
            8'h65: return "LCC4";    8'h66: return "LCC5";    8'h67: return "MANU";    8'h68: return "MANV";
            8'h69: return "GFIX";    8'h6A: return "GGAIN";   8'h6B: return "DBLV";    8'h6C: return "AWBCTR3";
            8'h6D: return "AWBCTR2"; 8'h6E: return "AWBCTR1"; 8'h6F: return "AWBCTR0"; 8'h70: return "SCALING_XSC";
            8'h71: return "SCALING_YSC"; 8'h72: return "SCALING_DCWCTR"; 8'h73: return "SCALING_PCLK_DIV";
            8'h74: return "REG74";   8'h75: return "REG75";   8'h76: return "REG76";   8'h77: return "REG77";
            8'h7A: return "SLOP";    8'h8C: return "RGB444";  8'h92: return "DM_LNL";  8'h93: return "DM_LNH";
            8'h94: return "LCC6";    8'h95: return "LCC7";    8'h9D: return "BD50ST";  8'h9E: return "BD60ST";
            8'h9F: return "HAECC1";  8'hA0: return "HAECC2";  8'hA2: return "SCALING_PCLK_DELAY";
            8'hA4: return "NT_CTRL"; 8'hA5: return "BD50MAX"; 8'hA6: return "HAECC3";  8'hA7: return "HAECC4";
            8'hA8: return "HAECC5";  8'hA9: return "HAECC6";  8'hAA: return "HAECC7";  8'hAB: return "BD60MAX";
            8'hAC: return "STR-OPT"; 8'hAD: return "STR_R";   8'hAE: return "STR_G";   8'hAF: return "STR_B";
            8'hB1: return "ABLC1";   8'hB3: return "THL_ST";  8'hB5: return "THL_DLT"; 8'hBE: return "AD-CHB";
            8'hBF: return "AD-CHR";  8'hC0: return "AD-CHGb"; 8'hC1: return "AD-CHGr"; 8'hC9: return "SATCTR";
            default: begin
                if (a >= 8'h7B && a <= 8'h89) return $sformatf("GAM%0d", int'(a) - 8'h7A);
                return "RSVD";
            end
        endcase
    endfunction

    function automatic string onoff(input logic b);
        return b ? "on" : "off";
    endfunction

    // A conditional between two string literals is sized to the longer one and padded; this keeps them strings.
    function automatic string pick(input logic c, input string a, input string b);
        return c ? a : b;
    endfunction

    function automatic int pll_factor(input logic [7:0] dblv);
        case (dblv[7:6]) 2'b00: return 1; 2'b01: return 4; 2'b10: return 6; default: return 8; endcase
    endfunction

    function automatic int com14_div(input logic [7:0] com14);
        case (com14[2:0]) 3'b000: return 1; 3'b001: return 2; 3'b010: return 4; 3'b011: return 8; 3'b100: return 16; default: return 0; endcase
    endfunction

    // ---- what a write means: Table 5, in words ---------------------------------------------------------------
    // "not simulated" marks what the model stores but does not act on, and "estimated" the stages FIDELITY (in the
    // header) lists as estimated.

    // "bit 3", "bits 5 and 4", "bits 7, 5 and 4": the bits set in b
    function automatic string bit_list(input logic [7:0] b);
        string s = "";
        int n = 0, k = 0;
        for (int i = 0; i < 8; i++) n += b[i];
        for (int i = 7; i >= 0; i--)
            if (b[i]) begin
                k++;
                s = {s, pick(k == 1, "", pick(k == n, " and ", ", ")), $sformatf("%0d", i)};
            end
        return {pick(n == 1, "bit ", "bits "), s};
    endfunction

    // "; reserved bit 3 set (default 0x88)": the bits Table 5 calls reserved (mask) that differ from the default.
    function automatic string rsvd_bits(input logic [7:0] a, input logic [7:0] d, input logic [7:0] mask);
        /*verilator no_inline_task*/
        logic [7:0] diff, set, clr;
        diff = (d ^ reset_value(a)) & mask;
        if (diff == 0) return "";
        set = diff & d; clr = diff & ~d;
        return $sformatf("; reserved %s%s%s (default 0x%02X)", pick(set != 0, {bit_list(set), " set"}, ""), pick(set != 0 && clr != 0, ", ", ""),
                         pick(clr != 0, {bit_list(clr), " clear"}, ""), reset_value(a));
    endfunction

    // A register whose bits Table 5 does not describe: the default, and whether the value is OmniVision's.
    function automatic string rsvd_reg(input logic [7:0] a, input logic [7:0] d, input string what);
        /*verilator no_inline_task*/
        int ov;
        string dflt;
        ov = ov_value(a);
        dflt = is_reserved(a) ? "Table 5 gives no default" : $sformatf("default 0x%02X", reset_value(a));
        if (ov < 0)  return $sformatf("%s (%s)", what, dflt);
        if (d != ov && !is_reserved(a) && ov == reset_value(a)) return $sformatf("%s; OmniVision's tuning value and the default are both 0x%02X", what, ov);
        if (d != ov) return $sformatf("%s; OmniVision's tuning value is 0x%02X (%s)", what, ov, dflt);
        if (!is_reserved(a) && ov == reset_value(a)) return $sformatf("%s: OmniVision's tuning value, the same as the default (0x%02X)", what, ov);
        return $sformatf("%s: OmniVision's tuning value (%s)", what, dflt);
    endfunction

    function automatic string gain4(input logic [1:0] g);   // GFIX
        return pick(g == 0, "1", pick(g == 1, "1.25", pick(g == 2, "1.5", "1.75")));
    endfunction

    // Registers 0x00 to 0x3F (decode() picks the half; two functions keep each one's C++ small).
    function automatic string decode_lo(input logic [7:0] a, input logic [7:0] d);
        /*verilator no_inline_task*/   // one copy (see reg_name)
        case (a)
            R_GAIN:  return $sformatf("AGC gain, low 8 bits = %0d (AGC[9:8] are VREF[7:6]); not simulated", d);
            R_BLUE:  return $sformatf("AWB blue channel gain %0d: with AWB off (COM8[1] = 0) a fixed gain, estimated as x%0.2f (the course's 0x40 is x1); with AWB on the chip sets it (not simulated)", d, real'(d) / 64.0);
            R_RED:   return $sformatf("AWB red channel gain %0d: with AWB off (COM8[1] = 0) a fixed gain, estimated as x%0.2f (the course's 0x60 is x1); with AWB on the chip sets it (not simulated)", d, real'(d) / 96.0);
            R_VREF:  return $sformatf("AGC[9:8] = %0d (bits 7:6, not simulated), window end row low 2 bits = %0d (bits 3:2), start row low 2 bits = %0d (bits 1:0)%s",
                                      d[7:6], d[3:2], d[1:0], rsvd_bits(a, d, 8'h30));
            R_COM1:  return $sformatf("CCIR656 format %s (bit 6), exposure AEC[1:0] = %0d (bits 1:0)%s; not simulated", onoff(d[6]), d[1:0], rsvd_bits(a, d, 8'hBC));
            8'h05:   return "U/B average level, which the chip updates itself; not simulated";
            8'h06:   return "Y/Gb average level, which the chip updates itself; not simulated";
            8'h07:   return $sformatf("exposure AEC[15:10] = %0d (bits 5:0; AECH holds AEC[9:2], COM1 AEC[1:0])%s; not simulated", d[5:0], rsvd_bits(a, d, 8'hC0));
            8'h08:   return "V/R average level, which the chip updates itself; not simulated";
            R_COM2:  return $sformatf("soft sleep %s (bit 4), output drive %0dx (bits 1:0, not simulated)%s", onoff(d[4]), int'(d[1:0]) + 1, rsvd_bits(a, d, 8'hEC));
            R_PID, R_VER, R_MIDH, R_MIDL: return "read only";
            R_COM3:  return $sformatf("output data MSB and LSB swap %s (bit 6), PCLK %s in power-down (bit 5), data %s in power-down (bit 4), scaling %s (bit 3), DCW %s (bit 2)%s; only DCW is simulated",
                                      onoff(d[6]), pick(d[5], "driven", "tri-stated"), pick(d[4], "driven", "tri-stated"), onoff(d[3]), onoff(d[2]), rsvd_bits(a, d, 8'h83));
            R_COM4:  return $sformatf("average window %s (bits 5:4; must match COM17[7:6])%s; not simulated",
                                      pick(d[5:4] == 0, "full", pick(d[5:4] == 1, "1/2", "1/4")), rsvd_bits(a, d, 8'hCF));
            R_COM6:  return $sformatf("%s (bit 7), %s (bit 1)%s%s; not simulated",
                                      pick(d[7], "HREF at the optical black lines too", "no HREF at the optical black lines"),
                                      pick(d[1], "timing reset when the format changes", "no timing reset when the format changes"),
                                      rsvd_bits(a, d, 8'h7D), pick(d[3], "; BBIAS, GbBIAS and RBIAS work only with bit 3 set (Table 5)", ""));
            R_AECH:  return $sformatf("exposure AEC[9:2] = %0d (AECHH holds AEC[15:10], COM1 AEC[1:0]); not simulated", d);
            R_CLKRC: return $sformatf("%s, %s", pick(d[6], "XCLK used directly (bit 6): no prescaler, and the clock is not halved", $sformatf("prescaler /%0d (bits 5:0)", int'(d[5:0]) + 1)),
                                      pick(d[7], "bit 7 set, as after reset: the clock is not halved",
                                                 pick(d[6], "bit 7 clear (bit 6 keeps the clock whole)",
                                                      "bit 7 clear: the clock is halved (Table 5 calls bit 7 reserved; this was measured on a board)")));
            R_COM7:  begin
                if (d[7]) return "software reset (bit 7): every register goes back to its default, COM7 included";
                return $sformatf("%s, %s, colour bar overlay %s (bit 1)%s", pick(d[5], "CIF (bit 5)", pick(d[4], "QVGA (bit 4)", pick(d[3], "QCIF (bit 3)", "VGA"))),
                                 pick(d[2], pick(d[0], "processed Bayer raw output (bits 2 and 0)", "RGB output (bit 2)"), pick(d[0], "Bayer raw output (bit 0)", "YUV output")),
                                 onoff(d[1]), rsvd_bits(a, d, 8'h40));
            end
            R_COM8:  return $sformatf("fast AGC/AEC %s (bit 7), AEC step %s (bit 6), banding filter %s (bit 5), AGC %s (bit 2), AWB %s (bit 1), AEC %s (bit 0)%s; not simulated%s",
                                      onoff(d[7]), pick(d[6], "unlimited", "limited to the vertical blank"), onoff(d[5]), onoff(d[2]), onoff(d[1]), onoff(d[0]),
                                      rsvd_bits(a, d, 8'h18), pick(d[1], "", "; with AWB off, BLUE and RED are fixed gains (estimated) and GGAIN a green gain"));
            R_COM9:  return $sformatf("AGC ceiling %s (bits 6:4), AGC/AEC freeze %s (bit 0)%s; not simulated",
                                      pick(d[6:4] == 7, "111, not allowed", $sformatf("%0dx", 2 << d[6:4])), onoff(d[0]), rsvd_bits(a, d, 8'h8E));
            R_COM10: return $sformatf("HREF pin gives %s (bit 6), PCLK %s (bit 5), PCLK %s (bit 4), HREF %s (bit 3), VSYNC changes on the %s edge of PCLK (bit 2), VSYNC %s (bit 1), HSYNC %s (bit 0)%s",
                                      pick(d[6], "HSYNC", "HREF"), pick(d[5], "stops in the horizontal blank", "runs all the time"), pick(d[4], "reversed", "normal"),
                                      pick(d[3], "reversed", "normal"), pick(d[2], "rising", "falling"), pick(d[1], "negative", "positive"), pick(d[0], "negative", "positive"),
                                      rsvd_bits(a, d, 8'h80));
            R_HSTART: return $sformatf("window start column, high 8 bits: %0d x 8 = %0d, plus HREF[2:0]", d, int'(d) * 8);
            R_HSTOP:  return $sformatf("window end column, high 8 bits: %0d x 8 = %0d, plus HREF[5:3]", d, int'(d) * 8);
            R_VSTRT:  return $sformatf("window start row, high 8 bits: %0d x 4 = %0d, plus VREF[1:0]", d, int'(d) * 4);
            R_VSTOP:  return $sformatf("window end row, high 8 bits: %0d x 4 = %0d, plus VREF[3:2]", d, int'(d) * 4);
            R_PSHFT:  return $sformatf("data delayed %0d pixels relative to HREF", d);
            R_MVFP:   return $sformatf("mirror %s (bit 5), vertical flip %s (bit 4), black sun enable %s (bit 2, not simulated)%s",
                                       onoff(d[5]), onoff(d[4]), onoff(d[2]), rsvd_bits(a, d, 8'hCB));
            8'h20:    return $sformatf("ADC range %s (bit 3), ADC reference %s (bits 2:0)%s; not simulated", pick(d[3], "1.5x", "1x"),
                                       pick(d[2:0] == 0, "0.8x", pick(d[2:0] == 4, "1x", pick(d[2:0] == 7, "1.2x", $sformatf("code %03b (Table 5 names 000, 100 and 111)", d[2:0])))),
                                       rsvd_bits(a, d, 8'hF0));
            R_AEW:    return $sformatf("AGC/AEC stable region, upper limit %0d; not simulated", d);
            R_AEB:    return $sformatf("AGC/AEC stable region, lower limit %0d; not simulated", d);
            8'h26:    return $sformatf("AGC/AEC fast mode region: upper limit high nibble %0d (bits 7:4), lower limit high nibble %0d (bits 3:0); not simulated", d[7:4], d[3:0]);
            8'h27, 8'h28, 8'h2C:
                      return $sformatf("%s channel output bias: %s %0d on the 10-bit scale (bits 7 and 6:0; needs COM6[3] = 1); not simulated",
                                       pick(a == 8'h27, "B", pick(a == 8'h28, "Gb", "R")), pick(d[7], "subtract", "add"), d[6:0]);
            R_EXHCH:  return $sformatf("dummy pixels, high 4 bits = %0d (bits 7:4); HSYNC falling edge delay MSBs %0d (bits 3:2) and rising edge delay MSBs %0d (bits 1:0), not simulated",
                                       d[7:4], d[3:2], d[1:0]);
            R_EXHCL:  return $sformatf("dummy pixels at the end of each line, inside HREF, low 8 bits = %0d", d);
            R_ADVFL:  return $sformatf("dummy lines inside VSYNC, low 8 bits = %0d", d);
            R_ADVFH:  return $sformatf("dummy lines inside VSYNC, high 8 bits = %0d", d);
            8'h2F:    return "Y/G average level, which the chip updates itself; not simulated";
            R_HSYST:  return $sformatf("HSYNC rising edge delay, low 8 bits = %0d; not simulated", d);
            R_HSYEN:  return $sformatf("HSYNC falling edge delay, low 8 bits = %0d; not simulated", d);
            R_HREF:   return $sformatf("HREF edge offset to the data = %0d (bits 7:6, not simulated), window end column low 3 bits = %0d (bits 5:3), start column low 3 bits = %0d (bits 2:0)",
                                       d[7:6], d[5:3], d[2:0]);
            8'h33:    return rsvd_reg(a, d, "array current control, all bits reserved");
            8'h34:    return rsvd_reg(a, d, "array reference control, all bits reserved");
            8'h37:    return rsvd_reg(a, d, "ADC control, all bits reserved");
            8'h38:    return rsvd_reg(a, d, "ADC and analogue common mode control, all bits reserved");
            8'h39:    return rsvd_reg(a, d, "ADC offset control, all bits reserved");
            R_TSLB:   return $sformatf("%s (bit 5), %s (bit 4), YUV byte order: bit 3 = %0d (with COM13[0]), output window %s (bit 0, not simulated)%s",
                                       pick(d[5], "negative image", "normal image"), pick(d[4], "fixed U and V from MANU and MANV", "normal U and V"), d[3],
                                       pick(d[0], "set automatically after a size change", "not set automatically"), rsvd_bits(a, d, 8'hC6));
            R_COM11:  return $sformatf("night mode %s (bit 7%s), 50/60 Hz auto detection %s (bit 4), banding filter value from %s (bit 3), exposure %s the banding step in strong light (bit 1)%s; not simulated",
                                       onoff(d[7]), pick(d[7], pick(d[6:5] == 0, "; lowest frame rate the normal one, bits 6:5", $sformatf("; lowest frame rate 1/%0d of normal, bits 6:5", 1 << d[6:5])), ""),
                                       onoff(d[4]), pick(d[3], "BD50ST, 50 Hz", "BD60ST, 60 Hz"), pick(d[1], "may go below", "stays at or above"), rsvd_bits(a, d, 8'h05));
            R_COM12:  return $sformatf("%s (bit 7)%s; not simulated", pick(d[7], "always has HREF", "no HREF when VSYNC is low"), rsvd_bits(a, d, 8'h7F));
            R_COM13:  return $sformatf("gamma %s (bit 7, estimated), UV saturation auto-adjust %s (bit 6, not simulated), UV swap %s (bit 0, with TSLB[3] it sets the YUV byte order)%s",
                                       onoff(d[7]), onoff(d[6]), onoff(d[0]), rsvd_bits(a, d, 8'h3E));
            R_COM14:  return $sformatf("DCW and scaling PCLK %s (bit 4), manual scaling %s (bit 3, not simulated), PCLK divider %s (bits 2:0, used when bit 4 is on)%s",
                                       onoff(d[4]), onoff(d[3]), pick(com14_div(d) == 0, $sformatf("%03b, not allowed", d[2:0]), $sformatf("/%0d", com14_div(d))),
                                       rsvd_bits(a, d, 8'hE0));
            R_EDGE:   return $sformatf("edge enhancement factor %0d (bits 4:0)%s; not simulated", d[4:0], rsvd_bits(a, d, 8'hE0));
            default:  return rsvd_reg(a, d, "reserved");
        endcase
    endfunction

    // Registers 0x40 to 0xFF.
    function automatic string decode_hi(input logic [7:0] a, input logic [7:0] d);
        /*verilator no_inline_task*/   // one copy (see reg_name)
        case (a)
            R_COM15:  return $sformatf("output range %s (bits 7:6), %s (bits 5:4)%s", pick(d[7:6] == 2'b11, "00 to FF", pick(d[7:6] == 2'b10, "01 to FE", "10 to F0")),
                                       pick(d[5:4] == 2'b01, "RGB565", pick(d[5:4] == 2'b11, "RGB555", "normal RGB, which is GRB 4:2:2")), rsvd_bits(a, d, 8'h0F));
            R_COM16:  return $sformatf("edge enhancement auto-adjust %s (bit 5), de-noise auto-adjust %s (bit 4), AWB gain %s (bit 3): not simulated; colour matrix %s (bit 1): estimated%s",
                                       onoff(d[5]), onoff(d[4]), onoff(d[3]), pick(d[1], "doubled", "not doubled"), rsvd_bits(a, d, 8'hC5));
            R_COM17:  return $sformatf("AEC window %s (bits 7:6, must match COM4[5:4]; not simulated), DSP colour bar %s (bit 3)%s",
                                       pick(d[7:6] == 0, "normal", pick(d[7:6] == 1, "1/2", "1/4")), onoff(d[3]), rsvd_bits(a, d, 8'h37));
            8'h4B:    return $sformatf("UV average %s (bit 0)%s; not simulated", onoff(d[0]), rsvd_bits(a, d, 8'hFE));
            8'h4C:    return $sformatf("de-noise strength %0d; not simulated", d);
            R_MTX1, R_MTX2, R_MTX3, R_MTX4, R_MTX5, R_MTX6:
                      return $sformatf("colour matrix coefficient %0d = %0d, %s into %s (its sign is in MTXS); estimated", int'(a) - 8'h4E, d,
                                       pick(a == R_MTX1 || a == R_MTX4, "red", pick(a == R_MTX2 || a == R_MTX5, "green", "blue")), pick(a <= R_MTX3, "V", "U"));
            R_BRIGHT: return $sformatf("brightness %s%0d (bit 7 = sign, bits 6:0 = size)", pick(d[6:0] == 0, "", pick(d[7], "-", "+")), d[6:0]);
            R_CONTRAS: return $sformatf("contrast x%0.2f (%0d/64; 0x40 is x1)", real'(d) / 64.0, d);
            R_CONTRAS_CENTER: return $sformatf("contrast centre %0d (used when MTXS[7] = 0)", d);
            R_MTXS:   return $sformatf("%s, colour matrix signs %06b (bits 5:0, 1 = minus; estimated)%s",
                                       pick(d[7], "contrast centre automatic (bit 7: the picture's mean luma)", "contrast centre from CONTRAS-CENTER (bit 7)"), d[5:0], rsvd_bits(a, d, 8'h40));
            8'h59, 8'h5A, 8'h5B, 8'h5C, 8'h5D, 8'h5E, 8'h5F, 8'h60, 8'h61: return rsvd_reg(a, d, "reserved, AWB control");
            8'h62:    return $sformatf("lens correction centre, X offset from the array centre = %0d; not simulated", d);
            8'h63:    return $sformatf("lens correction centre, Y offset from the array centre = %0d; not simulated", d);
            8'h64:    return $sformatf("lens correction coefficient = %0d (for G when LCC5[2] = 1, else for R, G and B); not simulated", d);
            8'h65:    return $sformatf("lens correction: radius with no correction = %0d; not simulated", d);
            8'h66:    return $sformatf("lens correction %s (bit 0), coefficients from %s (bit 2)%s; not simulated", onoff(d[0]),
                                       pick(d[2], "LCC6, LCC3 and LCC7 for R, G and B", "LCC3 for all three"), rsvd_bits(a, d, 8'hFA));
            R_MANU:   return $sformatf("fixed U value %0d (used when TSLB[4] = 1)", d);
            R_MANV:   return $sformatf("fixed V value %0d (used when TSLB[4] = 1)", d);
            R_GFIX:   return $sformatf("fixed gains: Gr x%s, Gb x%s, R x%s, B x%s; estimated (G takes the mean of Gr and Gb)", gain4(d[7:6]), gain4(d[5:4]), gain4(d[3:2]), gain4(d[1:0]));
            R_GGAIN:  return $sformatf("AWB green channel gain %0d: with AWB off (COM8[1] = 0) a fixed gain, x%0.2f (0x40 is x1, measured on a board); with AWB on the chip sets it (not simulated)", d, real'(d) / 64.0);
            R_DBLV:   return $sformatf("PLL %s (bits 7:6), internal regulator %s (bit 4, not simulated)%s", pick(d[7:6] == 0, "bypassed", $sformatf("x%0d", pll_factor(d))),
                                       pick(d[4], "bypassed", "on"), rsvd_bits(a, d, 8'h2F));
            8'h6C, 8'h6D, 8'h6E, 8'h6F:
                      return rsvd_reg(a, d, $sformatf("AWB control %0d (Table 5 does not describe its bits)", 8'h6F - int'(a)));
            R_SCALING_XSC: return $sformatf("test pattern bit 0 = %0d (bit 7; bit 1 is SCALING_YSC[7]), horizontal scale factor %0d (bits 6:0, not simulated)", d[7], d[6:0]);
            R_SCALING_YSC: return $sformatf("test pattern bit 1 = %0d (bit 7; bit 0 is SCALING_XSC[7]), vertical scale factor %0d (bits 6:0, not simulated)", d[7], d[6:0]);
            R_SCALING_DCWCTR: return $sformatf("down-sampling, used when COM3[2] = 1: vertical /%0d (bits 5:4), horizontal /%0d (bits 1:0); rounding options %02b and %02b (bits 7:6 and 3:2, not simulated)",
                                               1 << d[5:4], 1 << d[1:0], d[7:6], d[3:2]);
            R_SCALING_PCLK_DIV: return $sformatf("DSP scaling clock divider %s (bit 3), %s (bits 2:0; used when COM14[3] = 1, to match COM14[2:0])%s; not simulated",
                                                 pick(d[3], "bypassed", "on"), pick(com14_div(d) == 0, $sformatf("%03b, not allowed", d[2:0]), $sformatf("/%0d", com14_div(d))),
                                                 rsvd_bits(a, d, 8'hF0));
            R_REG74:  return $sformatf("digital gain set by %s (bit 4); bits 1:0 = %s%s; %s", pick(d[4], "bits 1:0", "VREF[7:6]"),
                                       pick(d[1:0] == 0, "00, bypass", pick(d[1:0] == 1, "01, 1x", pick(d[1:0] == 2, "10, 2x", "11, 4x"))), rsvd_bits(a, d, 8'hEC),
                                       pick(d[4], "estimated", "not simulated (VREF[7:6] is the AGC's)"));
            8'h75:    return $sformatf("edge enhancement lower limit %0d (bits 4:0)%s; not simulated", d[4:0], rsvd_bits(a, d, 8'hE0));
            8'h76:    return $sformatf("black pixel correction %s (bit 7), white pixel correction %s (bit 6), edge enhancement upper limit %0d (bits 4:0)%s; not simulated",
                                       onoff(d[7]), onoff(d[6]), d[4:0], rsvd_bits(a, d, 8'h20));
            8'h77:    return $sformatf("de-noise offset %0d; not simulated", d);
            8'h7A:    return $sformatf("gamma curve, slope of the highest segment = %0d (x64; Table 5: (256 - GAM15) x 4/3); estimated", d);
            8'h7B, 8'h7C, 8'h7D, 8'h7E, 8'h7F, 8'h80, 8'h81, 8'h82, 8'h83, 8'h84, 8'h85, 8'h86, 8'h87, 8'h88, 8'h89: begin
                int n = int'(a) - 'h7A;                     // GAMn; its input end point: 4, 8, 16, 32, 40 ... 80, 96, 112, 144, 176, 208
                return $sformatf("gamma curve, point %0d: output %0d for input %0d; estimated", n, d,
                                 (n <= 4) ? (4 << (n - 1)) : ((n <= 10) ? 32 + 8 * (n - 4) : ((n <= 12) ? 80 + 16 * (n - 10) : 112 + 32 * (n - 12))));
            end
            R_RGB444: return $sformatf("RGB444 %s (bit 1, used when COM15[4] = 1), word format %s (bit 0)%s", onoff(d[1]), pick(d[0], "RG Bx", "xR GB"), rsvd_bits(a, d, 8'hFC));
            R_DM_LNL: return $sformatf("dummy lines between VSYNC and the first line (DM_LN), low 8 bits = %0d", d);
            R_DM_LNH: return $sformatf("dummy lines between VSYNC and the first line (DM_LN), high 8 bits = %0d", d);
            8'h94:    return $sformatf("lens correction coefficient for R = %0d (used when LCC5[2] = 1); not simulated", d);
            8'h95:    return $sformatf("lens correction coefficient for B = %0d (used when LCC5[2] = 1); not simulated", d);
            8'h9D:    return $sformatf("50 Hz banding filter value %0d (used when COM8[5] and COM11[3] are 1); not simulated", d);
            8'h9E:    return $sformatf("60 Hz banding filter value %0d (used when COM8[5] is 1 and COM11[3] is 0); not simulated", d);
            8'h9F, 8'hA0, 8'hA6, 8'hA7, 8'hA8, 8'hA9:
                      return $sformatf("histogram-based AEC/AGC control %0d = %0d (Table 5 does not describe its bits); not simulated",
                                       (a < 8'hA6) ? int'(a) - 8'h9E : int'(a) - 8'hA3, d);
            R_SCALING_PCLK_DELAY: return $sformatf("scaling output delay %0d (bits 6:0)%s; not simulated", d[6:0], rsvd_bits(a, d, 8'h80));
            8'hA4:    return $sformatf("automatic frame rate adjustment %s (bit 3), dummy rows inserted %s (bits 1:0)%s; not simulated",
                                       pick(d[3], "halves the frame rate", "doubles the exposure time"),
                                       pick(d[1:0] == 0, "at 2x gain", pick(d[1:0] == 1, "at 4x gain", pick(d[1:0] == 2, "at 8x gain", "at a gain Table 5 does not list (11)"))),
                                       rsvd_bits(a, d, 8'hF4));
            8'hA5:    return $sformatf("50 Hz banding step limit %0d; not simulated", d);
            8'hAA:    return $sformatf("AEC algorithm %s (bit 7)%s; not simulated", pick(d[7], "histogram-based", "average-based"), rsvd_bits(a, d, 8'h7F));
            8'hAB:    return $sformatf("60 Hz banding step limit %0d; not simulated", d);
            8'hAC:    return $sformatf("strobe %s (bit 7), LED frame gains from STR_R/G/B %s (bit 6), xenon %0d row(s) (bits 5:4), mode %s (bits 1:0)%s; not simulated",
                                       onoff(d[7]), onoff(d[6]), int'(d[5:4]) + 1, pick(d[1], "LED 2", pick(d[0], "LED 1", "xenon")), rsvd_bits(a, d, 8'h0C));
            8'hAD, 8'hAE, 8'hAF:
                      return $sformatf("%s gain for the LED output frame = %0d; not simulated", pick(a == 8'hAD, "R", pick(a == 8'hAE, "G", "B")), d);
            8'hB1:    return $sformatf("automatic black level calibration %s (bit 2)%s; not simulated", onoff(d[2]), rsvd_bits(a, d, 8'hFB));
            8'hB3:    return $sformatf("black level calibration target %0d; not simulated", d);
            8'hB5:    return $sformatf("black level calibration stable range %0d; not simulated", d);
            8'hBE, 8'hBF, 8'hC0, 8'hC1:
                      return $sformatf("%s channel black level compensation %s%0d (bit 6 = sign, bits 5:0)%s; not simulated",
                                       pick(a == 8'hBE, "B", pick(a == 8'hBF, "R", pick(a == 8'hC0, "Gb", "Gr"))), pick(d[6], "-", "+"), d[5:0], rsvd_bits(a, d, 8'h80));
            8'hC9:    return $sformatf("UV saturation minimum %0d (bits 7:4); bits 3:0 hold the chip's own result (COM13[6]); not simulated", d[7:4]);
            default:  return rsvd_reg(a, d, "reserved");
        endcase
    endfunction

    // Human-readable meaning of a register value (Table 5).
    function automatic string decode(input logic [7:0] a, input logic [7:0] d);
        if (a < 8'h40) return decode_lo(a, d);
        return decode_hi(a, d);
    endfunction

endpackage


/*
 * ----------------------------------------------------------------------------
 *  ov7670_sccb_if : the camera's side of the SCCB and the 256-byte register file.
 * ----------------------------------------------------------------------------
 *  SCCB is OmniVision's version of I2C (the "Serial Camera Control Bus").
 *  On the wire a register write is *exactly* the transaction your Lesson 3
 *  I2C master sends to the WM8731: START, an ID byte (0x42 = 7-bit address
 *  0x21 + write), a register (sub-)address byte, a data byte, STOP, with a
 *  ninth clock after every byte. The differences:
 *    - the ninth bit is a "don't care" in SCCB, not an ACK. The OV7670 does
 *      pull SIO_D low there, so an I2C master sees an ACK (ACK_ON_WRITE=1
 *      reproduces that; set it to 0 to see a camera that keeps strictly to SCCB),
 *    - a read is two transactions: a 2-phase write (ID + sub-address, STOP)
 *      that sets the address, then a START, 0x43, the data byte from the chip,
 *      a don't-care bit driven 1 by the master, STOP,
 *    - one register per transaction; there is no auto-increment,
 *    - SIO_C up to 400 kHz (Table 4),
 *    - the chip needs XCLK running to answer, and nothing it receives in the
 *      first millisecond after a reset counts (tS:RESET, Table 4). This model
 *      DROPS such writes, prints why, and counts them as errors.
 *  SIO_D is open drain: the model only ever drives it low or lets go, and the
 *  testbench must have `pullup(...)` on the net.
 * ----------------------------------------------------------------------------
 */
module ov7670_sccb_if #(
    parameter logic [6:0] DEVICE_ADDR   = 7'h21,
    parameter bit         VERBOSE       = 1,
    parameter bit         ACK_ON_WRITE  = 1,       // drive the don't-care bit low, as the real chip does
    parameter bit         STRICT_SETTLE = 1,       // drop writes inside tS:RESET after a reset
    parameter realtime    T_SETTLE      = 1ms,     // tS:RESET (Table 4)
    parameter realtime    T_HOLD        = 200ns,   // data hold after SIO_C falls when the chip drives (tDH >= 50 ns)
    parameter realtime    T_FILTER      = 50ns     // input glitch filter
) (
    input  logic       sio_c,
    inout  wire        sio_d,
    input  logic       reset_n,        // RESET# pin
    input  logic       pwdn,           // PWDN pin
    input  logic       xclk_running,   // the chip's SCCB block is clocked from XCLK
    output logic [7:0] regs [0:255],
    output int         write_count,
    output int         read_count,
    output int         error_count,
    output int         nack_count,
    output int         dropped_count,  // writes dropped because they came too soon after a reset
    output logic       reg_written,    // toggles after each accepted write
    output logic [7:0] written_addr,
    output realtime    t_last_reset,   // when the chip last came out of a reset
    output int         reset_count
);
    import ov7670_pkg::*;

    // ---- open-drain driver -------------------------------------------------
    logic sda_drive_low = 1'b0;
    assign sio_d = sda_drive_low ? 1'b0 : 1'bz;

    // ---- input glitch filter (as in wm8731_model) ------------------------------
    logic scl_f = 1'b1, sda_f = 1'b1;
    always @(sio_c) begin
        #(T_FILTER);
        if (scl_f !== sio_c && sio_c !== 1'bx) scl_f = sio_c;
    end
    always @(sio_d) begin
        #(T_FILTER);
        if (sda_f !== (sio_d === 1'b0 ? 1'b0 : 1'b1)) sda_f = (sio_d === 1'b0 ? 1'b0 : 1'b1);
    end

    // ---- register file -------------------------------------------------------
    function automatic void reset_registers();
        for (int i = 0; i < 256; i++) regs[i] = reset_value(8'(i));
    endfunction
    initial begin
        reset_registers();
        write_count = 0; read_count = 0; error_count = 0; nack_count = 0; dropped_count = 0; reset_count = 0;
        reg_written = 1'b0; written_addr = '0; t_last_reset = 0;
    end

    logic [7:0] log_reg [$];   // every accepted write, in order (for benches)
    logic [7:0] log_val [$];

    // Bench hook, not the chip: while refuse[r] > 0, a write to register r gets no acknowledge on its data
    // byte (an I2C master reads a NACK), the register keeps its value, and refuse[r] counts down. A bench
    // sets it (cam.ctrl.refuse[8'h40] = 1) to check that the design sends a refused write again. All zero
    // by default: every write is taken, as on the real chip.
    int refuse [0:255] = '{default: 0};

    // Hardware reset: RESET# low clears the registers; the settle time starts when it is released.
    always @(negedge reset_n) begin
        reset_registers();
        $display("[OV7670 @%0t] RESET# low: all registers back to their defaults", $time);
    end
    always @(posedge reset_n) begin
        t_last_reset = $realtime; reset_count++;     // counted when released: a RESET# held low from time 0 counts too
        if (VERBOSE) $display("[OV7670 @%0t] RESET# released: the chip needs up to %0.1f ms to settle before it will take SCCB writes (tS:RESET, Table 4 p.6)", $time, T_SETTLE / 1ms);
    end

    // ---- bus bookkeeping -------------------------------------------------------
    logic       in_frame  = 1'b0;
    logic       addressed = 1'b0;
    logic       acking    = 1'b0;
    logic       reading   = 1'b0;    // a read transaction: the chip drives the data bits
    logic       read_done = 1'b0;    // all 8 data bits have been clocked out; the master's don't-care bit follows
    int         bit_cnt   = 0;
    int         byte_idx  = 0;
    int         read_bit  = 0;
    logic [7:0] shift     = '0;
    logic [7:0] sub_addr  = '0;      // the address pointer set by a 2- or 3-phase write
    logic [7:0] read_data = '0;
    realtime    t_scl_rise = 0;
    bit         warned_rate = 0, warned_chip = 0;

    function automatic void protocol_error(input string msg);
        error_count++;
        $display("[OV7670 @%0t] PROTOCOL ERROR: %s", $time, msg);
    endfunction

    function automatic bit chip_answers(input bit say);
        if (!reset_n)      begin if (say) $display("[OV7670 @%0t] RESET# is low: the chip does not answer on the SCCB (no ACK).", $time); return 0; end
        if (pwdn)          begin if (say) $display("[OV7670 @%0t] PWDN is high: the chip is in power-down and does not answer on the SCCB (no ACK).", $time); return 0; end
        if (!xclk_running) begin if (say) $display("[OV7670 @%0t] XCLK is not running: the SCCB block is clocked from XCLK, so the chip does not answer (no ACK). Drive XCLK before configuring.", $time); return 0; end
        return 1;
    endfunction

    // START: SDA falls while SCL is high.
    always @(negedge sda_f) begin
        if (scl_f === 1'b1) begin
            if (in_frame && bit_cnt != 0)
                protocol_error($sformatf("START in the middle of a byte (%0d bits received). SIO_D must only change while SIO_C is low.", bit_cnt));
            else if (VERBOSE)
                $display("[OV7670 @%0t] %sSTART", $time, pick(in_frame, "repeated ", ""));
            in_frame = 1'b1; addressed = 1'b0; acking = 1'b0; reading = 1'b0; read_done = 1'b0;
            bit_cnt = 0; byte_idx = 0; read_bit = 0; sda_drive_low = 1'b0;
        end
    end

    // STOP: SDA rises while SCL is high.
    always @(posedge sda_f) begin
        if (scl_f === 1'b1 && in_frame) begin
            // Every STOP is preceded by a rising SIO_C edge with SIO_D low, which looks like one data bit;
            // the Lesson 3 master adds one more clock pulse. After a complete byte those are harmless.
            if (bit_cnt > 2 || (bit_cnt != 0 && byte_idx == 0 && !reading))
                protocol_error($sformatf("STOP in the middle of a byte (%0d bits received). SIO_D must only change while SIO_C is low.", bit_cnt));
            else if (addressed && byte_idx == 2 && !reading) begin
                if (VERBOSE) $display("[OV7670 @%0t] STOP after a 2-phase write: address pointer = 0x%02X (%s), ready for a read", $time, sub_addr, reg_name(sub_addr));
            end
            else if (addressed && byte_idx == 1 && !reading)
                protocol_error("STOP right after the ID byte: nothing was written. A register write needs ID, sub-address and data bytes (3-phase write).");
            else if (VERBOSE)
                $display("[OV7670 @%0t] STOP", $time);
            in_frame = 1'b0; addressed = 1'b0; acking = 1'b0; reading = 1'b0; read_done = 1'b0; bit_cnt = 0; sda_drive_low = 1'b0;
        end
    end

    // Data bits are sampled on the rising edge of SCL (also the place to check the clock rate).
    always @(posedge scl_f) begin
        if (in_frame && t_scl_rise != 0 && ($realtime - t_scl_rise) < 2.4us && !warned_rate) begin
            warned_rate = 1;
            protocol_error($sformatf("SIO_C period %0.2f us = %0.0f kHz is above the 400 kHz maximum (Table 4 p.6). The course uses 100 kHz.",
                           ($realtime - t_scl_rise) / 1us, 1e6 / (($realtime - t_scl_rise) / 1us)));
        end
        t_scl_rise = $realtime;
        if (in_frame && !acking && !reading) begin
            shift = {shift[6:0], sda_f};
            bit_cnt = bit_cnt + 1;
        end
        else if (in_frame && reading && read_done && !acking) begin
            // the master's don't-care bit after a read byte (1 = NA in SCCB, 0 = ACK in I2C): either is fine
            if (VERBOSE) $display("[OV7670 @%0t] read byte finished, master drove the 9th bit = %0d", $time, sda_f);
            read_done = 1'b0;
        end
    end

    // Byte boundaries, the ninth clock and the read data are handled on the falling edge of SCL.
    always @(negedge scl_f) begin
        if (!in_frame) begin
        end
        else if (acking) begin
            #(T_HOLD);
            sda_drive_low = 1'b0;
            acking = 1'b0;
            if (reading) begin
                // first data bit of a read goes out now
                read_bit = 0;
                sda_drive_low = ~read_data[7];
                read_bit = 1;
            end
        end
        else if (reading && read_bit >= 1 && read_bit < 8) begin
            #(T_HOLD);
            sda_drive_low = ~read_data[7 - read_bit];
            read_bit = read_bit + 1;
        end
        else if (reading && read_bit == 8) begin
            // the 8th bit has just been sampled: release the line for the master's don't-care bit
            #(T_HOLD);
            sda_drive_low = 1'b0;
            read_bit = 9; read_done = 1'b1;
        end
        else if (bit_cnt == 8) begin
            logic ack;
            ack = process_byte(shift);
            bit_cnt = 0;
            byte_idx = byte_idx + 1;
            #(T_HOLD);
            if (ack) begin
                if (sio_d === 1'b0)
                    $display("[OV7670 @%0t]   note: the master is still driving SIO_D low during the 9th clock. SCCB calls this bit don't-care, so the chip does not mind; an I2C master would read a false ACK.", $time);
                sda_drive_low = ACK_ON_WRITE || reading;
                if (!ACK_ON_WRITE && !reading && VERBOSE) $display("[OV7670 @%0t]   (strict SCCB: the don't-care bit is left floating; an I2C master reads it as NACK)", $time);
            end else begin
                nack_count++;
            end
            acking = 1'b1;
        end
    end

    // Returns 1 to drive the ninth bit low (ACK), 0 to leave it.
    function automatic logic process_byte(input logic [7:0] b);
        case (byte_idx)
            0: begin
                if (b[7:1] != DEVICE_ADDR) begin
                    $display("[OV7670 @%0t] ID byte 0x%02X is not mine (0x42 = write, 0x43 = read). Ignoring until the next START (no ACK).", $time, b);
                    in_frame = 1'b0;
                    return 1'b0;
                end
                if (!chip_answers(!warned_chip)) begin warned_chip = 1; in_frame = 1'b0; return 1'b0; end
                warned_chip = 0;
                addressed = 1'b1;
                if (b[0]) begin
                    reading = 1'b1;
                    read_data = regs[sub_addr];
                    read_count++;
                    if (VERBOSE) $display("[OV7670 @%0t] ID 0x43 (read): sending %s (0x%02X) = 0x%02X", $time, reg_name(sub_addr), sub_addr, read_data);
                end
                else if (VERBOSE) $display("[OV7670 @%0t] ID 0x42 (write) -> ACK", $time);
                return 1'b1;
            end
            1: begin
                if (!addressed) return 1'b0;
                sub_addr = b;
                if (VERBOSE) $display("[OV7670 @%0t] sub-address 0x%02X (%s) -> ACK", $time, b, reg_name(b));
                return 1'b1;
            end
            2: begin
                if (!addressed) return 1'b0;
                if (refuse[sub_addr] > 0) begin          // the bench hook above
                    refuse[sub_addr]--;
                    $display("[OV7670 @%0t] data 0x%02X -> NO ACK: the bench refuses this write (refuse[0x%02X]); %s keeps 0x%02X", $time, b, sub_addr, reg_name(sub_addr), regs[sub_addr]);
                    return 1'b0;
                end
                if (VERBOSE) $display("[OV7670 @%0t] data 0x%02X -> ACK", $time, b);
                write_register(sub_addr, b);
                return 1'b1;
            end
            default: begin
                if (!addressed) return 1'b0;
                protocol_error("a fourth byte in one transaction. SCCB writes one register per START/STOP; there is no auto-increment.");
                return 1'b1;
            end
        endcase
    endfunction

    function automatic void write_register(input logic [7:0] a, input logic [7:0] d);
        if (STRICT_SETTLE && ($realtime - t_last_reset) < T_SETTLE) begin
            dropped_count++; error_count++;
            $display("[OV7670 @%0t] DROPPED WRITE %s (0x%02X) <= 0x%02X: only %0.3f ms after the last reset. The chip needs up to %0.1f ms to settle (tS:RESET, Table 4 p.6); a real chip may or may not take this write. Wait after RESET# and after COM7[7].",
                     $time, reg_name(a), a, d, ($realtime - t_last_reset) / 1ms, T_SETTLE / 1ms);
            return;
        end
        if (is_read_only(a)) begin
            $display("[OV7670 @%0t] WRITE %s (0x%02X) <= 0x%02X ignored: read-only register", $time, reg_name(a), a, d);
            return;
        end
        write_count++;
        log_reg.push_back(a); log_val.push_back(d);
        $display("[OV7670 @%0t] WRITE %s (0x%02X) <= 0x%02X: %s", $time, reg_name(a), a, d, decode(a, d));
        if (a == R_COM7 && d[7]) begin
            reset_registers(); reset_count++;
            t_last_reset = $realtime;
            $display("[OV7670 @%0t]   -> all registers reset to defaults; nothing written in the next %0.1f ms will count", $time, T_SETTLE / 1ms);
        end else begin
            regs[int'(a)] = d;
        end
        written_addr = a;
        reg_written = ~reg_written;   // toggles once per accepted write
    endfunction

endmodule


/*
 * ----------------------------------------------------------------------------
 *  ov7670_video : the video port, driven from the register array.
 * ----------------------------------------------------------------------------
 *  Timing (Figure 6, p.7, plus Table 5, plus a board: FIDELITY, "Measured"):
 *    - internal clock  f_int = f_XCLK / P x PLL(DBLV[7:6]) / H, with P =
 *      CLKRC[5:0] + 1 (1 when CLKRC[6] says "use external clock directly")
 *      and H = 2 when CLKRC[7] and CLKRC[6] are both clear, else 1. The
 *      halving is not in the datasheet, which calls bit 7 reserved: it was
 *      measured on a board;
 *    - the sensor reads one pixel every 2 internal clocks (tP = 2 tPCLK in
 *      YUV/RGB, where PCLK = f_int and each pixel is 2 bytes);
 *    - a line is 784 tP (+ dummy pixels EXHCH/EXHCL, which come out inside
 *      HREF), a frame 510 lines (+ dummy lines: ADVFH/ADVFL's inside VSYNC,
 *      DM_LNH/DM_LNL's after it): 799,680 PCLK per VGA frame, 50 fps at
 *      40 MHz;
 *    - VSYNC is high for the first 3 lines of the frame; HREF rises 2 x
 *      HSTART PCLKs into each of the window's lines (lines 19..498 for the
 *      course's rows 11..491) and is high for 640 tP; a window that runs past
 *      the line's end goes on into the next line. No HREF from 207 to 273
 *      PCLKs into a line (the window's bytes there are lost), and on the
 *      window's first line none before PCLK 139; the readout ends at row 495;
 *    - raw Bayer: 1 byte per pixel, PCLK = f_int/2 (so tP = tPCLK as Figure 6
 *      says); QVGA and CIF divide PCLK by 2 and QCIF by 4 themselves, or
 *      COM14[4] sets a divider of 1..16;
 *    - outputs change tPDV (<= 5 ns) after the FALLING edge of PCLK, so a
 *      design samples them on the RISING edge (setup 15 ns, hold 8 ns, Table 4).
 *      The model puts random bits on D[7:0] from the falling edge until tPDV
 *      later, so a design that samples on the falling edge reads the changing
 *      bus and gets the wrong pixels.
 *  Geometry (measured on a board where it says so; documented so you can argue):
 *    - the array is 656 x 488 (p.3); the window that starts at HSTART 160
 *      (the course's register list: HSTART 0x14, HSTOP 0x02, HREF 0x80) and
 *      VSTRT 12 is placed on the central 640 x 480 (a choice). The window is
 *      placed on the readout after mirror and flip (measured), so moving it
 *      moves the picture the same way, mirrored or not; columns and rows
 *      past the array's edge repeat its last ones (a choice);
 *    - readout rows 2..10 are not picture, and the pixels just after the
 *      line's gap are white (measured: FIDELITY);
 *    - the scaled modes take the window: QVGA every second line (the second
 *      of each pair), CIF 290 of its 480 lines and QCIF 145 of its 240 pairs
 *      (which ones fitted to the board's rows), half its width (QVGA, CIF) or
 *      a quarter less one pixel (QCIF).
 * ----------------------------------------------------------------------------
 */
module ov7670_video #(
    parameter bit      VERBOSE    = 1,
    parameter string   SCENE_FILE = "",       // "" = built-in scenes
    parameter int      SCENE_W    = 656,      // size of the picture in SCENE_FILE
    parameter int      SCENE_H    = 488,
    parameter int      NOISE      = 0,        // random +-NOISE per channel, before conversion
    parameter realtime T_PDV      = 5ns,      // PCLK falling edge to data valid (Table 4)
    parameter int      MAX_FRAME_MSGS = 4     // per-frame messages after this many are silent
) (
    input  logic       xclk,
    input  logic       reset_n,
    input  logic       pwdn,
    input  logic [7:0] regs [0:255],
    input  realtime    t_last_reset,
    output logic       pclk,
    output logic       vsync,
    output logic       href,
    output logic [7:0] d,
    // the scene
    input  int         scene_mode,     // 0 bars+ramp, 1 shapes, 2 chequerboard, 3 barcode (when SCENE_FILE == "")
    input  int         scene_x0,       // pan, in array pixels (wraps)
    input  int         scene_y0,
    input  logic [7:0] scene_code,     // the barcode's value in mode 3
    // observation hooks
    output int         frames_done,
    output int         out_w,          // output resolution under the current registers
    output int         out_h,
    output real        pclk_hz,
    output real        fps,
    output int         cur_col,        // output pixel being driven (-1 in blanking)
    output int         cur_row,
    output logic       xclk_running
);
    import ov7670_pkg::*;

    localparam int ARRAY_W = 656, ARRAY_H = 488;   // p.3: 656 x 488 total, 640 x 480 active
    localparam int MARGIN_X = 8, MARGIN_Y = 4;     // where the default window sits on the array
    localparam int DEF_HSTART = 160, DEF_VSTART = 12;   // the window at HSTART 160 (the course's list) is on the central 640 columns
    localparam int LINE_SLOTS = 784, FRAME_LINES = 510, VSYNC_LINES = 3, FIRST_ACTIVE_LINE = 20;
    // Measured on a board (FIDELITY), in half-slots from the start of a line (VGA PCLKs at 40 MHz): no HREF from 207
    // to 273, the first pixels after that white up to 286, and on the window's first line no HREF before 139.
    // Readout rows from 496 on are never sent.
    localparam int HS_GAP_LO = 207, HS_GAP_HI = 274, HS_WHITE_HI = 287, HS_GATE = 139, READ_ROWS = 496;

    // ---- XCLK measurement ----------------------------------------------------
    realtime t_xclk = 40ns, t_xclk_last = 0;
    int xclk_edges = 0, xclk_edges_seen = 0;
    always @(posedge xclk) begin
        if (t_xclk_last != 0) t_xclk = $realtime - t_xclk_last;
        t_xclk_last = $realtime;
        xclk_edges++;
    end
    initial xclk_running = 1'b0;
    always begin
        #(1us);
        xclk_running = (xclk_edges != xclk_edges_seen);
        xclk_edges_seen = xclk_edges;
    end
    bit warned_xclk_range = 0;
    real f_xclk_mhz;
    always @(posedge xclk_running) begin
        f_xclk_mhz = 1e3 / (t_xclk / 1ns);
        if ((f_xclk_mhz < 10.0 || f_xclk_mhz > 48.0) && !warned_xclk_range) begin
            warned_xclk_range = 1;
            $display("[OV7670-VIDEO @%0t] XCLK = %0.3f MHz is outside the 10-48 MHz input range (Table 4 p.6).", $time, f_xclk_mhz);
        end
    end

    // ---- the scene -------------------------------------------------------------
    logic [23:0] scene_mem [0:SCENE_W*SCENE_H-1];
    initial if (SCENE_FILE != "") begin
        $readmemh(SCENE_FILE, scene_mem);
        $display("[OV7670-VIDEO] scene: %s (%0d x %0d), shown on the %0d x %0d array", SCENE_FILE, SCENE_W, SCENE_H, ARRAY_W, ARRAY_H);
    end

    function automatic int wrap(input int v, input int n);
        int r = v % n; return (r < 0) ? r + n : r;
    endfunction

    // RGB888 of array pixel (ax, ay), 0..655 x 0..487.
    function automatic logic [23:0] scene_rgb(input int ax, input int ay);
        int x, y, bar, r, g, b;
        x = wrap(ax + scene_x0, ARRAY_W); y = wrap(ay + scene_y0, ARRAY_H);
        if (SCENE_FILE != "")
            return scene_mem[(y * SCENE_H / ARRAY_H) * SCENE_W + (x * SCENE_W / ARRAY_W)];
        case (scene_mode)
            0: begin  // eight colour bars over 3/4 of the height, a grey ramp below: the "world" version of the chip's test pattern
                if (y < 3 * ARRAY_H / 4) begin
                    bar = x * 8 / ARRAY_W;
                    case (bar) 0: return 24'hFFFFFF; 1: return 24'hFFFF00; 2: return 24'h00FFFF; 3: return 24'h00FF00;
                               4: return 24'hFF00FF; 5: return 24'hFF0000; 6: return 24'h0000FF; default: return 24'h000000; endcase
                end
                r = x * 255 / (ARRAY_W - 1); return {r[7:0], r[7:0], r[7:0]};
            end
            1: begin  // shapes: sky gradient, green ground, a red disc, a white square, a black post
                if ((x - 328) * (x - 328) + (y - 200) * (y - 200) < 60 * 60) return 24'hE02020;
                if (x >= 480 && x < 560 && y >= 120 && y < 200) return 24'hFFFFFF;
                if (x >= 100 && x < 116 && y >= 60 && y < 330) return 24'h101010;
                if (y >= 330) return 24'h30A030;
                b = 255; g = 120 + y * 120 / 330; r = 60 + y * 160 / 330;
                return {r[7:0], g[7:0], b[7:0]};
            end
            2: begin  // chequerboard, 32 px squares
                return (((x / 32) + (y / 32)) % 2) ? 24'hF0F0F0 : 24'h202020;
            end
            default: begin  // 3: a barcode on a white wall, bars 8 px (0) or 16 px (1) wide with 8 px gaps, as the A2 reader expects
                int bx = 120, i = 0;
                if (y < 100 || y >= 380) return 24'hE8E8E8;
                while (i < 8) begin
                    int w = scene_code[7 - i] ? 16 : 8;
                    if (x >= bx && x < bx + w) return 24'h101010;
                    bx += w + 8; i++;
                end
                return 24'hE8E8E8;
            end
        endcase
    endfunction

    function automatic logic [7:0] sat8(input int v);
        return (v < 0) ? 8'd0 : ((v > 255) ? 8'd255 : 8'(v));
    endfunction

    function automatic logic [23:0] with_noise(input logic [23:0] c);
        if (NOISE == 0) return c;
        return {sat8(int'(c[23:16]) + $urandom_range(0, 2 * NOISE) - NOISE),
                sat8(int'(c[15:8])  + $urandom_range(0, 2 * NOISE) - NOISE),
                sat8(int'(c[7:0])   + $urandom_range(0, 2 * NOISE) - NOISE)};
    endfunction

    // ---- the configuration, decoded from the registers -------------------------
    typedef enum int {FMT_YUV, FMT_RGB565, FMT_RGB555, FMT_RGB444_XRGB, FMT_RGB444_RGBX, FMT_GRB422, FMT_RAW} fmt_t;
    typedef struct {
        fmt_t fmt; int w, h; int pll, prescale; bit ext_clk, halve; int pclk_div; bit div_bad; bit raw;
        int scale, hscale; bit dcw;                 // COM7's QVGA 1, CIF 2, QCIF 3 (0 none); window pixels an output pixel; COM3[2]
        int hstart, hwidth, vstart, vheight, vlines; int dummy_px, advf, dmln;   // vlines: the window's lines the sensor sends
        bit mirror, flip, negative; int testpat;    // 0 none, 1 shifting 1, 2 bars, 3 fade-to-grey bars, 4 the DSP colour bar
        bit overlay;                                // COM7[1]: the colour bar overlaid on the picture
        int range_lo, range_hi; int uv_order;       // TSLB[3],COM13[0]
        bit pclk_gate, pclk_inv, href_inv, hsync_mode, vsync_neg, vsync_rise, hsync_neg;
        int hds, vds;
        int pshft;                                  // PSHFT: data delayed this many pixels relative to HREF
        int bright, contrast, centre; bit centre_auto, fx;   // BRIGHT as +-127, CONTRAS (64 = x1), CONTRAS-CENTER, MTXS[7]; fx: in use
        bit fixed_uv; logic [7:0] manu, manv;       // TSLB[4], MANU, MANV
    } cfg_t;

    cfg_t cfg;   // the register set as decoded at the last line start
    int ticks_per_pclk = 1, pclks_per_line = 1568, bpp = 2, k0 = 320, kw = 1280, frame_lines = 510;   // set by load_cfg
    int line0 = 18;                      // the frame's line on which the window's first line comes out
    int tail_k0 = 320, tail_kw = 1280, tail_ppl = 1568;   // the previous line's window: its pixels that run on into this line
    int luma_mean = 128;                 // the picture's mean luma, for contrast with MTXS[7]: the last frame's
    int mean_sum = 0, mean_n = 0;        // (40 x 30 of its pixels before contrast, summed as they go out)
    logic [23:0] last_base;              // picture_rgb()'s picture before contrast, for that sum

    // CIF and QCIF keep 290 of the window's 480 lines (QCIF: of its 240 line pairs). Which ones: a step of 309/512 a
    // line, fitted to the board's first 64 rows, its row count and its last line (FIDELITY). sr_row[a] is the output row
    // on window line (or pair) a, or -1; sr_line[r] is the line (or pair) of output row r.
    int sr_row [0:511], sr_line [0:511];
    int sr_key = -1, sr_count = 0;
    function automatic int scaled_rows(input int n, input bit qcif);
        int acc, key;
        key = 2 * n + int'(qcif);
        if (key != sr_key) begin
            sr_key = key; sr_count = 0; acc = qcif ? 210 : 226;
            for (int i = 0; i < 512; i++) sr_row[i] = -1;
            for (int i = 0; i < n && i < 512; i++) begin
                acc += 309;
                if (acc >= 512) begin acc -= 512; sr_row[i] = sr_count; sr_line[sr_count] = i; sr_count++; end
            end
        end
        return sr_count;
    endfunction

    function automatic cfg_t decode_cfg();
        cfg_t c;
        logic [7:0] com3 = regs[R_COM3], com7 = regs[R_COM7], com10 = regs[R_COM10], com14 = regs[R_COM14], com15 = regs[R_COM15];
        c.raw = com7[0];
        if (com7[0])            c.fmt = FMT_RAW;
        else if (!com7[2])      c.fmt = FMT_YUV;
        else if (regs[R_RGB444][1] && com15[4]) c.fmt = regs[R_RGB444][0] ? FMT_RGB444_RGBX : FMT_RGB444_XRGB;
        else if (com15[5:4] == 2'b01) c.fmt = FMT_RGB565;
        else if (com15[5:4] == 2'b11) c.fmt = FMT_RGB555;
        else                    c.fmt = FMT_GRB422;
        c.hstart = int'(regs[R_HSTART]) * 8 + int'(regs[R_HREF][2:0]);
        c.hwidth = wrap(int'(regs[R_HSTOP]) * 8 + int'(regs[R_HREF][5:3]) - c.hstart, LINE_SLOTS);
        c.vstart = int'(regs[R_VSTRT]) * 4 + int'(regs[R_VREF][1:0]);
        c.vheight = wrap(int'(regs[R_VSTOP]) * 4 + int'(regs[R_VREF][3:2]) - c.vstart, FRAME_LINES);
        c.vlines = (c.vheight < READ_ROWS - c.vstart) ? c.vheight : READ_ROWS - c.vstart;   // the readout ends at row 495 (measured)
        if (c.vlines < 0) c.vlines = 0;
        c.hds = 1 << regs[R_SCALING_DCWCTR][1:0]; c.vds = 1 << regs[R_SCALING_DCWCTR][5:4];
        // COM7's scaled modes, as measured on a board: the picture comes from the window, QVGA and CIF half its width and
        // QCIF a quarter of it less one pixel; QVGA takes every second line, CIF and QCIF the lines scaled_rows() picks
        c.scale = com7[5] ? 2 : (com7[4] ? 1 : (com7[3] ? 3 : 0));
        c.dcw = (c.scale == 0) && com3[2];
        c.hscale = (c.scale == 3) ? 4 : ((c.scale != 0) ? 2 : 1);
        if (c.scale == 1)      begin c.w = c.hwidth / 2;     c.h = c.vlines / 2; end
        else if (c.scale == 2) begin c.w = c.hwidth / 2;     c.h = scaled_rows(c.vlines, 1'b0); end
        else if (c.scale == 3) begin c.w = c.hwidth / 4 - 1; c.h = scaled_rows(c.vlines / 2, 1'b1); end
        else if (c.dcw)        begin c.w = 640 / c.hds; c.h = 480 / c.vds; end
        else                   begin c.w = 640; c.h = 480; end
        // the clock (measured on a board, FIDELITY): XCLK / the prescaler (none with CLKRC[6]) x the PLL, halved unless
        // CLKRC[7] or CLKRC[6] is set (Table 5 calls bit 7 reserved)
        c.pll = pll_factor(regs[R_DBLV]); c.ext_clk = regs[R_CLKRC][6];
        c.prescale = c.ext_clk ? 1 : int'(regs[R_CLKRC][5:0]) + 1;
        c.halve = !regs[R_CLKRC][7] && !regs[R_CLKRC][6];
        c.div_bad = com14[4] && com14_div(com14) == 0;                  // COM14[2:0] = 101..111: "not allowed"
        if (com14[4]) c.pclk_div = c.div_bad ? 1 : com14_div(com14);   // COM14's own divider ...
        else          c.pclk_div = (c.scale == 3) ? 4 : ((c.scale != 0) ? 2 : 1);   // ... else the scaled modes divide PCLK themselves (measured)
        c.dummy_px = int'(regs[R_EXHCH][7:4]) * 256 + int'(regs[R_EXHCL]);
        c.advf = int'(regs[R_ADVFH]) * 256 + int'(regs[R_ADVFL]);
        c.dmln = int'(regs[R_DM_LNH]) * 256 + int'(regs[R_DM_LNL]);
        c.mirror = regs[R_MVFP][5]; c.flip = regs[R_MVFP][4]; c.negative = regs[R_TSLB][5];
        c.testpat = {regs[R_SCALING_YSC][7], regs[R_SCALING_XSC][7]};  // the output stage's own patterns win
        if (c.testpat == 0 && regs[R_COM17][3]) c.testpat = 4;
        c.overlay = com7[1];
        case (com15[7:6]) 2'b10: begin c.range_lo = 1; c.range_hi = 254; end
                          2'b11: begin c.range_lo = 0; c.range_hi = 255; end
                          default: begin c.range_lo = 16; c.range_hi = 240; end endcase
        c.uv_order = {regs[R_TSLB][3], regs[R_COM13][0]};
        c.pclk_gate = com10[5]; c.pclk_inv = com10[4]; c.href_inv = com10[3]; c.hsync_mode = com10[6];
        c.vsync_neg = com10[1]; c.vsync_rise = com10[2]; c.hsync_neg = com10[0];
        c.pshft = int'(regs[R_PSHFT]);
        c.bright = regs[R_BRIGHT][7] ? -int'(regs[R_BRIGHT][6:0]) : int'(regs[R_BRIGHT][6:0]);   // sign and size (as the Linux driver writes it)
        c.contrast = int'(regs[R_CONTRAS]);
        c.centre = int'(regs[R_CONTRAS_CENTER]); c.centre_auto = regs[R_MTXS][7];          // MTXS[7]: the chip sets the centre itself
        c.fx = (c.bright != 0) || (c.contrast != 64);
        c.fixed_uv = regs[R_TSLB][4]; c.manu = regs[R_MANU]; c.manv = regs[R_MANV];
        return c;
    endfunction

    function automatic string fmt_name(input fmt_t f);
        case (f)
            FMT_YUV: return "YUV 4:2:2"; FMT_RGB565: return "RGB565"; FMT_RGB555: return "RGB555";
            FMT_RGB444_XRGB: return "RGB444 (xR GB)"; FMT_RGB444_RGBX: return "RGB444 (RG Bx)";
            FMT_GRB422: return "GRB 4:2:2 (\"normal RGB\")"; default: return "raw Bayer";
        endcase
    endfunction

    // ---- pixel conversion ---------------------------------------------------------
    // `cfg` (below) is the decoded register set, reloaded at every line start. The functions read it
    // directly rather than taking it as an argument: a struct argument is copied on every call, and
    // these run once per byte.
    function automatic logic [7:0] ranged(input logic [7:0] v);
        return 8'(cfg.range_lo + (int'(v) * (cfg.range_hi - cfg.range_lo) + 127) / 255);
    endfunction

    function automatic logic [7:0] luma(input logic [23:0] p);    // Y, ITU-R BT.601 (the same sum as the YUV output below)
        return sat8((77 * int'(p[23:16]) + 150 * int'(p[15:8]) + 29 * int'(p[7:0])) >> 8);
    endfunction

    // The "shifting 1" test pattern, as measured on a board: byte k of the line has its single 1 on pin ((k + 1) / 2)
    // mod 8, so each pin is held for two bytes: 01 02 02 04 04 ... 80 80 01 01 02 ... (Raw Bayer: our extension.)
    function automatic logic [15:0] shifting_one(input int col);
        int n = cfg.raw ? col : 2 * col;                               // the byte's place in the line
        return cfg.raw ? {8'(1 << (((n + 1) >> 1) % 8)), 8'h00} : {8'(1 << (((n + 1) >> 1) % 8)), 8'(1 << (((n + 2) >> 1) % 8))};
    endfunction

    // ---- the estimated stages: gains, gamma and the colour matrix ("Estimated" in FIDELITY, in the header) ------
    // The scene is the picture the course's register list gives, so these stages show only a change from that list
    // (ov7670_pkg::est_ref); a register the design has not written keeps its Table 5 default, as on the chip. Each scene
    // colour is taken back to what the chip had before the matrix (the curved sensor colour that the course's matrix
    // turns into this colour), back through the course's curve to the light, through the gains, the new curve and
    // the new matrix. The tables are rebuilt only when one of their registers, or the output format, changes, and
    // the stages run only when something differs from the reference (est_on): with the course's list every pixel
    // is exactly as it was.
    bit           est_on  = 1'b0;          // the gains, the curve or the matrix differ from the reference
    bit           est_lut = 1'b0;          // the gains or the curve differ (else only the matrix: one 3x3, est_t)
    bit           est_mtx = 1'b0;          // the matrix differs (never for raw Bayer: one colour a pixel)
    int           est_t [0:8];             // matrix only: output = est_t x scene colour, x 65536
    int           est_kin [0:8];           // scene colour -> the curved sensor colour (x 65536)
    int           est_kout [0:8];          // the new curved sensor colour -> output colour (x 65536)
    int           est_lutf [0:2][0:256];   // R, G, B: sensor value -> through the course's curve back, gains, new curve (x 256)
    real          est_lin [0:255];         // the light each value stands for: the course's curve, inverted
    logic [255:0] est_sig = '1;            // the registers and format the tables were built for
    string        est_desc = "";           // for the "output:" line
    localparam int GAM_IN [0:15] = '{0, 4, 8, 16, 32, 40, 48, 56, 64, 72, 80, 96, 112, 144, 176, 208};  // GAM1..15's inputs (Table 5)

    function automatic logic [7:0] est_reg(input logic [7:0] a);   // the chip's value, as an SCCB read returns it
        return regs[a];
    endfunction

    // Table 5's gamma curve at input x (0..255), from g[0] = SLOP and g[1..15] = GAM1..15: straight lines through
    // (0,0), (4,GAM1) ... (208,GAM15), then SLOP/64 per input step above 208.
    function automatic real gamma_curve(input real x, input logic [7:0] g [0:15]);
        /*verilator no_inline_task*/   // (out of line, as decode(): see the package)
        for (int i = 1; i < 16; i++)
            if (x <= real'(GAM_IN[i])) begin
                real y0 = (i == 1) ? 0.0 : real'(g[i - 1]);
                return y0 + (x - real'(GAM_IN[i - 1])) * (real'(g[i]) - y0) / real'(GAM_IN[i] - GAM_IN[i - 1]);
            end
        return real'(g[15]) + (x - 208.0) * real'(g[0]) / 64.0;
    endfunction

    // Its inverse, for a curve that rises (the reference curve, Table 5's default, does).
    function automatic real gamma_inverse(input real y, input logic [7:0] g [0:15]);
        /*verilator no_inline_task*/
        for (int i = 1; i < 16; i++) begin
            real y0 = (i == 1) ? 0.0 : real'(g[i - 1]), y1 = real'(g[i]);
            if (y <= y1 && y1 > y0) return real'(GAM_IN[i - 1]) + (y - y0) * real'(GAM_IN[i] - GAM_IN[i - 1]) / (y1 - y0);
        end
        return (g[0] == 0) ? 255.0 : 208.0 + (y - real'(g[15])) * 64.0 / real'(g[0]);
    endfunction

    // 3 x 3 matrices, row by row in [0:8]: element k of the inverse of a, and of the product a b.
    function automatic real inv3(input real a [0:8], input int k);
        /*verilator no_inline_task*/
        real det;
        det = a[0] * (a[4] * a[8] - a[5] * a[7]) - a[1] * (a[3] * a[8] - a[5] * a[6]) + a[2] * (a[3] * a[7] - a[4] * a[6]);
        case (k)
            0: return (a[4] * a[8] - a[5] * a[7]) / det;   1: return (a[2] * a[7] - a[1] * a[8]) / det;   2: return (a[1] * a[5] - a[2] * a[4]) / det;
            3: return (a[5] * a[6] - a[3] * a[8]) / det;   4: return (a[0] * a[8] - a[2] * a[6]) / det;   5: return (a[2] * a[3] - a[0] * a[5]) / det;
            6: return (a[3] * a[7] - a[4] * a[6]) / det;   7: return (a[1] * a[6] - a[0] * a[7]) / det;   default: return (a[0] * a[4] - a[1] * a[3]) / det;
        endcase
    endfunction
    function automatic real mul3(input real a [0:8], input real b [0:8], input int k);
        /*verilator no_inline_task*/
        return a[3 * (k / 3)] * b[k % 3] + a[3 * (k / 3) + 1] * b[3 + k % 3] + a[3 * (k / 3) + 2] * b[6 + k % 3];
    endfunction

    function automatic real gfix_gain(input logic [1:0] b);          // GFIX: 1x, 1.25x, 1.5x, 1.75x
        return 1.0 + 0.25 * real'(b);
    endfunction

    function automatic int iround(input real r);                     // to the nearest whole number
        return (r >= 0.0) ? $rtoi(r + 0.5) : -$rtoi(0.5 - r);
    endfunction

    initial begin
        logic [7:0] rg [0:15];
        logic [7:0] com13;
        com13 = est_ref(R_COM13);
        for (int i = 0; i < 16; i++) rg[i] = est_ref(8'(8'h7A + i));
        for (int v = 0; v < 256; v++) est_lin[v] = com13[7] ? gamma_inverse(real'(v), rg) : real'(v);
    end

    // Rebuild the tables if a register they read, or the output format, has changed. Called at every line start.
    task automatic est_update();      // (called from one place, so Verilator inlines it once)
        logic [255:0] sig;
        logic [7:0] g [0:15];
        logic [7:0] com8, com13, com16, reg74, gfix, mtxs, ref_com13, ref_com16, ref_mtxs;
        real gain [0:3];                                              // R, G, B, and the digital gain
        real bin [0:8], ac [0:8], an [0:8], ai [0:8], bi [0:8], kin [0:8], kout [0:8];
        real y, x, w0, w1, w2;
        int m, mr;
        bit curve_same, gains_one, gamma_on, ref_gamma_on;
        string parts;
        sig = '0;
        for (int i = 0; i < 16; i++) begin g[i] = est_reg(8'(8'h7A + i)); sig[8 * i +: 8] = g[i]; end
        com8 = est_reg(R_COM8); com13 = est_reg(R_COM13); com16 = est_reg(R_COM16); reg74 = est_reg(R_REG74);
        gfix = est_reg(R_GFIX); mtxs = est_reg(R_MTXS);
        sig[255:128] = {8'(cfg.raw ? 2 : ((cfg.fmt == FMT_YUV) ? 1 : 0)), com8, com13, com16, reg74, est_reg(R_BLUE), est_reg(R_RED), gfix, mtxs,
                        est_reg(R_MTX1), est_reg(R_MTX2), est_reg(R_MTX3), est_reg(R_MTX4), est_reg(R_MTX5), est_reg(R_MTX6), est_reg(R_GGAIN)};
        if (sig == est_sig) return;
        est_sig = sig;
        ref_com13 = est_ref(R_COM13); ref_com16 = est_ref(R_COM16); ref_mtxs = est_ref(R_MTXS);
        // the gains, on the light: GFIX (G takes the mean of Gr and Gb), REG74's digital gain, and BLUE, RED and GGAIN
        // as fixed gains while AWB is off, relative to the course's values (GGAIN measured on a board: 0x40 is x1)
        gain[0] = gfix_gain(gfix[3:2]); gain[1] = (gfix_gain(gfix[7:6]) + gfix_gain(gfix[5:4])) / 2.0; gain[2] = gfix_gain(gfix[1:0]);
        gain[3] = !reg74[4] ? 1.0 : ((reg74[1:0] == 2'b10) ? 2.0 : ((reg74[1:0] == 2'b11) ? 4.0 : 1.0));   // 00 bypass, 01 1x
        if (!com8[1]) begin
            gain[0] = gain[0] * real'(est_reg(R_RED)) / real'(est_ref(R_RED));
            gain[1] = gain[1] * real'(est_reg(R_GGAIN)) / real'(est_ref(R_GGAIN));
            gain[2] = gain[2] * real'(est_reg(R_BLUE)) / real'(est_ref(R_BLUE));
        end
        for (int c = 0; c < 3; c++) gain[c] = gain[c] * gain[3];
        gains_one = (gain[0] == 1.0) && (gain[1] == 1.0) && (gain[2] == 1.0);
        // the curve: each sensor value back through the course's curve to the light, the gains (clipped at full
        // scale), then the new curve (or none)
        gamma_on = com13[7]; ref_gamma_on = ref_com13[7];
        curve_same = 1'b1;
        for (int i = 0; i < 16; i++) if (g[i] != est_ref(8'(8'h7A + i))) curve_same = 1'b0;
        est_lut = !(gains_one && curve_same && gamma_on == ref_gamma_on);
        if (est_lut)
            for (int c = 0; c < 3; c++)
                for (int v = 0; v < 257; v++) begin
                    x = ((v < 256) ? est_lin[v] : est_lin[255]) * gain[c];
                    if (x > 255.0) x = 255.0;
                    y = gamma_on ? gamma_curve(x, g) : x;
                    est_lutf[c][v] = iround(y * 256.0);
                end
        // the colour matrix: rows V (MTX1..3) and U (MTX4..6) over R', G', B', 128 = x1, signs in MTXS[5:0], doubled by
        // COM16[1]. With Table 5's luma weights as a third row, the course's two rows give a 3x3 that has an inverse,
        // so a scene colour gives the curved sensor colour (R', G', B') that the course's list turns into it. In RGB
        // output the rows give R - Y and B - Y; in YUV output V and U (BT.601).
        w0 = 0.299; w1 = 0.587; w2 = 0.114;
        if (cfg.fmt != FMT_YUV) bin = '{w0, w1, w2,  1.0 - w0, -w1, -w2,  -w0, -w1, 1.0 - w2};          // Y, R - Y, B - Y
        else bin = '{w0, w1, w2,  0.5, -0.5 * w1 / (1.0 - w0), -0.5 * w2 / (1.0 - w0),  -0.5 * w0 / (1.0 - w2), -0.5 * w1 / (1.0 - w2), 0.5};   // Y, V, U
        ac = '{w0, w1, w2, 0, 0, 0, 0, 0, 0}; an = '{w0, w1, w2, 0, 0, 0, 0, 0, 0};
        est_mtx = 1'b0;
        for (int i = 0; i < 6; i++) begin
            m  = int'(est_reg(8'(R_MTX1 + i))) * (mtxs[i] ? -1 : 1) * (com16[1] ? 2 : 1);
            mr = int'(est_ref(8'(R_MTX1 + i))) * (ref_mtxs[i] ? -1 : 1) * (ref_com16[1] ? 2 : 1);
            an[3 + i] = real'(m) / 128.0; ac[3 + i] = real'(mr) / 128.0;
            if (m != mr && !cfg.raw) est_mtx = 1'b1;
        end
        for (int k = 0; k < 9; k++) begin ai[k] = inv3(ac, k); bi[k] = inv3(bin, k); end
        for (int k = 0; k < 9; k++) begin
            kin[k]  = cfg.raw ? ((k % 4 == 0) ? 1.0 : 0.0) : mul3(ai, bin, k);   // raw Bayer: no matrix either way
            kout[k] = cfg.raw ? ((k % 4 == 0) ? 1.0 : 0.0) : mul3(bi, (est_mtx ? an : ac), k);
        end
        for (int k = 0; k < 9; k++) begin
            est_kin[k] = iround(kin[k] * 65536.0); est_kout[k] = iround(kout[k] * 65536.0);
            est_t[k] = iround(mul3(kout, kin, k) * 65536.0);
        end
        est_on = est_lut || est_mtx;
        parts = "";
        if (gamma_on != ref_gamma_on) parts = gamma_on ? "gamma on" : "gamma off";
        else if (gamma_on && !curve_same) parts = "gamma curve changed";
        if (!gains_one) parts = {parts, pick(parts == "", "", ", "), $sformatf("gains R x%0.2f, G x%0.2f, B x%0.2f", gain[0], gain[1], gain[2])};
        if (est_mtx) parts = {parts, pick(parts == "", "", ", "), "colour matrix changed"};
        est_desc = est_on ? {", estimated: ", parts} : "";
    endtask

    // The estimated stages on one scene colour.
    function automatic logic [23:0] estimated(input logic [23:0] p);
        int r, g, b, q, i;
        int s [0:2];
        longint o0, o1, o2;
        r = int'(p[23:16]); g = int'(p[15:8]); b = int'(p[7:0]);
        if (!est_lut)                                                   // the matrix only: one 3x3
            return {sat8((est_t[0] * r + est_t[1] * g + est_t[2] * b + 32768) >>> 16),
                    sat8((est_t[3] * r + est_t[4] * g + est_t[5] * b + 32768) >>> 16),
                    sat8((est_t[6] * r + est_t[7] * g + est_t[8] * b + 32768) >>> 16)};
        for (int c = 0; c < 3; c++) begin                               // the curved sensor value, x 256, through the table
            q = (est_kin[3 * c] * r + est_kin[3 * c + 1] * g + est_kin[3 * c + 2] * b + 128) >>> 8;
            q = (q < 0) ? 0 : ((q > 255 * 256) ? 255 * 256 : q);
            i = q >>> 8;
            s[c] = est_lutf[c][i] + (((est_lutf[c][i + 1] - est_lutf[c][i]) * (q & 255)) >>> 8);
        end
        o0 = longint'(est_kout[0]) * s[0] + longint'(est_kout[1]) * s[1] + longint'(est_kout[2]) * s[2];
        o1 = longint'(est_kout[3]) * s[0] + longint'(est_kout[4]) * s[1] + longint'(est_kout[5]) * s[2];
        o2 = longint'(est_kout[6]) * s[0] + longint'(est_kout[7]) * s[1] + longint'(est_kout[8]) * s[2];
        return {sat8(int'((o0 + 64'sd8388608) >>> 24)), sat8(int'((o1 + 64'sd8388608) >>> 24)), sat8(int'((o2 + 64'sd8388608) >>> 24))};
    endfunction

    // ---- the picture: measured on a board (FIDELITY) where it says so ------------------------------------------------
    // The colour bars' colours, as they come out in RGB565 (8-bit): the 8-bar colour bar of SCALING_YSC[7] (and of the
    // fade, which starts from it), and COM17[3]'s DSP colour bar. Both run white, yellow, cyan, green, magenta, red,
    // blue, black, 654 pixels for the eight, from 23 pixels before the course's window's first column.
    function automatic logic [23:0] bar_colour(input int bar, input bit dsp);
        /*verilator no_inline_task*/
        case ({dsp, 3'(bar)})
            4'd0:  return 24'hFFFBFF;  4'd1:  return 24'hDEF75A;  4'd2:  return 24'h29E7F7;  4'd3:  return 24'h08F308;
            4'd4:  return 24'hEF08EF;  4'd5:  return 24'hCE1408;  4'd6:  return 24'h18049C;  4'd7:  return 24'h000000;
            4'd8:  return 24'hD6CFE7;  4'd9:  return 24'hB5D331;  4'd10: return 24'h10D3DE;  4'd11: return 24'h00E300;
            4'd12: return 24'hEF04EF;  4'd13: return 24'hCE1021;  4'd14: return 24'h3114AD;  default: return 24'h101418;
        endcase
    endfunction
    function automatic int bar_at(input int q);                        // the bar at readout column q (the course's window: 0..639)
        return wrap(q + 23, 654) * 8 / 654;
    endfunction

    // The fade: down the frame each bar moves towards a light grey, (166, 205, 206), by fade_k / 256 (every 24 rows,
    // straight lines between), and the fade starts again every 376 rows.
    localparam int FADE_K [0:16] = '{0, 5, 20, 41, 61, 87, 105, 128, 148, 164, 182, 195, 210, 225, 236, 243, 243};
    function automatic logic [23:0] faded(input logic [23:0] c, input int row);
        int r = wrap(row, 376), i = r / 24, k;
        k = FADE_K[i] + (FADE_K[i + 1] - FADE_K[i]) * (r % 24) / 24;
        return {8'((int'(c[23:16]) * (256 - k) + 166 * k) >> 8), 8'((int'(c[15:8]) * (256 - k) + 205 * k) >> 8),
                8'((int'(c[7:0]) * (256 - k) + 206 * k) >> 8)};
    endfunction

    // COM7[1]'s colour bar is an overlay: in each of 8 bars of 80 pixels (white, yellow, ... black, turned round with the
    // picture), a channel that is in the bar's colour becomes a x + b, and one that is not c x + d (fitted, FIDELITY).
    function automatic logic [23:0] overlaid(input logic [23:0] p, input int wc_mirrored);
        int bar = wrap(wc_mirrored, 640) / 80, ch [0:2];
        logic [2:0] on;
        case (bar) 0: on = 3'b111; 1: on = 3'b110; 2: on = 3'b011; 3: on = 3'b010; 4: on = 3'b101; 5: on = 3'b100; 6: on = 3'b001; default: on = 3'b000; endcase
        ch[0] = on[2] ? ((181 * int'(p[23:16])) >>> 8) + 69 : ((222 * int'(p[23:16])) >>> 8) - 7;
        ch[1] = on[1] ? ((188 * int'(p[15:8]))  >>> 8) + 61 : ((224 * int'(p[15:8]))  >>> 8) - 11;
        ch[2] = on[0] ? ((147 * int'(p[7:0]))   >>> 8) + 91 : ((201 * int'(p[7:0]))   >>> 8) - 7;
        return {sat8(ch[0]), sat8(ch[1]), sat8(ch[2])};
    endfunction

    // Readout rows above the picture: rows 2..9 are not image, and row 10 is dark blue (a window from row 10, as the Linux
    // driver's VREF 0x0A gives, shows it as a line along the top: the course's window starts at row 11).
    // Measured with the course's mirror and flip on, every second row (rows 3, 5, 7 and 9 are taken to match the row
    // above them); rows 0 and 1 are a guess.
    function automatic logic [23:0] artefact_row(input int rr);
        if (rr >= 10) return 24'h08004A;
        if (rr >= 8)  return 24'hA5FFB5;
        if (rr >= 6)  return 24'h520000;
        return 24'h000000;
    endfunction

    // The window's row (in VGA lines) that output row `row` shows.
    function automatic int window_row(input int row);
        case (cfg.scale)
            1: return 2 * row + 1;
            2: return (row >= 0 && row < 512) ? sr_line[row] : row;
            3: return (row >= 0 && row < 512) ? 2 * sr_line[row] + 1 : row;
            default: return cfg.dcw ? row * 480 / cfg.h : row;
        endcase
    endfunction

    // The picture before the picture controls, for output pixel (col,row): the window is placed on the readout, which
    // the sensor has already mirrored and flipped, so moving the window moves the picture the same way with or without
    // them (measured). Then: rows above the picture, white columns just after the gap, the scene (columns and rows past
    // the array's edge repeat its last ones), the estimated stages and COM7[1]'s overlay; or COM17[3]'s colour bar.
    function automatic logic [23:0] picture_base(input int col, input int row);
        int c, wc, q, rr, ax, ay, hs;
        logic [23:0] px;
        c = col - cfg.pshft;                                            // PSHFT: the data comes this many pixels late
        wc = cfg.dcw ? c * 640 / cfg.w : c * cfg.hscale;                // the window's column, in VGA pixels
        q = wc + (cfg.hstart - DEF_HSTART);                             // the readout's column (the course's window: 0..639)
        if (cfg.testpat == 4) return bar_colour(bar_at(q), 1'b1);
        rr = window_row(row) + cfg.vstart;                              // the readout's row (the course's window: 11..490)
        if (rr < 11) return artefact_row(rr);
        hs = wrap((k0 + col * bpp) * ticks_per_pclk, pclks_per_line * ticks_per_pclk);   // where the pixel is in the line
        if (hs >= HS_GAP_HI && hs < HS_WHITE_HI) return 24'hFFFFFF;
        ax = cfg.mirror ? (MARGIN_X + 639 - q) : (MARGIN_X + q);        // the course's window is on the central 640 x 480
        ay = cfg.flip ? (479 - (rr - DEF_VSTART)) : (MARGIN_Y + rr - DEF_VSTART);
        ax = (ax < 0) ? 0 : ((ax >= ARRAY_W) ? ARRAY_W - 1 : ax);
        ay = (ay < 0) ? 0 : ((ay >= ARRAY_H) ? ARRAY_H - 1 : ay);
        px = with_noise(scene_rgb(ax, ay));
        if (est_on) px = estimated(px);                                 // gains, gamma and matrix: estimated
        if (cfg.overlay) px = overlaid(px, cfg.mirror ? 639 - wc : wc);
        return px;
    endfunction

    // The picture's RGB for output pixel (col,row), before fixed U/V: an output-stage test pattern (shifting 1, the
    // bars, the fade: nothing else applies to them), or the picture, then contrast and brightness, then the negative.
    function automatic logic [23:0] picture_rgb(input int col, input int row);
        int y, dy, centre, wc;
        logic [23:0] px;
        if (cfg.testpat == 1) begin                                     // "shifting 1": the colour its bytes mean in RGB565
            logic [15:0] w = shifting_one(col);
            return {w[15:11], w[15:13], w[10:5], w[10:9], w[4:0], w[4:2]};
        end
        if (cfg.testpat == 2 || cfg.testpat == 3) begin
            wc = cfg.dcw ? col * 640 / cfg.w : col * cfg.hscale;
            px = bar_colour(bar_at(wc + cfg.hstart - DEF_HSTART), 1'b0);
            return (cfg.testpat == 3) ? faded(px, window_row(row)) : px;
        end
        px = picture_base(col, row);
        last_base = px;
        if (cfg.fx) begin                                               // on the luma: R, G and B all move by the same amount
            y = int'(luma(px));
            centre = cfg.centre_auto ? luma_mean : cfg.centre;
            dy = centre + (y - centre) * cfg.contrast / 64 + cfg.bright - y;
            px = {sat8(int'(px[23:16]) + dy), sat8(int'(px[15:8]) + dy), sat8(int'(px[7:0]) + dy)};
        end
        if (cfg.negative) px = ~px;                                     // the negative comes after brightness (measured)
        return px;
    endfunction

    // Fixed U/V (TSLB[4]). In RGB output, measured on a board: R becomes MANV and B becomes MANU, and G is kept. In YUV
    // output the U and V bytes are MANU and MANV (pixel_word); the RGB here keeps the luma (BT.601), a guess.
    function automatic logic [23:0] with_fixed_uv(input logic [23:0] p);
        int y, u, v;
        if (cfg.fmt != FMT_YUV) return {cfg.manv, p[15:8], cfg.manu};
        y = int'(luma(p)); u = int'(cfg.manu) - 128; v = int'(cfg.manv) - 128;
        return {sat8(y + ((359 * v) >>> 8)), sat8(y - ((88 * u + 183 * v) >>> 8)), sat8(y + ((454 * u) >>> 8))};
    endfunction

    // Fixed U/V applies to the picture and to COM17[3]'s bar, not to the output stage's patterns.
    function automatic bit uses_fixed_uv();
        return cfg.fixed_uv && (cfg.testpat == 0 || cfg.testpat == 4);
    endfunction

    // The RGB the chip has for output pixel (col,row): the picture, with fixed U/V when TSLB[4] is set.
    function automatic logic [23:0] pixel_rgb(input int col, input int row);
        logic [23:0] p = picture_rgb(col, row);
        return uses_fixed_uv() ? with_fixed_uv(p) : p;
    endfunction

    // The two bytes the chip puts on D[7:0] for output pixel (col,row), first byte in [15:8] (Figures 11-13, Table 5 TSLB).
    // Raw Bayer has one byte per pixel, returned in [15:8].
    function automatic logic [15:0] pixel_word(input int col, input int row);
        logic [23:0] p0, p;
        logic [7:0] r, g, bl, y, u, v;
        bit fixed;
        if (cfg.testpat == 1) return shifting_one(col);
        p0 = picture_rgb(col, row);
        fixed = uses_fixed_uv();
        p = fixed ? with_fixed_uv(p0) : p0;
        r = ranged(p[23:16]); g = ranged(p[15:8]); bl = ranged(p[7:0]);
        case (cfg.fmt)
            FMT_RGB565:      return {r[7:3], g[7:5], g[4:2], bl[7:3]};
            FMT_RGB555:      return {1'b0, r[7:3], g[7:6], g[5:3], bl[7:3]};
            FMT_RGB444_XRGB: return {4'h0, r[7:4], g[7:4], bl[7:4]};
            FMT_RGB444_RGBX: return {r[7:4], g[7:4], bl[7:4], 4'h0};
            FMT_GRB422:      return {g, (col % 2) ? r : bl};
            FMT_RAW: begin   // Bayer mosaic, BG/GR (the row/column parity is a modelling choice)
                if ((row % 2) == 0) return {(col % 2) ? g : bl, 8'h00};
                return {(col % 2) ? r : g, 8'h00};
            end
            default: begin   // YUV 4:2:2, ITU-R BT.601 from the chip's RGB; U with even pixels, V with odd (or per the order bits)
                if (fixed) begin r = ranged(p0[23:16]); g = ranged(p0[15:8]); bl = ranged(p0[7:0]); end   // Y as without TSLB[4]
                y = sat8((77 * int'(r) + 150 * int'(g) + 29 * int'(bl)) >> 8);
                u = fixed ? cfg.manu : sat8(((-43 * int'(r) - 85 * int'(g) + 128 * int'(bl)) >>> 8) + 128);   // >>>: these sums can be negative
                v = fixed ? cfg.manv : sat8(((128 * int'(r) - 107 * int'(g) - 21 * int'(bl)) >>> 8) + 128);
                case (cfg.uv_order)
                    2'b00: return {y, (col % 2) ? v : u};      // Y U Y V
                    2'b01: return {y, (col % 2) ? u : v};      // Y V Y U
                    2'b10: return {(col % 2) ? v : u, y};      // U Y V Y
                    default: return {(col % 2) ? u : v, y};    // V Y U Y
                endcase
            end
        endcase
    endfunction

    // Public hooks for testbenches: what the chip outputs for output pixel (col,row) under the current registers.
    function automatic logic [23:0] expected_rgb(input int col, input int row);
        return pixel_rgb(col, row);
    endfunction
    function automatic logic [15:0] expected_word(input int col, input int row);
        return pixel_word(col, row);
    endfunction
    function automatic logic [7:0] expected_grey(input int col, input int row);
        logic [23:0] p = pixel_rgb(col, row);
        return sat8((77 * int'(p[23:16]) + 150 * int'(p[15:8]) + 29 * int'(p[7:0])) >> 8);
    endfunction

    // ---- the timing generator ------------------------------------------------------
    logic running, asleep;
    assign asleep  = regs[R_COM2][4];                               // COM2[4], soft sleep: the video port stops, the SCCB still works
    assign running = reset_n && !pwdn && xclk_running && !asleep;

    string last_cfg_desc = "";
    int line = 0, k = 0;                 // line in frame, PCLK index in line
    int kn, ln;                          // the next PCLK's position
    realtime t_int, t_pclk;
    logic pclk_int = 1'b0, href_int = 1'b0, vsync_int = 1'b0;
    logic href_act = 1'b0;               // pixels on D[7:0] now (HREF before COM10's reversal or HSYNC option)
    bit   slept = 0;                     // the port stopped for soft sleep
    int frames_started = 0;
    initial begin frames_done = 0; cur_col = -1; cur_row = -1; out_w = 640; out_h = 480; pclk_hz = 0; fps = 0; d = '0; end

    // The picture effects in use, for the "output:" line (empty when there are none).
    function automatic string effects_desc(input cfg_t c);
        return $sformatf("%s%s%s%s", pick(c.bright != 0, $sformatf(", brightness %s%0d", pick(c.bright > 0, "+", "-"), (c.bright > 0) ? c.bright : -c.bright), ""),
                         pick(c.contrast != 64, $sformatf(", contrast x%0.2f", real'(c.contrast) / 64.0), ""),
                         pick(c.fixed_uv, $sformatf(", fixed U/V %0d/%0d", c.manu, c.manv), ""),
                         pick(c.pshft != 0, $sformatf(", data %0d pixels late (PSHFT)", c.pshft), ""));
    endfunction

    function automatic string cfg_desc(input cfg_t c);
        string fx = "";
        bit picture = (c.testpat == 0), dsp = (c.testpat == 4);
        if ((picture || dsp) && (c.fx || c.fixed_uv || c.pshft != 0)) fx = effects_desc(c);
        if (picture) fx = {fx, est_desc};
        return $sformatf("%s %0dx%0d, PCLK = XCLK%s%s%s = %0.3f MHz, %0.1f fps (line %0.1f us, frame %0.2f ms)%s%s%s%s%s%s%s",
            fmt_name(c.fmt), c.w, c.h,
            {pick(c.pll > 1, $sformatf(" x %0d", c.pll), ""), pick(c.halve, " / 2", "")},
            pick(c.ext_clk, " (no prescaler)", pick(c.prescale > 1, $sformatf(" / %0d", c.prescale), "")),
            pick(c.raw || c.pclk_div > 1, $sformatf(" / %0d", (c.raw ? 2 : 1) * c.pclk_div), ""),
            pclk_hz / 1e6, fps, 1e6 / (fps * real'(frame_lines)), 1e3 / fps,
            pick(c.mirror && picture, ", mirrored", ""), pick(c.flip && picture, ", flipped", ""),     // the bars are not turned round
            pick(c.negative && (picture || dsp), ", negative", ""),
            fx,
            pick(c.overlay && picture, ", colour bar overlay (COM7[1])", ""),
            pick(c.testpat != 0, pick(c.testpat == 1, ", TEST PATTERN shifting-1", pick(c.testpat == 2, ", TEST PATTERN colour bars",
                 pick(c.testpat == 3, ", TEST PATTERN fade-to-grey bars", ", TEST PATTERN DSP colour bar"))), ""),
            pick(c.hwidth != 640 || c.vheight != 480, $sformatf(", window %0d columns x %0d rows from (%0d,%0d)", c.hwidth, c.vheight, c.hstart, c.vstart), ""));
    endfunction

    // Recompute everything derived from the registers (called at every line start).
    task automatic load_cfg();
        int lost;
        real f_pll;
        string desc;
        tail_k0 = k0; tail_kw = kw; tail_ppl = pclks_per_line;        // the chip fixes each line's window as the line starts
        cfg = decode_cfg();
        est_update();
        // XCLK / the prescaler (none with CLKRC[6]) x the PLL's factor, halved unless CLKRC[7] or CLKRC[6] (measured on a
        // board: FIDELITY)
        t_int = t_xclk * cfg.prescale * (cfg.halve ? 2 : 1) / cfg.pll;
        ticks_per_pclk = (cfg.raw ? 2 : 1) * cfg.pclk_div;
        t_pclk = t_int * ticks_per_pclk;
        bpp = cfg.raw ? 1 : 2;
        pclks_per_line = (LINE_SLOTS + cfg.dummy_px) * 2 / ticks_per_pclk;
        // the dummy lines (measured): ADVF's at the start of the frame, inside VSYNC; DM_LN's between VSYNC and the
        // window's first line
        frame_lines = FRAME_LINES + cfg.advf + cfg.dmln;
        line0 = FIRST_ACTIVE_LINE + (cfg.vstart - DEF_VSTART) + cfg.advf + cfg.dmln;
        // HREF rises 2 x HSTART half-slots into the line (measured), a PCLK later in QVGA and CIF and three in QCIF. A
        // window that runs past the line's end goes on into the next line.
        k0 = (cfg.hstart * 2) / ticks_per_pclk + ((cfg.scale == 3) ? 3 : ((cfg.scale != 0) ? 1 : 0));
        kw = cfg.w * bpp;                                             // PCLKs of the window's pixels
        if (cfg.hwidth < 640 && cfg.w == 640) kw = cfg.hwidth * bpp;  // a narrower window in VGA mode
        if (cfg.scale == 0) kw += cfg.dummy_px * bpp;                 // the dummy pixels come out inside HREF, at the end (measured)
        // what comes out: the pixels HREF covers on a line, and the rows
        out_w = kw / bpp;
        if (cfg.scale != 0) out_h = cfg.h;
        else if (cfg.dcw)   out_h = (cfg.vlines <= 0) ? 0 : ((cfg.h < (cfg.vlines - 1) * cfg.h / 480 + 1) ? cfg.h : (cfg.vlines - 1) * cfg.h / 480 + 1);
        else                out_h = (cfg.h < cfg.vlines) ? cfg.h : cfg.vlines;
        pclk_hz = 1e9 / (t_pclk / 1ns);
        fps = 1e9 / (t_pclk / 1ns) / real'(pclks_per_line) / real'(frame_lines);
        desc = cfg_desc(cfg);
        if (desc != last_cfg_desc) begin
            last_cfg_desc = desc;
            $display("[OV7670-VIDEO @%0t] output: %s", $time, last_cfg_desc);
            if (pclk_hz > 48.1e6) $display("[OV7670-VIDEO @%0t]   note: PCLK %0.1f MHz is above 48 MHz, the highest input clock in Table 4 (the datasheet gives no PCLK limit, and rates VGA at 30 fps), and leaves the FPGA's capture almost no timing margin.", $time, pclk_hz / 1e6);
            f_pll = 1e3 / (t_xclk / 1ns) / real'(cfg.prescale) * real'(cfg.pll);
            if (cfg.pll > 1 && f_pll > 60.5) $display("[OV7670-VIDEO @%0t]   note: the camera's PLL makes %0.1f MHz. On a board, 80 MHz (x8 from a 10 MHz XCLK) did not lock: PCLK wandered 1 to 5 %% fast, where 60 MHz (x6) and 40 MHz (x4) were exact. The model's clock is always exact.", $time, f_pll);
            lost = 0;
            for (int j = 0; j < kw; j++) begin
                int hs = wrap((k0 + j) * ticks_per_pclk, pclks_per_line * ticks_per_pclk);
                if (hs >= HS_GAP_LO && hs < HS_GAP_HI) lost++;
            end
            if (lost > 0) $display("[OV7670-VIDEO @%0t]   note: %0d bytes of each line of the window fall where the chip sends no HREF (%0d to %0d half-slots into the line, measured on a board) and do not come out.", $time, lost, HS_GAP_LO, HS_GAP_HI - 1);
            if (cfg.fmt == FMT_GRB422) $display("[OV7670-VIDEO @%0t]   note: COM15[5:4]=x0 with RGB output is \"normal RGB\" (GRB 4:2:2); most designs want RGB565 (COM15 = 0xD0).", $time);
            if (cfg.div_bad) $display("[OV7670-VIDEO @%0t]   WARNING: COM14[2:0] = %b is \"not allowed\" (Table 5); the model leaves PCLK undivided.", $time, regs[R_COM14][2:0]);
        end
    endtask

    // Which output row (if any) starts on active line a (0..vheight-1), for h output rows over 480 lines (COM3[2]'s
    // down-sampling).
    function automatic int row_for_line(input int a, input int h);
        if (h >= 480) return (a < h) ? a : -1;
        return ((a * h) % 480 < h) ? (a * h / 480) : -1;
    endfunction

    // The output row on line l of the frame, or -1. -2 is the readout row just above the window: the end of its pixels,
    // where they run on into the window's first line, comes out there (measured on a board).
    function automatic int row_on_line(input int l);
        int a = l - line0;
        if (a == -1) return (cfg.scale == 0 && !cfg.dcw) ? -2 : -1;
        if (a < 0 || a >= cfg.vlines) return -1;
        case (cfg.scale)
            1: return (a % 2 == 1 && (a - 1) / 2 < cfg.h) ? (a - 1) / 2 : -1;     // QVGA: the second line of each pair
            2: return sr_row[a];                                                   // CIF
            3: return (a % 2 == 1) ? sr_row[(a - 1) / 2] : -1;                     // QCIF: CIF's choice of the pairs
            default: return cfg.dcw ? row_for_line(a, cfg.h) : ((a < cfg.h) ? a : -1);
        endcase
    endfunction

    // The main loop: one iteration per output PCLK period. (When the chip starts, one pass with no edges reads the first
    // line's registers: new_line() has this one call, so that Verilator puts its code in the C++ once.)
    bit starting = 1'b0;
    always begin
        if (!running) begin
            pclk_int = 1'b0; href_int = 1'b0; href_act = 1'b0; vsync_int = 1'b0; d = '0; cur_col = -1; cur_row = -1;
            line = 0; k = 0; last_cfg_desc = "";
            slept = asleep && reset_n && !pwdn;
            if (slept) $display("[OV7670-VIDEO @%0t] soft sleep (COM2[4] = 1): PCLK, VSYNC, HREF and D[7:0] stop; the SCCB still works", $time);
            @(posedge running);
            if (slept) $display("[OV7670-VIDEO @%0t] out of soft sleep (COM2[4] = 0): a new frame starts", $time);
            else if (VERBOSE) $display("[OV7670-VIDEO @%0t] chip running: RESET# high, PWDN low, XCLK %0.3f MHz", $time, 1e3 / (t_xclk / 1ns));
            starting = 1'b1; kn = 0; ln = 0;
        end else begin
            // rising edge: the design samples what we put out after the previous falling edge
            pclk_int = 1'b1;
            if (cfg.vsync_rise) vsync_int = vsync_for(line);
            #(t_pclk / 2);
            // falling edge: move to the next PCLK and update the outputs tPDV later. Until then D[7:0] is changing
            // (Table 4: valid at most tPDV after the edge), so the model puts random bits on it.
            pclk_int = 1'b0;
            d = 8'($urandom);
            // (kn/ln are module-level: a variable declared with an initialiser inside a static process is
            //  initialised once, at time 0, not on every pass.)
            kn = k + 1; ln = line;
            if (kn >= pclks_per_line) begin
                kn = 0; ln = line + 1;
                if (ln >= frame_lines) begin ln = 0; frames_done++; end
            end
            #(T_PDV);
        end
        if (kn == 0) new_line(ln);           // the line's registers, before its first PCLK's outputs
        if (starting) starting = 1'b0;
        else begin
            drive_outputs(kn, ln);
            k = kn; line = ln;
            #(t_pclk / 2 - T_PDV);
        end
    end

    // A line starts: its registers, and at a frame's start the picture's mean luma (for MTXS[7]) and a message.
    task automatic new_line(input int line_no);
        load_cfg();
        if (line_no == 0) begin
            frames_started++;
            if (mean_n > 0) luma_mean = mean_sum / mean_n;              // MTXS[7]: the last frame's mean
            mean_sum = 0; mean_n = 0;
            if (frames_done > 0 && frames_done <= MAX_FRAME_MSGS && VERBOSE)
                $display("[OV7670-VIDEO @%0t] frame %0d done (%0d lines of %0d PCLK); frame %0d starts", $time, frames_done, frame_lines, pclks_per_line, frames_started);
        end
    endtask

    function automatic logic vsync_for(input int ln);
        return (ln < VSYNC_LINES + cfg.advf) ^ cfg.vsync_neg;          // ADVF's dummy lines lengthen VSYNC (measured)
    endfunction

    logic [15:0] word;   // the current pixel's two bytes
    task automatic drive_outputs(input int kn, input int ln);
        int j, row, col, b, hs;
        logic gate, in_href;
        hs = kn * ticks_per_pclk;                                       // half-slots into the line
        // the byte here: this line's row from k0 on, or the previous line's row running on past the line's end
        if (kn >= k0) begin j = kn - k0; row = (j < kw) ? row_on_line(ln) : -1; end
        else begin j = kn + tail_ppl - tail_k0; row = (j >= 0 && j < tail_kw) ? row_on_line(ln - 1) : -1; end
        // HREF (measured on a board): never in the gap at the start of a line; on the window's first line only from
        // HS_GATE on; on the line after its last only before the gap
        if (ln < line0 || ln > line0 + cfg.vlines) gate = 1'b0;
        else if (ln == line0)                       gate = (hs >= HS_GATE);
        else if (ln == line0 + cfg.vlines)          gate = (hs < HS_GAP_LO);
        else                                        gate = 1'b1;
        in_href = (row != -1) && gate && !(hs >= HS_GAP_LO && hs < HS_GAP_HI);
        href_act = in_href;
        if (!cfg.vsync_rise) vsync_int = vsync_for(ln);
        if (cfg.hsync_mode) begin
            // HSYNC: 45 tP wide, 80 tP after HREF would have fallen (Figure 6); negative if COM10[0]
            int hs0 = k0 + kw + 80 * 2 / ticks_per_pclk, hs1;
            hs1 = hs0 + 45 * 2 / ticks_per_pclk;
            href_int = ((kn >= hs0 && kn < hs1) ^ cfg.hsync_neg) ^ cfg.href_inv;
        end else
            href_int = in_href ^ cfg.href_inv;
        col = j / bpp; b = j % bpp;
        if (row != -1 && b == 0) word = pixel_word(col, (row == -2) ? -1 : row);   // (the word even when its first byte is lost)
        if (row >= 0 && b == 0 && col % 16 == 8 && row % 16 == 8 && !(cfg.testpat inside {[1:3]})) begin
            mean_sum += int'(luma(last_base)); mean_n++;                // MTXS[7]'s mean: 40 x 30 pixels of a VGA frame
        end
        if (in_href) begin
            d = (b == 0) ? word[15:8] : word[7:0];
            cur_col = col; cur_row = (row == -2) ? -1 : row;
        end else begin
            d = 8'h00; cur_col = -1; cur_row = -1;
        end
    endtask

    assign pclk  = (cfg.pclk_gate && !href_act) ? 1'b0 : (pclk_int ^ cfg.pclk_inv);   // COM10[5]: no PCLK while no pixels come out
    assign href  = href_int;
    assign vsync = vsync_int;

endmodule


/*
 * ----------------------------------------------------------------------------
 *  ov7670_model : the whole camera module (SCCB + registers + video port).
 * ----------------------------------------------------------------------------
 */
module ov7670_model #(
    parameter bit    VERBOSE    = 1,
    parameter string SCENE_FILE = "",
    parameter int    SCENE_W    = 656,
    parameter int    SCENE_H    = 488,
    parameter int    NOISE      = 0,
    parameter bit    ACK_ON_WRITE  = 1,
    parameter bit    STRICT_SETTLE = 1
) (
    // SCCB
    input  logic       sio_c,
    inout  wire        sio_d,
    // clock and control pins
    input  logic       xclk,
    input  logic       reset_n,
    input  logic       pwdn,
    // video port
    output logic       pclk,
    output logic       vsync,
    output logic       href,
    output logic [7:0] d,
    // the scene
    input  int         scene_mode,
    input  int         scene_x0,
    input  int         scene_y0,
    input  logic [7:0] scene_code,
    // hooks
    output int         frames_done,
    output int         write_count,
    output int         error_count
);
    import ov7670_pkg::*;

    logic [7:0] regs [0:255];
    int read_count, nack_count, dropped_count, reset_count;
    logic reg_written; logic [7:0] written_addr; realtime t_last_reset;
    int out_w, out_h, cur_col, cur_row; real pclk_hz, fps; logic xclk_running;

    ov7670_sccb_if #(.VERBOSE(VERBOSE), .ACK_ON_WRITE(ACK_ON_WRITE), .STRICT_SETTLE(STRICT_SETTLE)) ctrl (
        .sio_c, .sio_d, .reset_n, .pwdn, .xclk_running, .regs,
        .write_count, .read_count, .error_count, .nack_count, .dropped_count,
        .reg_written, .written_addr, .t_last_reset, .reset_count);

    ov7670_video #(.VERBOSE(VERBOSE), .SCENE_FILE(SCENE_FILE), .SCENE_W(SCENE_W), .SCENE_H(SCENE_H), .NOISE(NOISE)) video (
        .xclk, .reset_n, .pwdn, .regs, .t_last_reset, .pclk, .vsync, .href, .d,
        .scene_mode, .scene_x0, .scene_y0, .scene_code,
        .frames_done, .out_w, .out_h, .pclk_hz, .fps, .cur_col, .cur_row, .xclk_running);

    // Write a register as if it had arrived over the SCCB (for benches that test the video port alone).
    task automatic set_reg(input logic [7:0] a, input logic [7:0] v);
        ctrl.write_register(a, v);
    endtask

    // The rest of the course's register list (the camera project's rtl/ov7670_config.sv after its first 17 entries:
    // OmniVision's tuning values and the colour block, the same 61 values in the same order), written as set_reg
    // writes them. For a bench that sets the format and the window with set_reg: without these the chip keeps Table
    // 5's defaults, and its colour matrix gives about half the colour of the course's (FIDELITY in the header).
    localparam logic [15:0] COURSE_TUNING [0:60] = '{
        16'h1448, 16'h3DC0, 16'h0E61, 16'h0F4B, 16'h1602, 16'h2291, 16'h2907, 16'h330B, 16'h350B, 16'h371D, 16'h3871, 16'h392A, 16'h3C78,
        16'h4D40, 16'h4E20, 16'h7410, 16'h8D4F, 16'hB084, 16'hB10C, 16'hB20E, 16'hB382, 16'hB80A, 16'h5988, 16'h5A88, 16'h5B44, 16'h5C67,
        16'h5D49, 16'h5E0E, 16'h6C0A, 16'h6D55, 16'h6E11, 16'h6F9F, 16'h6A40, 16'h0140, 16'h0260, 16'h4F80, 16'h5080, 16'h5100, 16'h5222,
        16'h535E, 16'h5480, 16'h589E, 16'h4118, 16'h3F00, 16'h7505, 16'h76E1, 16'h4C00, 16'h7701, 16'h4B09, 16'hC960, 16'h5640, 16'h3411,
        16'hA488, 16'h9600, 16'h9730, 16'h9820, 16'h9930, 16'h9A84, 16'h9B29, 16'h9C03, 16'h7804};
    task automatic set_course_tuning();
        int n;
        n = $size(COURSE_TUNING);                        // (a variable bound: one copy of the write, not 61)
        for (int i = 0; i < n; i++) ctrl.write_register(COURSE_TUNING[i][15:8], COURSE_TUNING[i][7:0]);
    endtask

    // What the chip outputs for output pixel (col,row) under the current registers.
    function automatic logic [23:0] expected_rgb(input int col, input int row);  return video.expected_rgb(col, row);  endfunction
    function automatic logic [15:0] expected_word(input int col, input int row); return video.expected_word(col, row); endfunction
    function automatic logic [7:0]  expected_grey(input int col, input int row); return video.expected_grey(col, row); endfunction

    // The changes to the picture that are on (brightness, contrast, negative, fixed U/V, PSHFT); "" when none.
    function automatic string picture_changes();
        string s = "";
        if (regs[R_BRIGHT][6:0] != 0) s = {s, $sformatf(", brightness %s%0d (BRIGHT)", pick(regs[R_BRIGHT][7], "-", "+"), regs[R_BRIGHT][6:0])};
        if (regs[R_CONTRAS] != 8'h40) s = {s, $sformatf(", contrast x%0.2f (CONTRAS)", real'(regs[R_CONTRAS]) / 64.0)};
        if (regs[R_TSLB][5]) s = {s, ", negative image (TSLB[5])"};
        if (regs[R_TSLB][4]) s = {s, $sformatf(", fixed U/V %0d/%0d (TSLB[4], MANU, MANV)", regs[R_MANU], regs[R_MANV])};
        if (regs[R_PSHFT] != 0) s = {s, $sformatf(", data %0d pixels late (PSHFT)", regs[R_PSHFT])};
        if (s == "") return "";
        return s.substr(2, s.len() - 1);                                // without the first ", "
    endfunction

    task automatic print_summary();
        $display("---------------------------------------------------------------");
        $display("OV7670 model state at %0t: %0d register write(s) accepted, %0d read(s), %0d reset(s), %0d protocol error(s), %0d dropped write(s), %0d frame(s) output.",
                 $time, write_count, read_count, reset_count, error_count, dropped_count, frames_done);
        $display("  COM7   (0x12) = 0x%02X  %s", regs[R_COM7], decode(R_COM7, regs[R_COM7]));
        $display("  CLKRC  (0x11) = 0x%02X  %s", regs[R_CLKRC], decode(R_CLKRC, regs[R_CLKRC]));
        $display("  DBLV   (0x6B) = 0x%02X  %s", regs[R_DBLV], decode(R_DBLV, regs[R_DBLV]));
        $display("  COM14  (0x3E) = 0x%02X  %s", regs[R_COM14], decode(R_COM14, regs[R_COM14]));
        $display("  COM15  (0x40) = 0x%02X  %s", regs[R_COM15], decode(R_COM15, regs[R_COM15]));
        $display("  RGB444 (0x8C) = 0x%02X  %s", regs[R_RGB444], decode(R_RGB444, regs[R_RGB444]));
        $display("  TSLB   (0x3A) = 0x%02X  %s", regs[R_TSLB], decode(R_TSLB, regs[R_TSLB]));
        $display("  COM10  (0x15) = 0x%02X  %s", regs[R_COM10], decode(R_COM10, regs[R_COM10]));
        $display("  MVFP   (0x1E) = 0x%02X  %s", regs[R_MVFP], decode(R_MVFP, regs[R_MVFP]));
        if (regs[R_COM2][4]) $display("  COM2   (0x09) = 0x%02X  %s", regs[R_COM2], decode(R_COM2, regs[R_COM2]));
        if (picture_changes() != "") $display("  picture: %s", picture_changes());
        $display("  window: columns %0d..%0d (HSTART/HSTOP/HREF), rows %0d..%0d (VSTRT/VSTOP/VREF)",
                 int'(regs[R_HSTART]) * 8 + int'(regs[R_HREF][2:0]), int'(regs[R_HSTOP]) * 8 + int'(regs[R_HREF][5:3]),
                 int'(regs[R_VSTRT]) * 4 + int'(regs[R_VREF][1:0]), int'(regs[R_VSTOP]) * 4 + int'(regs[R_VREF][3:2]));
        $display("  => video port: %s", pick(video.last_cfg_desc == "", "not running (RESET#/PWDN/XCLK)", video.last_cfg_desc));
        $display("  => AEC %s, AGC %s, AWB %s (COM8); these only affect the real picture, not the model's", onoff(regs[R_COM8][0]), onoff(regs[R_COM8][2]), onoff(regs[R_COM8][1]));
        $display("---------------------------------------------------------------");
    endtask

    // Check the configuration against what the course's camera code expects: no test pattern, RGB565, VGA, full
    // range, free-running PCLK with default polarities and byte order, nothing dropped. Returns the number of problems.
    // The clock is noted here, not checked: the benches that care check it (ov7670_config_tb.sv does).
    function automatic int check_course_config(input bit expect_rgb565 = 1, input int expect_w = 640, input int expect_h = 480);
        int problems = 0;
        if (regs[R_COM7][1] || regs[R_COM17][3] || regs[R_SCALING_XSC][7] || regs[R_SCALING_YSC][7]) begin problems++; $display("  [config] a test pattern is enabled (COM7[1] / COM17[3] / SCALING_XSC[7] / SCALING_YSC[7]): the picture is the chip's colour bars, not the scene (COM7[1] lays them over it)."); end
        if (expect_rgb565) begin
            if (!regs[R_COM7][2] || regs[R_COM7][0]) begin problems++; $display("  [config] COM7 = 0x%02X: output is %s, expected RGB (COM7[2]=1, COM7[0]=0).", regs[R_COM7], pick(regs[R_COM7][0], "raw Bayer", "YUV")); end
            if (regs[R_COM15][5:4] != 2'b01) begin problems++; $display("  [config] COM15[5:4] = %b: expected 01 (RGB565).", regs[R_COM15][5:4]); end
            if (regs[R_RGB444][1]) begin problems++; $display("  [config] RGB444[1] = 1 overrides RGB565 with 12-bit RGB444."); end
            if (regs[R_COM15][7:6] != 2'b11) $display("  [config] note: COM15[7:6] = %b limits the output range (00-FF needs 11); not wrong, just less contrast.", regs[R_COM15][7:6]);
        end
        if (regs[R_COM2][4]) begin problems++; $display("  [config] COM2 = 0x%02X: soft sleep (bit 4) is on, so PCLK, VSYNC, HREF and D[7:0] have stopped.", regs[R_COM2]); end
        if (out_w != expect_w || out_h != expect_h) begin problems++; $display("  [config] output size is %0dx%0d, expected %0dx%0d (COM7[5:3], COM3, SCALING_DCWCTR, the window registers).", out_w, out_h, expect_w, expect_h); end
        if (regs[R_DBLV][7:6] != 2'b00) $display("  [config] note: PLL x%0d: PCLK = %0.1f MHz.", pll_factor(regs[R_DBLV]), pclk_hz / 1e6);
        if (!regs[R_CLKRC][7] && !regs[R_CLKRC][6]) $display("  [config] note: CLKRC = 0x%02X: bits 7 and 6 are clear, so the clock is halved (PCLK %0.1f MHz). The course's list keeps bit 7 set (0x80).", regs[R_CLKRC], pclk_hz / 1e6);
        if (regs[R_CLKRC][5:0] != 0 && !regs[R_CLKRC][6]) $display("  [config] note: CLKRC prescaler /%0d: PCLK = %0.1f MHz, %0.1f fps.", int'(regs[R_CLKRC][5:0]) + 1, pclk_hz / 1e6, fps);
        if (regs[R_COM10][5:0] != 0 || regs[R_COM10][6]) begin problems++; $display("  [config] COM10 = 0x%02X changes the PCLK/HREF/VSYNC polarity or gating; the course capture code expects the defaults (0x00).", regs[R_COM10]); end
        if (regs[R_COM3][6]) begin problems++; $display("  [config] COM3[6] swaps the output MSB/LSB; the capture code expects the datasheet bit order."); end
        if (regs[R_MVFP][5] || regs[R_MVFP][4]) $display("  [config] note: MVFP mirror=%0d flip=%0d: the picture is reversed on purpose (camera orientation on the robot).", regs[R_MVFP][5], regs[R_MVFP][4]);
        if (int'(regs[R_VSTRT]) * 4 + int'(regs[R_VREF][1:0]) < 11)
            $display("  [config] note: the window starts at readout row %0d (VSTRT/VREF). On the chip the rows above row 11 are not picture: row 10 is a dark blue line along the top, whatever the scene, and the model sends it too. The course's list starts at row 11 (VREF = 0x0F).",
                     int'(regs[R_VSTRT]) * 4 + int'(regs[R_VREF][1:0]));
        if (picture_changes() != "") $display("  [config] note: the picture is changed: %s.", picture_changes());
        if (dropped_count > 0) begin problems++; $display("  [config] %0d write(s) were dropped because they came within 1 ms of a reset: the chip may be in a half-configured state.", dropped_count); end
        if (problems == 0) $display("  [config] OK: %s %0dx%0d at %0.3f MHz PCLK, %0.1f fps.", pick(regs[R_COM7][2], "RGB565", "YUV"), out_w, out_h, pclk_hz / 1e6, fps);
        return problems;
    endfunction

endmodule
