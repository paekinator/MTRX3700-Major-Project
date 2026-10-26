/*
 *  top_level.sv -- the OV7670 camera on the DE1-SoC, live on the VGA monitor.
 *
 *      CLOCK_50 --> video_pll --> clk_25 (display, SCCB /250) and clk_10 --> camera XCLK (GPIO_1[20]), x4 inside the camera = 40 MHz PCLK (20 at 25 fps)
 *                                   |
 *      clock_divider --> 100 kHz --> ov7670_config --SCCB--> camera (RESET#, PWDN, SIO_C, SIO_D)
 *
 *      camera PCLK/VSYNC/HREF/D --> ov7670_capture --> frame_buffer (write port, PCLK domain)
 *                                                        frame_buffer (read port, clk_25 domain)
 *                                                            --> camera_display --Avalon-ST--> vga_sink.qsys --> VGA
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
    parameter int CAMERA_FPS = 50   // the camera's frame rate: 50, or 25 for a dim room (twice the exposure; the camera lesson's slide 2.5)
) (
    input  wire        CLOCK_50,
    input  wire [3:0]  KEY,
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
    camera_display #(.H_RES(640), .V_RES(480), .W(320), .H(240)) disp_u (
        .clk(clk_25), .reset(reset25), .hold_enable(1'b1), .rd_x(rd_x), .rd_y(rd_y), .rd_pixel(rd_pixel),
        .data(st_data), .startofpacket(st_sop), .endofpacket(st_eop), .valid(st_valid), .ready(st_ready));

    vga_sink vga_u (
        .clk_clk(clk_25), .reset_reset_n(~reset25),
        .video_in_data(st_data), .video_in_startofpacket(st_sop), .video_in_endofpacket(st_eop),
        .video_in_valid(st_valid), .video_in_ready(st_ready),
        .vga_CLK(VGA_CLK), .vga_HS(VGA_HS), .vga_VS(VGA_VS), .vga_BLANK(VGA_BLANK_N), .vga_SYNC(VGA_SYNC_N),
        .vga_R(VGA_R), .vga_G(VGA_G), .vga_B(VGA_B));

    // ---- status LEDs ---------------------------------------------------------------------------------
    logic frame_toggle = 1'b0;
    always_ff @(posedge cam_pclk) if (frame_start) frame_toggle <= ~frame_toggle;
    assign LEDR = {7'b0, frame_toggle, cfg_error, cfg_done};
endmodule
