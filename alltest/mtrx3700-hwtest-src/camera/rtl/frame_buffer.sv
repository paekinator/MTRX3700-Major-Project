/*
 *  frame_buffer.sv -- one, two or three pictures in on-chip memory, written by the camera, read by the display.
 *
 *  Two clocks meet here and nowhere else. The camera writes at its own PCLK (25 MHz, one pixel
 *  every two clocks, 31 frames a second); the display reads at the VGA pixel clock (25 MHz too,
 *  but a different oscillator: 60 frames a second, and never in step). A Cyclone V M10K block has
 *  two ports with independent clocks, so the memory itself is the clock-domain crossing: nothing
 *  is synchronised, each side just uses its own port.
 *
 *  The camera's 640x480 does not fit: 307,200 x 16 bits = 4.9 Mbit, and the chip has 4.45 Mbit
 *  in total. So the writer keeps one pixel in DECIMATE (2) along each row and one row in DECIMATE:
 *  320x240 x 16 bits = 1.23 Mbit. That is decimation without a filter (Lesson 4 would frown), and
 *  it is also exactly the size the Assignment 2 pipeline works on. Quartus infers the RAM from
 *  the two always blocks below (simple dual-port, dual clock); no wizard file is needed.
 *
 *  How much memory a picture takes is not the bit count: an M10K block is 256 x 40, 512 x 20,
 *  1024 x 10 ..., so a 16-bit word sits in a 20-bit slot and a 320x240 picture is 150 of the
 *  DE1-SoC's 397 blocks. With PACKED = 1 the pixels are stored as RGB444 (the top four bits of
 *  each channel, what the 2025 code stored too) and THREE of them fill a 40-bit word: 100 blocks
 *  per picture. The interface stays RGB565 in and out; the low bits are the only thing lost.
 *
 *  BUFFERS = 1  one picture. A displayed frame can be half old and half new (tearing) when the
 *               writer overtakes the reader mid-frame: a moving hand shows a seam. The smallest
 *               thing that works. 150 blocks, or 100 packed.
 *  BUFFERS = 3  no tearing, every camera frame shown: one bank is being written, one is being
 *               read, one holds the last complete frame. The display is faster than the camera, so
 *               it shows each frame twice and is never waiting. 450 blocks at 16 bits, which the
 *               chip does not have; 300 packed, which it does (the default in the top level).
 *  BUFFERS = 2  no tearing, but only every OTHER camera frame is stored (15 fps): while the
 *               display is still on the frame before last, the only bank free is the one it is
 *               about to switch to, so the writer sits that frame out. (Two banks would be enough
 *               if the two sides ran in step; they do not, which is the whole point.) 300 / 200.
 *
 *  How the banks are handed over: at `wr_frame_start` (the camera's VSYNC falling edge, from
 *  ov7670_capture: the previous frame is complete by then, and the next one's pixels are 17 lines
 *  away) the writer marks the bank it just filled as `done`, then picks its next bank as one that
 *  is neither `done` nor the one the reader is on; if there is none it skips the frame. The reader
 *  switches to `done` only at its own start of frame, so what it shows is always one complete
 *  camera frame. The two bank numbers cross clock domains as a stable value plus a toggle bit,
 *  each toggle through two flip-flops (Lesson 4 1.3: the value is written a clock before the
 *  toggle flips, and read only after the toggle has been seen to change).
 */
module frame_buffer #(
    parameter int W        = 320,      // stored picture (W <= 511 when PACKED)
    parameter int H        = 240,
    parameter int DW       = 16,       // bits per pixel at the ports (RGB565; must be 16 when PACKED)
    parameter int DECIMATE = 2,        // keep every DECIMATE-th column and row of the input
    parameter int BUFFERS  = 1,        // 1, 2 or 3 (see above)
    parameter bit PACKED   = 0         // 1: RGB444 inside, three pixels per 40-bit word (100 M10K per picture instead of 150)
) (
    // write side: the camera's stream (full resolution coordinates)
    input  logic                 wr_clk,
    input  logic                 wr_frame_start,   // one wr_clk at the start of every camera frame (unused when BUFFERS = 1)
    input  logic                 wr_valid,
    input  logic [9:0]           wr_x,
    input  logic [8:0]           wr_y,
    input  logic [DW-1:0]        wr_pixel,
    // read side: registered, the pixel appears one rd_clk after the address
    input  logic                 rd_clk,
    input  logic [$clog2(W)-1:0] rd_x,
    input  logic [$clog2(H)-1:0] rd_y,
    output logic [DW-1:0]        rd_pixel
);
    localparam int WPR  = PACKED ? (W + 2) / 3 : W;   // words per row
    localparam int PIC  = WPR * H;                     // words per picture
    localparam int MEMW = PACKED ? 40 : DW;            // bits per word
    localparam int MW   = $clog2(BUFFERS * PIC);       // memory address
    localparam int QW   = $clog2(WPR);                 // word-in-row

    logic [MEMW-1:0] mem [0:BUFFERS*PIC-1];

    // ---- which bank is written, which is done, which is read: the write clock's view -------------
    logic [1:0] wr_bank   = 2'd0;                      // being written
    logic [1:0] done_bank = 2'd1;                      // the last complete frame (bank 1 is empty at power-up: the display shows black)
    logic       wr_active = 1'b1;                      // 0: this camera frame is being skipped (BUFFERS = 2)
    logic       done_tgl  = 1'b0, done_set = 1'b0;     // toggles one clock after done_bank changes
    logic [2:0] rd_tgl_s  = '0;                        // the reader's toggle, synchronised
    logic [1:0] rd_bank_w = 2'd1;                      // the reader's bank, as last reported
    logic [3:0] fs_q      = '0;                        // frame_start delayed: the pick happens 4 clocks after, once rd_bank_w is fresh
    logic [1:0] rd_bank   = 2'd1;                      // the reader's bank: a read-clock register, declared here so the write side can capture it
    logic       rd_tgl    = 1'b0;

    // a bank that is neither done nor being read; 3 = none
    function automatic logic [1:0] pick(input logic [1:0] d, input logic [1:0] r);
        for (int b = 0; b < BUFFERS; b++) if (2'(b) != d && 2'(b) != r) return 2'(b);
        return 2'd3;
    endfunction

    generate if (BUFFERS > 1) begin : g_wbank
        logic [1:0] next_bank;
        always_ff @(posedge wr_clk) begin
            fs_q     <= {fs_q[2:0], wr_frame_start};
            done_set <= 1'b0;
            rd_tgl_s <= {rd_tgl_s[1:0], rd_tgl};
            if (rd_tgl_s[2] != rd_tgl_s[1]) rd_bank_w <= rd_bank;      // the reader moved (its bank was stable a clock before it toggled)
            if (wr_frame_start && wr_active) begin done_bank <= wr_bank; done_set <= 1'b1; end
            if (done_set) done_tgl <= ~done_tgl;
            if (fs_q[3]) begin
                next_bank = pick(done_bank, rd_bank_w);
                wr_active <= (next_bank != 2'd3);
                if (next_bank != 2'd3) wr_bank <= next_bank;
            end
        end
    end endgenerate

    // ---- write port (camera clock): decimate, then address = bank * PIC + y * WPR + (x or x/3) ----
    logic            stored;                           // this input pixel is one we keep
    logic            we;
    logic [MW-1:0]   wa;
    logic [MEMW-1:0] wd;
    logic [9:0]      wx;                               // wr_x / DECIMATE  (DECIMATE is a power of two)
    logic [8:0]      wy;
    assign wx = wr_x >> $clog2(DECIMATE);
    assign wy = wr_y >> $clog2(DECIMATE);
    assign stored = wr_valid && wr_active && (wr_x[$clog2(DECIMATE)-1:0] == '0) && (wr_y[$clog2(DECIMATE)-1:0] == '0)
                             && (wx < 10'(W)) && (wy < 9'(H));

    generate if (!PACKED) begin : g_wr_plain
        always_ff @(posedge wr_clk) begin
            // registered first, so the multiply-add is not in the same cycle as the RAM write
            we <= stored;
            wa <= MW'(wr_bank) * MW'(PIC) + MW'(wy) * MW'(W) + MW'(wx);
            wd <= wr_pixel;
            if (we) mem[wa] <= wd;
        end
    end else begin : g_wr_packed
        // The stored pixels of a row arrive in order, so a word counter q and a slot counter r
        // (0, 1, 2) follow them; pixels for slots 0 and 1 wait in `slots`, and the word is written
        // when slot 2 arrives, or at the end of the row (320 = 3 x 106 + 2: the last word has two).
        logic [QW-1:0] qn = '0, q;
        logic [1:0]    rn = 2'd0, r;
        logic [23:0]   slots = '0;
        logic [11:0]   px12;
        assign px12 = {wr_pixel[15:12], wr_pixel[10:7], wr_pixel[4:1]};    // RGB565 -> RGB444: the top four bits of each channel
        assign q = (wx == 10'd0) ? QW'(0) : qn;
        assign r = (wx == 10'd0) ? 2'd0   : rn;
        always_ff @(posedge wr_clk) begin
            we <= 1'b0;
            if (stored) begin
                if (r == 2'd2) begin qn <= q + 1'b1; rn <= 2'd0; end
                else           begin qn <= q;        rn <= r + 1'b1; end
                if (r == 2'd0) slots[11:0]  <= px12;
                if (r == 2'd1) slots[23:12] <= px12;
                we <= (r == 2'd2) || (wx == 10'(W - 1));
                wa <= MW'(wr_bank) * MW'(PIC) + MW'(wy) * MW'(WPR) + MW'(q);
                case (r)
                    2'd2:    wd <= {4'b0, px12, slots[23:12], slots[11:0]};
                    2'd1:    wd <= {4'b0, 12'b0, px12, slots[11:0]};
                    default: wd <= {4'b0, 24'b0, px12};
                endcase
            end
            if (we) mem[wa] <= wd;
        end
    end endgenerate

    // ---- which bank is read: the read clock's view -----------------------------------------------
    logic [2:0] done_tgl_s  = '0;
    logic [1:0] done_bank_r = 2'd1;                    // done_bank, as last reported
    logic       rd_set = 1'b0;
    logic       frame_top, frame_top_q = 1'b0, switching;
    logic [1:0] rd_bank_now;
    assign frame_top   = (rd_x == '0) && (rd_y == '0);                 // the address of the display's first pixel: presented
    assign switching   = frame_top && !frame_top_q && (rd_bank != done_bank_r);   //   at the end of the previous frame, once
    assign rd_bank_now = (BUFFERS > 1) ? (switching ? done_bank_r : rd_bank) : 2'd0;
    generate if (BUFFERS > 1) begin : g_rbank
        always_ff @(posedge rd_clk) begin
            frame_top_q <= frame_top;
            rd_set      <= 1'b0;
            done_tgl_s  <= {done_tgl_s[1:0], done_tgl};
            if (done_tgl_s[2] != done_tgl_s[1]) done_bank_r <= done_bank;
            if (switching) begin rd_bank <= done_bank_r; rd_set <= 1'b1; end
            if (rd_set) rd_tgl <= ~rd_tgl;
        end
    end endgenerate

    // ---- read port (display clock) ------------------------------------------------------------
    generate if (!PACKED) begin : g_rd_plain
        always_ff @(posedge rd_clk)
            rd_pixel <= mem[MW'(rd_bank_now) * MW'(PIC) + MW'(rd_y) * MW'(W) + MW'(rd_x)];
    end else begin : g_rd_packed
        // word = x / 3 and slot = x mod 3, with the division done as (x * 171) >> 9: exact for x < 512
        logic [16:0]     mul;
        logic [QW-1:0]   rq;
        logic [1:0]      rr, rr_q = 2'd0;
        logic [MEMW-1:0] word_q = '0;
        logic [11:0]     p12;
        assign mul = 17'(rd_x) * 17'd171;
        assign rq  = QW'(mul >> 9);
        assign rr  = 2'(rd_x - $clog2(W)'(3 * rq));
        always_ff @(posedge rd_clk) begin
            word_q <= mem[MW'(rd_bank_now) * MW'(PIC) + MW'(rd_y) * MW'(WPR) + MW'(rq)];
            rr_q   <= rr;
        end
        assign p12 = (rr_q == 2'd0) ? word_q[11:0] : (rr_q == 2'd1) ? word_q[23:12] : word_q[35:24];
        assign rd_pixel = {p12[11:8], p12[11], p12[7:4], p12[7:6], p12[3:0], p12[3]};   // RGB444 -> RGB565 by repeating the top bits
    end endgenerate

endmodule
