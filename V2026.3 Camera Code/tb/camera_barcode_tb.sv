`timescale 1ns/1ps
/*
 *  camera_barcode_tb -- the Assignment 2 barcode reader reading a barcode THROUGH the camera.
 *
 *      scene (a barcode on a wall, panning) -> OV7670 model -> ov7670_capture
 *          -> live_reader (decimate, grey, hdiff, column profile, run picker, bar decoder)   [PCLK domain]
 *          -> cdc_latch -> camera_barcode_display (picture + red edges + the value) -> VGA model -> frame_*.png
 *          -> frame_buffer (the picture itself, as in the plain camera project)
 *
 *  The camera is configured by the model's set_reg (no SCCB traffic, to keep the run short) with
 *  the core registers ov7670_config sends, then the rest of its list (cam.set_course_tuning()):
 *  PCLK 40 MHz from the 10 MHz XCLK, RGB565, the window (columns 160..16, rows 11..491), mirrored and
 *  flipped as on the robot, so the bars are read right to left and the value comes out bit-reversed,
 *  which the bench expects.
 *  PASS: the decoded value equals the mirror of the scene's code on every result after the first
 *  complete frame, and no VGA protocol errors. The pictures show the red edge lines.
 *
 *  Run:  ./simulate.sh barcode. For another barcode, run ./obj_dir/Vcamera_barcode_tb +code=<hex> after it
 *        (default A3; A5 is a palindrome and hides the mirroring), then python3 tools/render_frames.py.
 */
module camera_barcode_tb;
    localparam int W = 320, H = 240, NB = 8, NMAX = 32, XW = $clog2(W);
    logic clk_10 = 0; always #50 clk_10 = ~clk_10;     // XCLK, 10 MHz as on the board (x4 inside the camera = 40 MHz PCLK)
    logic clk_vga = 0; always #20 clk_vga = ~clk_vga;   // the 25 MHz display clock
    logic reset_n = 0, reset = 1;
    wire  sio_d; logic sio_c = 1; pullup(sio_d);
    wire  pclk, vsync, href; wire [7:0] d;
    int frames_done, write_count, error_count;
    int scene_x0 = 0; logic [7:0] scene_code = 8'hA3;
    ov7670_model #(.VERBOSE(0)) cam (
        .sio_c(sio_c), .sio_d(sio_d), .xclk(clk_10), .reset_n(reset_n), .pwdn(1'b0),
        .pclk(pclk), .vsync(vsync), .href(href), .d(d),
        .scene_mode(3), .scene_x0(scene_x0), .scene_y0(0), .scene_code(scene_code),
        .frames_done(frames_done), .write_count(write_count), .error_count(error_count));

    // ---- capture ----
    wire frame_start, px_valid; wire [15:0] px; wire [9:0] px_x; wire [8:0] px_y;
    ov7670_capture cap (.pclk(pclk), .vsync(vsync), .href(href), .d(d), .frame_start(frame_start), .valid(px_valid), .pixel(px), .x(px_x), .y(px_y));

    // ---- the reader on the live stream (PCLK domain) ----
    logic [19:0] thr = 20'd4096; logic [XW-1:0] min_gap = XW'(3);
    logic result_valid, code_valid, prof_wr; logic [$clog2(NMAX):0] edge_count; logic [NMAX*XW-1:0] edge_list;
    logic [NB-1:0] code; logic [XW-1:0] prof_wr_x; logic [19:0] prof_wr_val;
    logic reset_p = 1;
    always @(posedge pclk) reset_p <= reset;
    live_reader #(.W(W), .H(H), .NB(NB), .NMAX(NMAX)) reader (
        .clk(pclk), .reset(reset_p), .cam_frame_start(frame_start), .cam_valid(px_valid), .cam_pixel(px), .cam_x(px_x), .cam_y(px_y),
        .thr, .min_gap, .result_valid, .edge_count, .edge_list, .code_valid, .code, .prof_wr, .prof_wr_x, .prof_wr_val);

    // ---- the picture, and the results, into the display clock ----
    wire [8:0] rd_x; wire [7:0] rd_y; wire [15:0] rd_pixel;
    frame_buffer #(.W(W), .H(H), .DW(16), .DECIMATE(2)) fb (.wr_clk(pclk), .wr_frame_start(1'b0), .wr_valid(px_valid), .wr_x(px_x), .wr_y(px_y), .wr_pixel(px),
        .rd_clk(clk_vga), .rd_x(rd_x), .rd_y(rd_y), .rd_pixel(rd_pixel));
    localparam int RW = 1 + $clog2(NMAX)+1 + NMAX*XW + NB;
    logic [RW-1:0] bundle_src, bundle_dst; logic vblank, updated;
    assign bundle_src = {code_valid, edge_count, edge_list, code};
    cdc_latch #(.WIDTH(RW)) latch (.src_clk(pclk), .src_valid(result_valid), .src_data(bundle_src), .src_busy(),
        .dst_clk(clk_vga), .dst_reset(reset), .update_ok(vblank), .dst_data(bundle_dst), .dst_updated(updated));
    logic d_code_valid; logic [$clog2(NMAX):0] d_count; logic [NMAX*XW-1:0] d_list; logic [NB-1:0] d_code;
    assign {d_code_valid, d_count, d_list, d_code} = bundle_dst;

    wire [29:0] st_data; wire st_sop, st_eop, st_valid, st_ready;
    camera_barcode_display #(.W(W), .H(H), .NB(NB), .NMAX(NMAX)) disp (
        .clk(clk_vga), .reset(reset), .rd_x(rd_x), .rd_y(rd_y), .rd_pixel(rd_pixel),
        .edge_count(d_count), .edge_list(d_list), .code_valid(d_code_valid), .code(d_code),
        .data(st_data), .startofpacket(st_sop), .endofpacket(st_eop), .valid(st_valid), .ready(st_ready), .vblank(vblank));
    int mon_frames, mon_errors, x_pos, y_pos; logic accept, discard;
    vga_monitor_model #(.H_RES(640), .V_RES(480), .H_BLANK(160), .V_BLANK(45), .ASCII_ART(0), .PPM_PREFIX("barcode_frame"), .MAX_PPM_FILES(8), .VERBOSE(0)) mon (
        .clk(clk_vga), .reset(reset), .data(st_data), .startofpacket(st_sop), .endofpacket(st_eop), .valid(st_valid), .ready(st_ready),
        .frames_done(mon_frames), .errors(mon_errors), .x_pos(x_pos), .y_pos(y_pos), .accept(accept), .discard(discard));

    function automatic logic [7:0] reverse8(input logic [7:0] v);
        for (int i = 0; i < 8; i++) reverse8[i] = v[7 - i];
    endfunction

    int results = 0, good = 0, fails = 0; logic [7:0] want;
    always @(posedge pclk) if (result_valid) begin
        results++;
        want = cam.regs[8'h1E][5] ? reverse8(scene_code) : scene_code;      // mirrored camera: bars read backwards
        $write("[tb @%0t] result %0d: %0d edges:", $time, results, edge_count);
        for (int i = 0; i < edge_count; i++) $write(" %0d", edge_list[i*XW +: XW]);
        $display("  ->  code %02X valid=%0d (scene %02X, expected read %02X)", code, code_valid, scene_code, want);
        if (results >= 2) begin if (code_valid && code == want) good++; else begin fails++; $display("FAIL: result %0d wrong", results); end end
    end

    initial begin
        if ($value$plusargs("code=%h", scene_code)) ;
        `ifdef VERILATOR
        if ($test$plusargs("wave")) begin $dumpfile("waveform.fst"); $dumpvars(0, reader.u_pick); $dumpvars(0, reader.u_dec); end
        `else
        $dumpfile("waveform.vcd"); $dumpvars(0, reader.u_dec);
        `endif
        #10us reset_n = 1;
        #1.5ms;
        // the core registers ov7670_config writes (see rtl/ov7670_config.sv)
        cam.set_reg(8'h3A, 8'h04); cam.set_reg(8'h11, 8'h80); cam.set_reg(8'h6B, 8'h4A);   // TSLB, CLKRC /1 (bit 7 set), DBLV PLL x4: PCLK 40 MHz
        cam.set_reg(8'h12, 8'h04); cam.set_reg(8'h40, 8'hD0);                               // COM7 RGB VGA, COM15 RGB565 00..FF
        cam.set_reg(8'h17, 8'h14); cam.set_reg(8'h18, 8'h02); cam.set_reg(8'h32, 8'h80);   // window columns 160..16 (wrapping at 784): 640 wide
        cam.set_reg(8'h19, 8'h02); cam.set_reg(8'h1A, 8'h7A); cam.set_reg(8'h03, 8'h0F);   // window rows 11..491
        cam.set_reg(8'h1E, 8'h37);                                                          // MVFP mirror + flip
        cam.set_course_tuning();                                                            // the rest of the list: the course's colours
        @(posedge vsync); reset = 0;
        // six camera frames, panning the barcode 12 pixels a frame
        for (int f = 0; f < 6; f++) begin @(posedge vsync); scene_x0 = scene_x0 + 12; end
        fork
            wait (mon_frames >= 8);
            begin #300ms; $display("FAIL: only %0d monitor frames in 300 ms", mon_frames); $display("FAILED: 1 problem"); $finish; end
        join_any
        disable fork;
        #1us;
        if (results < 3) begin fails++; $display("FAIL: only %0d results from the reader", results); end
        if (mon_errors != 0) begin fails++; $display("FAIL: %0d VGA protocol errors", mon_errors); end
        if (fails == 0) $display("PASS: barcode %02X read through the camera %0d times (as %02X, mirrored), %0d monitor frames drawn; see barcode_frame_*.png", scene_code, good, reverse8(scene_code), mon_frames);
        else $display("FAILED: %0d problem(s)", fails);
        $finish;
    end
endmodule
