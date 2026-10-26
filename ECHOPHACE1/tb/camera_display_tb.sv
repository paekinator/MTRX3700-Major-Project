`timescale 1ns/1ps
/*
 *  camera_display_tb -- the Avalon-ST source against the VGA Controller + monitor model.
 *
 *  A frame buffer is filled through its write port with a test picture (colour bars with a
 *  diagonal), then camera_display streams it into vga_monitor_model, which behaves like the
 *  University Program VGA Controller (startofpacket sync, ready low in blanking, random stalls)
 *  and writes each completed frame to display_frame_<n>.ppm -> tools/render_frames.py -> .png.
 *  The screen is 160x120 here (H_RES/V_RES parameters) so that three frames take a second;
 *  the stored picture is 80x60 and each stored pixel shows as a 2x2 block, as on the board.
 *  PASS: no protocol errors from the model, three frames, and the monitor's pixel (0,0) and
 *  (159,119) are what the buffer holds at (0,0) and (79,59).
 *
 *  Run:  ./simulate.sh display
 */
module camera_display_tb;
    localparam int H_RES = 160, V_RES = 120, W = 80, H = 60;
    logic clk = 0; always #20 clk = ~clk;
    logic reset = 1;

    // the frame buffer, filled from here
    logic        wr_valid = 0; logic [9:0] wr_x = 0; logic [8:0] wr_y = 0; logic [15:0] wr_pixel = 0;
    wire  [$clog2(W)-1:0] rd_x; wire [$clog2(H)-1:0] rd_y; wire [15:0] rd_pixel;
    frame_buffer #(.W(W), .H(H), .DW(16), .DECIMATE(2)) fb (
        .wr_clk(clk), .wr_frame_start(1'b0), .wr_valid(wr_valid), .wr_x(wr_x), .wr_y(wr_y), .wr_pixel(wr_pixel),
        .rd_clk(clk), .rd_x(rd_x), .rd_y(rd_y), .rd_pixel(rd_pixel));

    wire [29:0] data; wire sop, eop, valid, ready;
    camera_display #(.H_RES(H_RES), .V_RES(V_RES), .W(W), .H(H)) dut (
        .clk(clk), .reset(reset), .hold_enable(1'b1), .rd_x(rd_x), .rd_y(rd_y), .rd_pixel(rd_pixel),
        .data(data), .startofpacket(sop), .endofpacket(eop), .valid(valid), .ready(ready));

    int frames_done, errors, x_pos, y_pos; logic accept, discard;
    vga_monitor_model #(.H_RES(H_RES), .V_RES(V_RES), .H_BLANK(H_RES/4), .V_BLANK(V_RES/10), .RANDOM_STALL_PCT(5),
                        .ASCII_ART(1), .ASCII_COLS(80), .PPM_PREFIX("display_frame"), .MAX_PPM_FILES(3), .VERBOSE(1)) mon (
        .clk(clk), .reset(reset), .data(data), .startofpacket(sop), .endofpacket(eop), .valid(valid), .ready(ready),
        .frames_done(frames_done), .errors(errors), .x_pos(x_pos), .y_pos(y_pos), .accept(accept), .discard(discard));

    // the test picture: 8 colour bars, a white diagonal, in RGB565
    function automatic logic [15:0] picture(input int x, input int y);   // x,y in the 2W x 2H camera space
        logic [15:0] bars [0:7] = '{16'hFFFF, 16'hFFE0, 16'h07FF, 16'h07E0, 16'hF81F, 16'hF800, 16'h001F, 16'h0000};
        if (x / 2 == y / 2) return 16'hFFFF;
        return bars[(x * 8) / (2 * W)];
    endfunction

    // sample what the monitor accepts at three positions (its frame store is cleared after each frame)
    logic [23:0] px_00, px_last, px_bottom_left;
    always @(posedge clk) if (accept) begin
        if (x_pos == 0 && y_pos == 0)                 px_00 <= {data[29:22], data[19:12], data[9:2]};
        if (x_pos == H_RES - 1 && y_pos == V_RES - 1) px_last <= {data[29:22], data[19:12], data[9:2]};
        if (x_pos == 0 && y_pos == V_RES - 1)         px_bottom_left <= {data[29:22], data[19:12], data[9:2]};
    end

    int fails = 0;
    initial begin
        `ifdef VERILATOR
        if ($test$plusargs("wave")) begin $dumpfile("waveform.fst"); $dumpvars(0, dut); $dumpvars(0, mon); end
        `else
        $dumpfile("waveform.vcd"); $dumpvars(0, dut);
        `endif
        // fill the buffer: the writer keeps every second pixel of every second row
        for (int y = 0; y < 2 * H; y++) for (int x = 0; x < 2 * W; x++) begin
            @(negedge clk); wr_valid = 1; wr_x = 10'(x); wr_y = 9'(y); wr_pixel = picture(x, y);
        end
        @(negedge clk); wr_valid = 0;
        repeat (3) @(negedge clk); reset = 0;
        fork
            wait (frames_done == 3);
            begin #20ms; $display("FAIL: %0d frames in 20 ms: is startofpacket high on pixel (0,0)?", frames_done); $display("FAILED: 1 problem"); $finish; end
        join_any
        disable fork;
        #100;
        if (errors != 0) begin fails++; $display("FAIL: the VGA model counted %0d protocol errors", errors); end
        if (px_00 != 24'hFFFFFF)          begin fails++; $display("FAIL: screen (0,0) = %06h, expected white (the diagonal)", px_00); end
        if (px_last != 24'h000000)        begin fails++; $display("FAIL: screen (%0d,%0d) = %06h, expected black (the last bar)", H_RES - 1, V_RES - 1, px_last); end
        if (px_bottom_left != 24'hFFFFFF) begin fails++; $display("FAIL: screen (0,%0d) = %06h, expected white (bar 0)", V_RES - 1, px_bottom_left); end
        if (fails == 0) $display("PASS: camera_display drew %0d frames of %0dx%0d with no Avalon-ST protocol errors; see display_frame_1.png", frames_done, H_RES, V_RES);
        else $display("FAILED: %0d problem(s)", fails);
        $finish;
    end
endmodule
