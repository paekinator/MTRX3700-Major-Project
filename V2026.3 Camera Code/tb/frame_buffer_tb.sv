`timescale 1ns/1ps
/*
 *  frame_buffer_tb -- write a full-resolution stream in on one clock, read the stored picture
 *  back on another.
 *
 *  The write side gets one 640x480 frame at 25 MHz, one pixel every second clock, value =
 *  {x[7:0], y[7:0]} so every stored pixel says where it came from. The read side runs on a 27 MHz
 *  clock (deliberately not the write clock) and reads all 320x240 positions; each must hold the
 *  pixel from (2x, 2y). Then a second frame with different values checks that writes overwrite.
 *
 *  Part 1 also runs the PACKED variant alongside (RGB444 inside: the top four bits of each channel must come back).
 *  Part 2: the same with BUFFERS = 3 (plain and packed) and BUFFERS = 2, camera frames marked by wr_frame_start and
 *  the reader running its own frames continuously, as on the board. Every frame the reader
 *  completes must be ONE camera frame, whole: never a mix of two (that is tearing), and with three
 *  banks every camera frame must appear; with two banks every other one may be missing.
 *
 *  Run:  ./simulate.sh buffer
 */
module frame_buffer_tb;
    logic wr_clk = 0; always #20.000 wr_clk = ~wr_clk;    // 25 MHz (PCLK is 40 MHz on the board; the rate makes no difference here)
    logic rd_clk = 0; always #18.518 rd_clk = ~rd_clk;    // 27 MHz
    logic        wr_valid = 0;
    logic [9:0]  wr_x = 0;
    logic [8:0]  wr_y = 0;
    logic [15:0] wr_pixel = 0;
    logic [8:0]  rd_x = 0;
    logic [7:0]  rd_y = 0;
    wire  [15:0] rd_pixel;
    frame_buffer #(.W(320), .H(240), .DW(16), .DECIMATE(2)) dut (
        .wr_clk(wr_clk), .wr_frame_start(1'b0), .wr_valid(wr_valid), .wr_x(wr_x), .wr_y(wr_y), .wr_pixel(wr_pixel),
        .rd_clk(rd_clk), .rd_x(rd_x), .rd_y(rd_y), .rd_pixel(rd_pixel));
    wire  [15:0] rdp_pixel;                                          // the same, packed: RGB444 inside, three pixels per word
    frame_buffer #(.W(320), .H(240), .DW(16), .DECIMATE(2), .PACKED(1)) dutp (
        .wr_clk(wr_clk), .wr_frame_start(1'b0), .wr_valid(wr_valid), .wr_x(wr_x), .wr_y(wr_y), .wr_pixel(wr_pixel),
        .rd_clk(rd_clk), .rd_x(rd_x), .rd_y(rd_y), .rd_pixel(rdp_pixel));
    function automatic logic [15:0] packed_view(input logic [15:0] v);   // what survives RGB565 -> RGB444 -> RGB565
        return {v[15:12], v[15], v[10:7], v[10:9], v[4:1], v[4]};
    endfunction

    function automatic logic [15:0] value_of(input int x, input int y, input int frame);
        return {x[7:0], y[7:0]} ^ (frame ? 16'h5A5A : 16'h0000);
    endfunction

    // ---- part 2: banked buffers, the reader free-running ------------------------------------------
    // pixel value = {frame number, y[7:0]}: the reader can tell which camera frame a pixel came from
    logic        b_fs = 0, b_valid = 0;
    logic [9:0]  b_x = 0;
    logic [8:0]  b_y = 0;
    logic [15:0] b_pixel = 0;
    logic [8:0]  b_rd_x = 0;
    logic [7:0]  b_rd_y = 0;
    wire  [15:0] b3_pixel, b2_pixel, b3p_pixel;
    frame_buffer #(.W(320), .H(240), .DW(16), .DECIMATE(2), .BUFFERS(3), .PACKED(1)) dut3p (   // three banks that fit the chip (packed)
        .wr_clk(wr_clk), .wr_frame_start(b_fs), .wr_valid(b_valid), .wr_x(b_x), .wr_y(b_y), .wr_pixel(b_pixel),
        .rd_clk(rd_clk), .rd_x(b_rd_x), .rd_y(b_rd_y), .rd_pixel(b3p_pixel));
    frame_buffer #(.W(320), .H(240), .DW(16), .DECIMATE(2), .BUFFERS(3)) dut3 (
        .wr_clk(wr_clk), .wr_frame_start(b_fs), .wr_valid(b_valid), .wr_x(b_x), .wr_y(b_y), .wr_pixel(b_pixel),
        .rd_clk(rd_clk), .rd_x(b_rd_x), .rd_y(b_rd_y), .rd_pixel(b3_pixel));
    frame_buffer #(.W(320), .H(240), .DW(16), .DECIMATE(2), .BUFFERS(2)) dut2 (
        .wr_clk(wr_clk), .wr_frame_start(b_fs), .wr_valid(b_valid), .wr_x(b_x), .wr_y(b_y), .wr_pixel(b_pixel),
        .rd_clk(rd_clk), .rd_x(b_rd_x), .rd_y(b_rd_y), .rd_pixel(b2_pixel));

    // the camera: frame_start, 17 blank lines, 480 rows of 640 pixels (one every second PCLK), 10 blank lines; 31 fps
    // at this bench's 25 MHz (50 fps at the board's 40 MHz)
    task automatic camera_frame(input int frame);
        @(negedge wr_clk); b_fs = 1; @(negedge wr_clk); b_fs = 0;
        repeat (17 * 1568) @(negedge wr_clk);
        for (int y = 0; y < 480; y++) begin
            for (int x = 0; x < 640; x++) begin
                @(negedge wr_clk); b_valid = 1; b_x = 10'(x); b_y = 9'(y); b_pixel = {8'(frame), 8'(y)};
                @(negedge wr_clk); b_valid = 0;
            end
            repeat (1568 - 1280) @(negedge wr_clk);
        end
        repeat (10 * 1568) @(negedge wr_clk);
    endtask

    // the reader: 320x240 addresses, one per clock, then 40 clocks of "blanking", forever (about 3 ms per frame here:
    // faster than the bench's 32 ms camera frame, as the 60 Hz monitor is faster than the camera's 50 fps on the
    // board). Each completed frame is checked.
    int frames_read = 0, torn3 = 0, torn2 = 0, torn3p = 0, shown3 [$], shown2 [$], shown3p [$];
    logic reader_on = 0;
    always begin
        @(negedge rd_clk);
        if (reader_on) read_one_frame();
    end
    task automatic read_one_frame();
        int first3 = -1, first2 = -1, first3p = -1, mix3 = 0, mix2 = 0, mix3p = 0;
        for (int y = 0; y < 240; y++)
            for (int x = 0; x < 320; x++) begin
                b_rd_x = 9'(x); b_rd_y = 8'(y);
                @(negedge rd_clk);                            // registered read: the previous address's pixel is out now
                if (x > 0 || y > 0) begin          // the frame number is bits 10..8 of the pixel: those survive the RGB444 packing
                    if (first3  < 0) first3  = b3_pixel[10:8];  else if (b3_pixel[10:8]  != first3[2:0])  mix3++;
                    if (first2  < 0) first2  = b2_pixel[10:8];  else if (b2_pixel[10:8]  != first2[2:0])  mix2++;
                    if (first3p < 0) first3p = b3p_pixel[10:8]; else if (b3p_pixel[10:8] != first3p[2:0]) mix3p++;
                end
            end
        b_rd_x = 0; b_rd_y = 0;
        repeat (40) @(negedge rd_clk);                        // the (0,0) address held: the bank switch happens here
        frames_read++;
        if (mix3) torn3++;
        if (mix2) torn2++;
        if (mix3p) torn3p++;
        if (shown3.size() == 0 || shown3[$] != first3) shown3.push_back(first3);
        if (shown2.size() == 0 || shown2[$] != first2) shown2.push_back(first2);
        if (shown3p.size() == 0 || shown3p[$] != first3p) shown3p.push_back(first3p);
    endtask

    task automatic write_frame(input int frame);
        for (int y = 0; y < 480; y++)
            for (int x = 0; x < 640; x++) begin
                @(negedge wr_clk); wr_valid = 1; wr_x = 10'(x); wr_y = 9'(y); wr_pixel = value_of(x, y, frame);
                @(negedge wr_clk); wr_valid = 0;                        // one pixel every second PCLK, as the camera does
            end
    endtask

    int fails = 0, errors;
    task automatic read_and_check(input int frame);
        logic [15:0] want;
        errors = 0;
        for (int y = 0; y < 240; y++)
            for (int x = 0; x < 320; x++) begin
                @(negedge rd_clk); rd_x = 9'(x); rd_y = 8'(y);
                @(negedge rd_clk);                                       // registered read: the value is out now
                want = value_of(2 * x, 2 * y, frame);
                if (rd_pixel !== want) begin
                    errors++;
                    if (errors <= 5) $display("FAIL: frame %0d, stored (%0d,%0d) = %04h, expected %04h (camera pixel (%0d,%0d))", frame, x, y, rd_pixel, want, 2 * x, 2 * y);
                end
                if (rdp_pixel !== packed_view(want)) begin
                    errors++;
                    if (errors <= 5) $display("FAIL: packed: frame %0d, stored (%0d,%0d) = %04h, expected %04h", frame, x, y, rdp_pixel, packed_view(want));
                end
            end
        if (errors) fails++;
        $display("frame %0d: %0d of %0d stored pixels read back correctly", frame, 320 * 240 - errors, 320 * 240);
    endtask

    initial begin
        `ifdef VERILATOR
        if ($test$plusargs("wave")) begin $dumpfile("waveform.fst"); $dumpvars(0, dut); end
        `else
        $dumpfile("waveform.vcd"); $dumpvars(0, dut);
        `endif
        write_frame(0);
        repeat (4) @(negedge wr_clk);
        read_and_check(0);
        write_frame(1);
        repeat (4) @(negedge wr_clk);
        read_and_check(1);

        // ---- part 2 ----
        reader_on = 1;
        for (int f = 1; f <= 6; f++) camera_frame(f);             // 6 camera frames, ~200 ms; the reader completes ~60 frames
        repeat (2000) @(negedge rd_clk);
        $display("part 2: reader completed %0d frames; 3 banks: %0d torn, camera frames shown in order %p; 3 banks packed: %0d torn, shown %p; 2 banks: %0d torn, shown %p",
                 frames_read, torn3, shown3, torn3p, shown3p, torn2, shown2);
        if (torn3 != 0) begin fails++; $display("FAIL: BUFFERS = 3: %0d displayed frames mixed two camera frames (tearing)", torn3); end
        if (torn3p != 0 || shown3p != shown3) begin fails++; $display("FAIL: BUFFERS = 3 PACKED: %0d torn, or a different sequence from the unpacked one", torn3p); end
        if (torn2 != 0) begin fails++; $display("FAIL: BUFFERS = 2: %0d displayed frames mixed two camera frames (tearing)", torn2); end
        // 3 banks: frames 1..5 all appear (6 is still being written, or just done, when the run ends), in order, after the initial empty bank (0)
        if (!(shown3.size() >= 6 && shown3[1] == 1 && shown3[2] == 2 && shown3[3] == 3 && shown3[4] == 4 && shown3[5] == 5))
            begin fails++; $display("FAIL: BUFFERS = 3 should show every camera frame in order (1,2,3,4,5,...)"); end
        // 2 banks: every other frame (which parity depends on where the reader was at the first frame_start), in order, none mixed
        if (!(shown2.size() >= 3 && shown2[1] <= 2 && shown2[2] == shown2[1] + 2 && shown2[$] == shown2[1] + 2 * (shown2.size() - 2)))
            begin fails++; $display("FAIL: BUFFERS = 2 should show every other camera frame (1,3,5,... or 2,4,6,...)"); end
        if (fails == 0) $display("PASS: frame_buffer keeps every second pixel of every second row, addressed as y*320+x, across two clocks (packed: the top 4 bits of each channel); 3 banks (packed or not) show every frame whole, 2 banks every other frame whole");
        else $display("FAILED: %0d problem(s)", fails);
        $finish;
    end
endmodule
