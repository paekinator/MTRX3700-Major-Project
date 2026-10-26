`timescale 1ns/1ps
/*
 *  ov7670_capture_tb -- the pixel capture against the camera model.
 *
 *  The model is put into RGB565 directly (no SCCB traffic: cam.set_reg writes the registers as
 *  if the transactions had happened), with the window ov7670_config.sv sets (columns 160..16,
 *  rows 11..491) and the rest of its list (cam.set_course_tuning(): without it the chip keeps
 *  Table 5's colour matrix, about half the colour), and streams the "shapes" scene. The capture module must deliver every pixel
 *  with the right value and the right (x, y): the bench compares each one with what the model
 *  says it put on the bus, cam.expected_word(x, y), and counts pixels and frame_start pulses
 *  per frame. Two frames, about 240 ms of camera time, a second or two to run in our tests.
 *
 *  Run:  ./simulate.sh capture
 */
module ov7670_capture_tb;
    // XCLK, 10 MHz as on the board. The camera's PLL is left bypassed here (DBLV keeps its default), so PCLK =
    // XCLK = 10 MHz and a frame takes 80 ms: the capture logic does not care about the rate, and the system and
    // barcode benches run it at the board's 40 MHz.
    logic clk_10 = 0;   always #50 clk_10 = ~clk_10;   // the camera's XCLK, 10 MHz
    logic reset_n = 0;
    wire  sio_d; logic sio_c = 1; pullup(sio_d);
    wire  pclk, vsync, href; wire [7:0] d;
    int frames_done, write_count, error_count;
    int scene_x0 = 0;
    ov7670_model #(.VERBOSE(0)) cam (
        .sio_c(sio_c), .sio_d(sio_d), .xclk(clk_10), .reset_n(reset_n), .pwdn(1'b0),
        .pclk(pclk), .vsync(vsync), .href(href), .d(d),
        .scene_mode(1), .scene_x0(scene_x0), .scene_y0(0), .scene_code(8'hA5),
        .frames_done(frames_done), .write_count(write_count), .error_count(error_count));

    wire        frame_start, valid;
    wire [15:0] pixel;
    wire [9:0]  x;
    wire [8:0]  y;
    ov7670_capture dut (.pclk(pclk), .vsync(vsync), .href(href), .d(d),
                        .frame_start(frame_start), .valid(valid), .pixel(pixel), .x(x), .y(y));

    // ---- checks, in the PCLK domain -----------------------------------------------------------
    int pixels = 0, bad_value = 0, bad_coord = 0, starts = 0, fails = 0;
    int last_x = -1, last_y = -1;
    logic [15:0] want;
    always @(posedge pclk) begin
        if (frame_start) begin
            starts++;
            if (pixels != 0 && pixels != 640 * 480) begin fails++; $display("FAIL: frame %0d delivered %0d pixels, expected %0d", starts - 1, pixels, 640 * 480); end
            pixels = 0; last_x = -1; last_y = -1;
        end
        if (valid) begin
            pixels++;
            // coordinates must walk the raster: x + 1 on the same row, or x = 0 on the next row
            if (!((int'(x) == last_x + 1 && int'(y) == last_y) || (x == 0 && (int'(y) == last_y + 1 || last_y == -1)))) begin
                bad_coord++;
                if (bad_coord <= 5) $display("FAIL: pixel at (%0d,%0d) came after (%0d,%0d)", x, y, last_x, last_y);
            end
            last_x = x; last_y = y;
            want = cam.expected_word(int'(x), int'(y));
            if (pixel !== want) begin
                bad_value++;
                if (bad_value <= 5) $display("FAIL: pixel (%0d,%0d) = %04h, the camera sent %04h", x, y, pixel, want);
            end
        end
    end

    // "+wave": a SHORT run that traces the first rows of one frame (a full frame is a 15 MB waveform;
    // Ed's workspace disk is small), then stops. Without it: the full two-frame check, no waveform.
    logic wave_mode = 0;
    initial begin
        `ifndef VERILATOR
        $dumpfile("waveform.vcd"); $dumpvars(0, dut);
        `endif
        wave_mode = $test$plusargs("wave");
        #10us reset_n = 1;
        #1.5ms;                                   // let the model's settle time pass
        cam.set_reg(8'h12, 8'h04);                // COM7: RGB output, VGA
        cam.set_reg(8'h40, 8'hD0);                // COM15: RGB565, full range
        cam.set_reg(8'h17, 8'h14); cam.set_reg(8'h18, 8'h02); cam.set_reg(8'h32, 8'h80);   // the window ov7670_config.sv sets: columns 160..16
        cam.set_reg(8'h19, 8'h02); cam.set_reg(8'h1A, 8'h7A); cam.set_reg(8'h03, 8'h0F);   //   (wrapping at 784, 640 wide) and rows 11..491
        cam.set_course_tuning();                  // the list's tuning and colour blocks, for the course's colours
        // two complete frames: wait for the start of a frame, then two more (with a watchdog: a capture
        // module that never pulses frame_start would otherwise leave this bench waiting for ever)
        fork
            begin @(posedge frame_start); end
            begin #120ms; $display("FAIL: frame_start never pulsed in 120 ms (the camera sent %0d frames). It must pulse on the falling edge of VSYNC.", frames_done); $display("FAILED: 1 problem"); $finish; end
        join_any
        disable fork;
        `ifdef VERILATOR
        if (wave_mode) begin
            $dumpfile("waveform.fst"); $dumpvars(0, dut);
            wait (valid && y == 3);
            $display("wave mode: the first three rows of a frame are in waveform.fst (%0d pixels checked so far, %0d wrong). Run ./simulate.sh without 'wave' for the full two-frame check.", pixels, bad_value);
            $finish;
        end
        `endif
        @(posedge frame_start);
        scene_x0 = 40;                            // the world moves between frames (the model pans the scene)
        @(posedge frame_start);
        if (pixels != 0 || starts != 3) begin end // the checks happen in the always block
        if (bad_value != 0) begin fails++; $display("FAIL: %0d pixel value mismatches", bad_value); end
        if (bad_coord != 0) begin fails++; $display("FAIL: %0d coordinate sequence errors", bad_coord); end
        if (starts != 3)   begin fails++; $display("FAIL: %0d frame_start pulses, expected 3", starts); end
        if (fails == 0) $display("PASS: ov7670_capture delivered 2 x %0d pixels with the right values and coordinates, 1 frame_start per frame", 640 * 480);
        else $display("FAILED: %0d problem(s)", fails);
        $finish;
    end
endmodule
