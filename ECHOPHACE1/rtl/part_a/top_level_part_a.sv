// AI-assisted Part A integration; Member A name/SID pending.
// Native colour baseline, causal cleanup, bounded candidates, and raw capture.
// No CNN, candidate association, or motion logic; hardware validation pending.
// ECHO-7 Phase 1 / 1.5 | Owner: MTRX3700 ECHO-7 team (human review required).
// AI-assisted implementation: OpenAI Codex; see OWNERS.md and AI_STATEMENT.md.
/*
 *  top_level.sv -- the OV7670 camera on the DE1-SoC, live on the VGA monitor.
 *
 *      CLOCK_50 --> video_pll --> clk_25 (display, SCCB /250) and clk_10 --> camera XCLK (GPIO_1[20]); sensor x4 PLL then /2 prescaler = 20 MHz PCLK at 25 fps.
 *                                   |
 *      clock_divider --> 100 kHz --> ov7670_config --SCCB--> camera (RESET#, PWDN, SIO_C, SIO_D)
 *
 *      camera PCLK/VSYNC/HREF/D --> ov7670_capture --> frame_buffer (write port, PCLK domain)
 *                                                        frame_buffer (read port, clk_25 domain)
 *                                                            --> camera_display --> segmentationSelector
 *                                                            --> colourDiagnostics (mask/box/text) --> vga_sink.qsys --> VGA
 *
 *  Pins: the Robot Adaptor Board puts the camera on GPIO_1[10..25]; the stock DE1-SoC pin
 *  assignments are used, and the mapping lives here, in one place:
 *      PWDN 10, RESET# 11, D0..D7 12..19, XCLK 20, PCLK 21, HREF 22, VSYNC 23, SIO_D 24, SIO_C 25.
 *
 *  Controls: KEY0 = reset (re-runs the camera configuration). LEDR0 = camera configured,
 *  LEDR1 = the last SCCB write got no acknowledge (being retried: check the loom and XCLK),
 *  LEDR2 toggles once per camera frame (12.5 Hz at the required 25 fps).
 */
module top_level #(
    parameter int CAMERA_FPS = 25,  // Required: native Part A timing is constrained for 20 MHz PCLK.
    parameter int RATIO_RED_MIN_VALUE = 64,
    parameter int RATIO_BLUE_MIN_VALUE = 32,
    parameter int RATIO_NUM = 3,
    parameter int RATIO_DEN = 2
) (
    input  wire        CLOCK_50,
    output wire [6:0] HEX0, HEX1, HEX2,
    input  wire [3:0]  KEY,
    input  wire [4:0]  SW, // SW0 reserved; SW[2:1] algorithm; SW3 overlay; SW4 calibration
    output wire [9:0]  LEDR,
    inout  wire [35:0] GPIO_1,
    output wire        VGA_CLK, VGA_HS, VGA_VS, VGA_BLANK_N, VGA_SYNC_N,
    output wire [7:0]  VGA_R, VGA_G, VGA_B
);
    // Match the physical sensor clock to PartAPipeline.sdc. This undefined-module
    // elaboration guard also applies in synthesis (same pattern as ov7670_config).
    generate if (CAMERA_FPS != 25) begin : part_a_requires_25fps
        PartAPipeline_requires_CAMERA_FPS_25_and_20MHz_PCLK stop_here ();
    end endgenerate
    generate if (RATIO_RED_MIN_VALUE<0 || RATIO_RED_MIN_VALUE>255 ||
                 RATIO_BLUE_MIN_VALUE<0 || RATIO_BLUE_MIN_VALUE>255 ||
                 RATIO_NUM<1 || RATIO_NUM>255 || RATIO_DEN<1 || RATIO_DEN>255) begin : invalid_ratio_profile
        PartAPipeline_ratio_profile_must_fit_packet_bytes stop_here ();
    end endgenerate
    // ---- clocks ------------------------------------------------------------------------------
    wire clk_25, pll_locked;
    wire clk_10;
    video_pll video_pll_u (.refclk(CLOCK_50), .rst(1'b0), .outclk_0(clk_25), .outclk_1(clk_10), .locked(pll_locked));
    wire sccb_clk;
    clock_divider #(.DIVISOR(250)) sccb_clk_u (.clk_in(clk_25), .clk_out(sccb_clk));   // 100 kHz

    // ---- reset: KEY0 (active low), synchronised into each domain ---------------------------------
    logic [1:0] rs25 = '0, rs_sccb = '0;
    always_ff @(posedge clk_25)   rs25    <= {rs25[0],    ~KEY[0] | ~pll_locked};
    always_ff @(posedge sccb_clk) rs_sccb <= {rs_sccb[0], ~KEY[0]};
    wire reset25 = rs25[1], reset_sccb = rs_sccb[1];

    // ---- the camera's pins ---------------------------------------------------------------------
    wire       cam_pclk  = GPIO_1[21];
    wire       cam_href  = GPIO_1[22];
    wire       cam_vsync = GPIO_1[23];
    wire [7:0] cam_d     = GPIO_1[19:12];
    wire       cam_reset_n, cam_pwdn, sioc;
    assign GPIO_1[20] = clk_10;          // XCLK10 MHz; sensor PLLx4 and CLKRC0x81 /2 produce20 MHz PCLK.
    assign GPIO_1[11] = cam_reset_n;     // RESET#
    assign GPIO_1[10] = cam_pwdn;        // PWDN
    assign GPIO_1[25] = sioc;            // SIO_C
    // GPIO_1[24] is SIO_D, driven open-drain from inside ov7670_config; every other pin stays an input

    // ---- configure the camera ------------------------------------------------------------------
    wire cfg_done, cfg_error;
    ov7670_config #(.FPS(CAMERA_FPS)) cfg_u (
        .clk(sccb_clk), .reset(reset_sccb), .sioc(sioc), .siod(GPIO_1[24]),
        .cam_reset_n(cam_reset_n), .cam_pwdn(cam_pwdn), .done(cfg_done), .error(cfg_error));

    // ---- capture the stream (PCLK domain) --------------------------------------------------------
    wire        frame_start, px_valid;
    wire [15:0] px;
    wire [9:0]  px_x;
    wire [8:0]  px_y;
    ov7670_capture cap_u (
        .pclk(cam_pclk), .vsync(cam_vsync), .href(cam_href), .d(cam_d),
        .frame_start(frame_start), .valid(px_valid), .pixel(px), .x(px_x), .y(px_y));

    // ---- one picture in memory: written at PCLK, read at clk_25 ----------------------------------
    wire [8:0]  rd_x;
    wire [7:0]  rd_y;
    wire [15:0] rd_pixel;
    frame_buffer #(.W(320), .H(240), .DW(16), .DECIMATE(2), .BUFFERS(1), .PACKED(0)) fb_u (   // one 16-bit picture, 150 M10K: simple; a moving scene can tear (frame_buffer.sv has 2 / 3 banks and packing)
        .wr_clk(cam_pclk), .wr_frame_start(frame_start), .wr_valid(px_valid), .wr_x(px_x), .wr_y(px_y), .wr_pixel(px),
        .rd_clk(clk_25), .rd_x(rd_x), .rd_y(rd_y), .rd_pixel(rd_pixel));

    // ---- show it -----------------------------------------------------------------------------------
    wire [29:0] st_data;
    wire        st_sop, st_eop, st_valid, st_ready;
    camera_display #(.H_RES(640), .V_RES(480), .W(320), .H(240), .ROTATE_CCW_90(1)) disp_u (
        .clk(clk_25), .reset(reset25), .hold_enable(1'b1), .rd_x(rd_x), .rd_y(rd_y), .rd_pixel(rd_pixel),
        .data(st_data), .startofpacket(st_sop), .endofpacket(st_eop), .valid(st_valid), .ready(st_ready));

    // ECHO-7: all classification and overlay processing stays in the display domain.
    wire [29:0] seg_data, mask_data;
    wire seg_sop, seg_eop, seg_valid, seg_ready, seg_overlay, seg_calibration;
    wire mask_sop, mask_eop, mask_valid, mask_ready;
    wire [1:0] seg_mask, seg_mode;
    segmentationSelector #(.CONTROL_WIDTH(4), .RATIO_RED_MIN_VALUE(RATIO_RED_MIN_VALUE),
        .RATIO_BLUE_MIN_VALUE(RATIO_BLUE_MIN_VALUE), .RATIO_NUM(RATIO_NUM), .RATIO_DEN(RATIO_DEN)) seg_u (
        .clk(clk_25), .reset(reset25), .control_async(SW[4:1]),
        .in_data(st_data), .in_sop(st_sop), .in_eop(st_eop), .in_valid(st_valid), .in_ready(st_ready),
        .out_data(seg_data), .out_sop(seg_sop), .out_eop(seg_eop), .out_valid(seg_valid), .out_ready(seg_ready),
        .out_mask(seg_mask), .out_overlay(seg_overlay), .out_mode(seg_mode), .out_calibration(seg_calibration));
    videoDiagnostics overlay_u (
        .clk(clk_25), .reset(reset25), .in_data(seg_data), .in_mask(seg_mask), .in_mode(seg_mode), .in_overlay(seg_overlay), .in_calibration(seg_calibration),
        .in_sop(seg_sop), .in_eop(seg_eop), .in_valid(seg_valid), .in_ready(seg_ready),
        .out_data(mask_data), .out_sop(mask_sop), .out_eop(mask_eop), .out_valid(mask_valid), .out_ready(mask_ready));

    vga_sink vga_u (
        .clk_clk(clk_25), .reset_reset_n(~reset25),
        .video_in_data(mask_data), .video_in_startofpacket(mask_sop), .video_in_endofpacket(mask_eop),
        .video_in_valid(mask_valid), .video_in_ready(mask_ready),
        .vga_CLK(VGA_CLK), .vga_HS(VGA_HS), .vga_VS(VGA_VS), .vga_BLANK(VGA_BLANK_N), .vga_SYNC(VGA_SYNC_N),
        .vga_R(VGA_R), .vga_G(VGA_G), .vga_B(VGA_B));

    // ---- status LEDs ---------------------------------------------------------------------------------
    logic frame_toggle = 1'b0;
    always_ff @(posedge cam_pclk) if (frame_start) frame_toggle <= ~frame_toggle;

    // Course FrameGrab V2026.1: raw PCLK tap before display rotation/segmentation.
    // Native 320x240 RGB565; camera MVFP stays 0x07. Use grab.py --mvfp 0x07.
    // The 78 result words contain native Part A statistics/candidates for this
    // captured frame, with explicit ID matching; see packet_schema.json.
    logic [1:0] rs_pclk = '0;
    always_ff @(posedge cam_pclk) rs_pclk <= {rs_pclk[0], ~KEY[0]};
    wire reset_pclk = rs_pclk[1];
    wire [78*32-1:0] stats;
    partACapturePipeline #(.W(320), .H(240), .CAP(8), .MIN_AREA(32),
        .RATIO_RED_MIN_VALUE(RATIO_RED_MIN_VALUE), .RATIO_BLUE_MIN_VALUE(RATIO_BLUE_MIN_VALUE),
        .RATIO_NUM(RATIO_NUM), .RATIO_DEN(RATIO_DEN)) part_a_u (
        .pclk(cam_pclk), .reset(reset_pclk), .camera_frame_start(frame_start),
        .px_valid(px_valid), .pixel(px), .px_x(px_x), .px_y(px_y),
        .control_async(SW[4:1]), .snapshot_results(stats));
    wire snap_busy, snap_ready;
    frame_snap #(.MODE(0), .N_RESULTS(78)) snap_u (
        .pclk(cam_pclk), .reset(reset_pclk), .frame_start(frame_start),
        .px_valid(px_valid), .pixel(px), .x(px_x), .y(px_y),
        .results(stats), .trigger(~KEY[1]), .busy(snap_busy), .ready(snap_ready));

    // Camera uses GPIO_1[10..25]; every other GPIO_1 pin is explicitly high impedance.
    // No chassis, Arduino, sonar, IR-control, or UART logic is instantiated.
    assign GPIO_1[9:0] = 10'bz;
    assign GPIO_1[35:26] = 10'bz;
    assign HEX0 = 7'h7f;
    assign HEX1 = 7'h7f;
    assign HEX2 = 7'h7f;
    // KEY1 requests a snapshot. KEY2/3 unused. LED3 held snapshot, LED4 capturing.
    assign LEDR = {5'b0, snap_busy, snap_ready, frame_toggle, cfg_error, cfg_done};
endmodule
