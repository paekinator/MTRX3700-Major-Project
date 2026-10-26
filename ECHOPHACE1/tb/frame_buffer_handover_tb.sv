`timescale 1ns/1ps
/*
 *  frame_buffer_handover_tb -- frame_buffer's bank handover (BUFFERS = 2 and 3) when the camera's frame start
 *  and the display's frame top come close together.
 *
 *  The clocks are the board's: the camera writes at PCLK (40 MHz) and the display reads at 25 MHz. Every pixel
 *  carries the number of its camera frame, in bits that the packing keeps, so each frame the display reads can
 *  be checked: it must be ONE camera frame, whole, from its top line to its bottom one. Three buffers take the
 *  same camera stream and are read at the same addresses: three banks, three banks packed, and two banks.
 *
 *  Part 1: the display's frame top within a few hundred nanoseconds of the camera's frame start. Here the
 *  display reads each stored row once, at the screen's pace, so it presents (0,0) only at its frame top. Before
 *  each try it has had no frame top since the camera's previous frame start, as if it were slower than the
 *  camera, so it is still on an older frame than the newest complete one. Then it takes its frame top at a set
 *  time from the next frame start, and one ordinary frame after that. 15 tries, one display clock apart, from
 *  about 200 ns before the frame start to about 360 ns after.
 *  Part 2: camera_display as the display, with the VGA Controller's ready pattern (the 640 visible clocks of each
 *  of the 480 visible lines; 800 clocks a line, 525 lines a frame). It shows each stored row on two screen lines,
 *  so it presents (0,0) at the end of the previous frame and again at the end of its first line. The camera's
 *  frame start comes between the two, or just after the second: 6 tries.
 *
 *  Run, from the project folder (about 20 s in our tests):
 *      verilator -Wno-fatal --timing --top frame_buffer_handover_tb --cc tb/frame_buffer_handover_tb.sv \
 *          rtl/camera_pkg.sv rtl/frame_buffer.sv rtl/camera_display.sv --main --exe -CFLAGS -O1
 *      make -s -C obj_dir -f Vframe_buffer_handover_tb.mk Vframe_buffer_handover_tb VM_PARALLEL_BUILDS=0
 *      ./obj_dir/Vframe_buffer_handover_tb
 */
module frame_buffer_handover_tb;
    logic wr_clk = 0; always #12.5 wr_clk = ~wr_clk;      // PCLK, 40 MHz
    logic rd_clk = 0; always #20.0 rd_clk = ~rd_clk;      // the display's clock, 25 MHz

    // ---- the camera ------------------------------------------------------------------------------------------
    localparam int  LINE     = 1568;                      // PCLKs a line (784 pixel times of two clocks)
    localparam real FRAME_NS = 507.0 * LINE * 25.0;       // 17 blank lines, 480 rows, 10 blank lines: 19.87 ms
    logic        fs = 0, valid = 0;
    logic [9:0]  cam_x = 0;
    logic [8:0]  cam_y = 0;
    logic [15:0] cam_px = 0;
    int          sent = 0;                                // camera frames begun
    real         fs_at = 0.0, fs_first = 0.0;             // the clock edge that took the latest (the first) frame_start

    // a pixel carries its camera frame f in bits that RGB444 keeps (15:12 and 10:7), and its row in 4:0
    function automatic logic [15:0] pixel_of(input int f, input int y);
        return {4'(f >> 4), 1'b0, 4'(f), 2'b00, 5'(y)};
    endfunction
    function automatic int frame_of(input logic [15:0] p);
        return int'({p[15:12], p[10:7]});
    endfunction

    // one camera frame: frame_start on the first clock, 17 blank lines, 480 rows of 640 pixels (one every second
    // clock, then 288 blank clocks), 10 blank lines; 507 x 1568 clocks in all
    task automatic camera_frame();
        sent++;
        @(negedge wr_clk); fs = 1;
        @(negedge wr_clk); fs = 0; fs_at = $realtime - 12.5;
        if (sent == 1) fs_first = fs_at;
        repeat (17 * LINE - 2) @(negedge wr_clk);
        for (int y = 0; y < 480; y++) begin
            for (int x = 0; x < 640; x++) begin
                @(negedge wr_clk); valid = 1; cam_x = 10'(x); cam_y = 9'(y); cam_px = pixel_of(sent, y);
                @(negedge wr_clk); valid = 0;
            end
            repeat (LINE - 1280) @(negedge wr_clk);
        end
        repeat (10 * LINE) @(negedge wr_clk);
    endtask

    // ---- three buffers on the same stream, read at the same addresses ---------------------------------------
    wire  [8:0]  rd_x;
    wire  [7:0]  rd_y;
    wire  [15:0] px [3];
    frame_buffer #(.W(320), .H(240), .DW(16), .DECIMATE(2), .BUFFERS(3), .PACKED(0)) fb3 (
        .wr_clk(wr_clk), .wr_frame_start(fs), .wr_valid(valid), .wr_x(cam_x), .wr_y(cam_y), .wr_pixel(cam_px),
        .rd_clk(rd_clk), .rd_x(rd_x), .rd_y(rd_y), .rd_pixel(px[0]));
    frame_buffer #(.W(320), .H(240), .DW(16), .DECIMATE(2), .BUFFERS(3), .PACKED(1)) fb3p (
        .wr_clk(wr_clk), .wr_frame_start(fs), .wr_valid(valid), .wr_x(cam_x), .wr_y(cam_y), .wr_pixel(cam_px),
        .rd_clk(rd_clk), .rd_x(rd_x), .rd_y(rd_y), .rd_pixel(px[1]));
    frame_buffer #(.W(320), .H(240), .DW(16), .DECIMATE(2), .BUFFERS(2), .PACKED(0)) fb2 (
        .wr_clk(wr_clk), .wr_frame_start(fs), .wr_valid(valid), .wr_x(cam_x), .wr_y(cam_y), .wr_pixel(cam_px),
        .rd_clk(rd_clk), .rd_x(rd_x), .rd_y(rd_y), .rd_pixel(px[2]));
    function automatic string name_of(input int i);
        return (i == 0) ? "3 banks" : (i == 1) ? "3 banks packed" : "2 banks";
    endfunction

    // the read address: part 1's display, or camera_display in part 2
    logic        part2 = 0;
    logic [8:0]  r_x = 0;
    logic [7:0]  r_y = 0;
    logic        disp_reset = 1, ready = 0;
    wire  [8:0]  d_x;
    wire  [7:0]  d_y;
    wire  [29:0] d_data;
    wire         sop, eop, d_valid;
    camera_display #(.H_RES(640), .V_RES(480), .W(320), .H(240)) disp (
        .clk(rd_clk), .reset(disp_reset), .hold_enable(1'b1), .rd_x(d_x), .rd_y(d_y), .rd_pixel(px[0]),
        .data(d_data), .startofpacket(sop), .endofpacket(eop), .valid(d_valid), .ready(ready));
    assign rd_x = part2 ? d_x : r_x;
    assign rd_y = part2 ? d_y : r_y;

    // ---- the check: every frame read is one camera frame ---------------------------------------------------
    int frame_f  [3];                                     // the frame's camera frame (its first pixel's)
    int row_f    [3][480];                                // each row's (part 1: stored rows; part 2: screen lines)
    bit torn_now [3];
    function automatic void frame_begin();
        for (int i = 0; i < 3; i++) begin
            frame_f[i] = -1; torn_now[i] = 0;
            for (int r = 0; r < 480; r++) row_f[i][r] = -1;
        end
    endfunction
    function automatic void sample(input int row);       // the pixel each buffer gives now
        for (int i = 0; i < 3; i++) begin
            int f;
            f = frame_of(px[i]);
            if (frame_f[i] < 0) frame_f[i] = f; else if (f != frame_f[i]) torn_now[i] = 1;
            if (row_f[i][row] < 0) row_f[i][row] = f;
        end
    endfunction
    // "7" for a whole frame; "7 (rows 0-53), 5 (rows 54-239)" for a torn one
    function automatic string what_of(input int i, input int n, input string unit);
        string s;
        int    r0;
        if (!torn_now[i]) return $sformatf("%0d", frame_f[i]);
        s = ""; r0 = 0;
        for (int r = 1; r <= n; r++)
            if (r == n || row_f[i][r] != row_f[i][r0]) begin
                s = {s, (r0 == 0) ? "" : ", ", $sformatf("%0d (%s %0d-%0d)", row_f[i][r0], unit, r0, r - 1)};
                r0 = r;
            end
        return {"TORN: ", s};
    endfunction

    // ---- part 1: a display that presents (0,0) only at its frame top ---------------------------------------
    // It reads each stored row once, one pixel every second clock, in the first of the two screen lines that show
    // it, and holds its last address otherwise: the frame top, 45 lines of vertical blanking at (0,0), then 240
    // rows of 1600 clocks. The frame top comes at the first clock edge at or after `when`.
    real top_at = 0.0;
    task automatic reader_frame(input real when);
        while ($realtime + 20.0 < when) @(negedge rd_clk);    // waiting at the end of the last frame, at (319,239)
        r_x = 0; r_y = 0; top_at = $realtime + 20.0;          // the frame top
        repeat (45 * 800 + 160) @(negedge rd_clk);
        frame_begin();
        for (int y = 0; y < 240; y++) begin
            for (int c = 0; c < 640; c++) begin
                r_x = 9'(c >> 1); r_y = 8'(y);
                @(negedge rd_clk);
                if (c % 2 == 1) sample(y);                     // the pixel read at the edge just gone
            end
            repeat (960) @(negedge rd_clk);                    // the rest of the line, and the line that repeats it
        end
    endtask

    // ---- part 2: camera_display, with the VGA Controller's ready -------------------------------------------
    task automatic vga_frame();
        for (int v = 0; v < 525; v++)
            for (int h = 0; h < 800; h++) begin
                @(negedge rd_clk); ready = (v < 480) && (h < 640);
            end
    endtask
    event top_ev;                                         // camera_display's last handshake of a frame: (0,0) presented
    real  d_top_at = 0.0;
    int   m_frames = 0, watch = -1, torn_p2 [3], shown_p2 [3][$];
    string trial_msg = "";
    // where the camera's frame start fell: the second (0,0) comes 36,800 clocks (1472 us) after the first
    always @(posedge wr_clk) if (part2 && fs)
        trial_msg = $sformatf("frame start %7.1f us after the display's first (0,0), %s", ($realtime - d_top_at) / 1000.0,
                              ($realtime - d_top_at < 1446400.0) ? "in its vertical blanking" :
                              ($realtime - d_top_at < 1472000.0) ? "in its first line" : "after its second (0,0)");
    always @(posedge rd_clk) if (part2 && d_valid && ready) begin
        if (sop) frame_begin();
        sample(int'(disp.y));
        if (eop) begin
            m_frames++;
            for (int i = 0; i < 3; i++) begin
                if (torn_now[i]) torn_p2[i]++;
                if (shown_p2[i].size() == 0 || shown_p2[i][$] != frame_f[i]) shown_p2[i].push_back(frame_f[i]);
            end
            if (m_frames == watch)
                $display("part 2, %s: %s %s; %s %s; %s %s", trial_msg, name_of(0), what_of(0, 480, "lines"),
                         name_of(1), what_of(1, 480, "lines"), name_of(2), what_of(2, 480, "lines"));
            d_top_at = $realtime; -> top_ev;
        end
    end

    // ---- the run --------------------------------------------------------------------------------------------
    localparam int N1 = 15;
    int  fails = 0, torn_p1 [3], shown_p1 [3][$], first_p2;
    real offset_ns [6] = '{1000.0, 700000.0, 1440000.0, 1460000.0, 1471000.0, 1472500.0};
    function automatic bit rises(input int q [$]);       // never goes back
        for (int j = 1; j < q.size(); j++) if (q[j] < q[j - 1]) return 0;
        return 1;
    endfunction
    function automatic bit has(input int q [$], input int v);
        foreach (q[j]) if (q[j] == v) return 1;
        return 0;
    endfunction
    function automatic string list_of(input int q [$]);
        string s;
        s = "";
        foreach (q[j]) s = {s, (j == 0) ? "" : " ", $sformatf("%0d", q[j])};
        return s;
    endfunction
    initial begin
        `ifdef VERILATOR
        if ($test$plusargs("wave")) begin $dumpfile("waveform.fst"); $dumpvars(0, fb3); end
        `endif
        // ---- part 1 ----
        fork
            repeat (2 * N1 + 1) camera_frame();
            begin
                reader_frame(0.0);                                        // one frame to begin with
                for (int k = 0; k < N1; k++) begin
                    real fs_try;
                    fs_try = fs_first + (2 * k + 2) * FRAME_NS;           // camera frame 2k+3's frame start
                    reader_frame(fs_try + (k - 5) * 40.0);                // the try
                    for (int i = 0; i < 3; i++) begin
                        if (torn_now[i]) torn_p1[i]++;
                        shown_p1[i].push_back(frame_f[i]);
                    end
                    $display("part 1, frame top %6.1f ns %s the frame start of camera frame %0d: %s %s; %s %s; %s %s",
                             (top_at >= fs_try) ? top_at - fs_try : fs_try - top_at, (top_at >= fs_try) ? "after " : "before",
                             2 * k + 3, name_of(0), what_of(0, 240, "rows"), name_of(1), what_of(1, 240, "rows"),
                             name_of(2), what_of(2, 240, "rows"));
                    reader_frame(0.0);                                    // an ordinary frame: up to date again
                    for (int i = 0; i < 3; i++) if (torn_now[i]) begin
                        torn_p1[i]++;
                        $display("part 1, the ordinary frame after that: %s %s", name_of(i), what_of(i, 240, "rows"));
                    end
                end
            end
        join
        for (int i = 0; i < 3; i++) begin
            if (torn_p1[i] != 0) begin fails++; $display("FAIL: part 1: %s: %0d of %0d frames torn", name_of(i), torn_p1[i], 2 * N1); end
            else if (!rises(shown_p1[i]) || shown_p1[i][N1 - 1] < shown_p1[i][0] + N1 / 2)
                begin fails++; $display("FAIL: part 1: %s: the frames shown went back or did not move on: %s", name_of(i), list_of(shown_p1[i])); end
        end
        if (torn_p1[0] == 0 && torn_p1[1] == 0 && torn_p1[2] == 0)
            $display("part 1: no frame torn in %0d tries; camera frames shown: 3 banks %s; 2 banks %s", N1, list_of(shown_p1[0]), list_of(shown_p1[2]));

        // ---- part 2 ----
        part2 = 1;
        repeat (3) @(negedge rd_clk); disp_reset = 0;
        first_p2 = sent + 1;
        fork
            forever vga_frame();
            begin
                for (int k = 0; k < 6; k++) begin
                    @(top_ev);
                    watch = m_frames + 1;                                 // the display frame this top begins
                    #(offset_ns[k]);
                    camera_frame();
                end
                camera_frame();                                           // its frame start completes the last try's frame
                repeat (2) @(top_ev);                                     // which then shows
            end
        join_any
        disable fork;
        for (int i = 0; i < 3; i++)
            if (torn_p2[i] != 0) begin fails++; $display("FAIL: part 2: %s: %0d of %0d frames torn", name_of(i), torn_p2[i], m_frames); end
        // three banks show every camera frame of part 2, in order; two banks every other one
        for (int i = 0; i < 2; i++)
            for (int f = first_p2; f < first_p2 + 6; f++)
                if (!has(shown_p2[i], f)) begin fails++; $display("FAIL: part 2: %s never showed camera frame %0d: %s", name_of(i), f, list_of(shown_p2[i])); break; end
        if (!rises(shown_p2[2]) || shown_p2[2][$] < first_p2 + 3)
            begin fails++; $display("FAIL: part 2: 2 banks: the frames shown went back or did not move on: %s", list_of(shown_p2[2])); end
        $display("part 2: %0d display frames; camera frames shown: 3 banks %s; 2 banks %s", m_frames, list_of(shown_p2[0]), list_of(shown_p2[2]));

        if (fails == 0) $display("PASS: frame_buffer_handover_tb: with the frame top beside the frame start, and with camera_display's two (0,0)s a frame, every frame read is one camera frame, whole (3 banks, 3 banks packed, 2 banks)");
        else $display("FAILED: %0d problem(s)", fails);
        $finish;
    end
endmodule
