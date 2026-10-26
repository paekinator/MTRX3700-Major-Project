// ECHO-7 Phase 1 / 1.5 | Owner: MTRX3700 ECHO-7 team (human review required).
// AI-assisted implementation: OpenAI Codex; see OWNERS.md and AI_STATEMENT.md.
/*
 *  top_level.sv -- the OV7670 camera on the DE1-SoC, live on the VGA monitor.
 *
 *      CLOCK_50 --> video_pll --> clk_25 (display, SCCB /250) and clk_10 --> camera XCLK (GPIO_1[20]), x4 inside the camera = 40 MHz PCLK (20 at 25 fps)
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
 *  LEDR2 toggles once per camera frame (a 25 Hz flicker at 50 fps means frames are arriving).
 */
module top_level #(
    parameter bit POWER_KEY_CONFIGURED = 1, // Set only after HEX1..0 verifies the actual POWER command.
    parameter logic [7:0] POWER_KEY = 8'h12, // Placeholder, NOT a confirmed POWER code.
    parameter int CAMERA_FPS = 50   // the camera's frame rate: 50, or 25 for a dim room (twice the exposure; the camera lesson's slide 2.5)
) (
    input  wire        CLOCK_50,
    input  wire        IRDA_RXD,
    output wire [6:0] HEX0, HEX1, HEX2,
    input  wire [3:0]  KEY,
    input  wire [4:0]  SW, // SW0 reserved; SW[2:1] algorithm; SW3 overlay; SW4 calibration
    output wire [9:0]  LEDR,
    inout  wire [35:0] GPIO_1,
    output wire        VGA_CLK, VGA_HS, VGA_VS, VGA_BLANK_N, VGA_SYNC_N,
    output wire [7:0]  VGA_R, VGA_G, VGA_B
);
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
    assign GPIO_1[20] = clk_10;          // XCLK 10 MHz; the sensor's PLL makes the 40 MHz PCLK from it (ov7670_config.sv: DBLV)
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
    segmentationSelector #(.CONTROL_WIDTH(4)) seg_u (
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
    // ECHO-7 safety domain; camera and display domains above retain their existing wiring.
    logic [1:0] rs50=2'b11;
    always_ff @(posedge CLOCK_50) rs50<={rs50[0],~KEY[0]};
    wire reset50=rs50[1];
    wire [11:0] sonar1_distance_mm,sonar2_distance_mm;
    wire sonar1_valid,sonar2_valid,sonar1_update,sonar2_update;
    // Confirmed by the user: 2026 adaptor Port 2 / J4 uses GPIO_1[35]/[34].
    dualSonar sonar_u(.CLOCK_50(CLOCK_50),.reset50(reset50),.echo1(GPIO_1[29]),.echo2(GPIO_1[34]),
        .trig1(GPIO_1[27]),.trig2(GPIO_1[35]),.sonar1_distance_mm(sonar1_distance_mm),.sonar2_distance_mm(sonar2_distance_mm),
        .sonar1_valid(sonar1_valid),.sonar2_valid(sonar2_valid),.sonar1_update(sonar1_update),.sonar2_update(sonar2_update));
    wire estop_latched,control_expired,stop_active,rx_seen,ir_seen;
    wire [7:0] last_ir_key;
    safetySystem #(.POWER_KEY_CONFIGURED(POWER_KEY_CONFIGURED),.POWER_KEY(POWER_KEY)) safety_u (
        .clk(CLOCK_50),.reset(reset50),.ir_rx(IRDA_RXD),.chassis_rx(GPIO_1[33]),.chassis_tx(GPIO_1[31]),
        .sonar1_distance_mm(sonar1_distance_mm),.sonar2_distance_mm(sonar2_distance_mm),
        .sonar1_valid(sonar1_valid),.sonar2_valid(sonar2_valid),.sonar1_update(sonar1_update),.sonar2_update(sonar2_update),
        .estop_latched(estop_latched),.control_expired(control_expired),.stop_active(stop_active),.rx_seen(rx_seen),
        .last_ir_key(last_ir_key),.last_ir_code(),.ir_seen(ir_seen),.stop_reason());
    // HEX normally shows the last checked NEC key. Hold KEY1/KEY2 for measured sonar mm in HEX.
    logic [1:0] key1_sync=2'b11,key2_sync=2'b11;
    always_ff @(posedge CLOCK_50) begin
        key1_sync<={key1_sync[0],KEY[1]}; key2_sync<={key2_sync[0],KEY[2]};
    end
    wire [11:0] diagnostic_value=!key1_sync[1] ? sonar1_distance_mm :
        !key2_sync[1] ? sonar2_distance_mm : {4'd0,last_ir_key};
    wire [6:0] hex2_value;
    safetyHex hex0_u(.value(diagnostic_value[3:0]),.segments(HEX0));
    safetyHex hex1_u(.value(diagnostic_value[7:4]),.segments(HEX1));
    safetyHex hex2_u(.value(diagnostic_value[11:8]),.segments(hex2_value));
    assign HEX2=(!key1_sync[1] || !key2_sync[1]) ? hex2_value : 7'h7f;
    // LEDR9=0: Ultrasonic Safety DISABLED. RX activity is not a command ACK.
    assign LEDR={1'b0,POWER_KEY_CONFIGURED,ir_seen,rx_seen,control_expired,estop_latched,
                 stop_active,frame_toggle,cfg_error,cfg_done};
endmodule
