/*
 *  ov7670_capture.sv -- turn the camera's video port into a pixel stream with coordinates.
 *
 *  What the camera drives (datasheet Figure 6, p.7; Figure 11, p.9), all changing after the
 *  FALLING edge of PCLK, so this module samples on the RISING edge:
 *    VSYNC  high for three lines at the start of every frame, low during the picture;
 *    HREF   high while one row's bytes are on D[7:0], 640 pixels = 1280 PCLKs, then low for the
 *           horizontal blanking; 480 such rows per frame, 17 blank lines after VSYNC, 10 before;
 *    D[7:0] two bytes per pixel in RGB565: {R[4:0], G[5:3]} then {G[2:0], B[4:0]}.
 *
 *  Out comes the same stream your Assignment 2 raster_source produced from a ROM, only now it is
 *  live: `valid` for one PCLK per pixel with the pixel's 16 bits and its (x, y), and `frame_start`
 *  once per frame. Nothing here depends on the picture size; the counters just follow HREF and
 *  VSYNC. There is no clock other than PCLK: the camera's clock is the only one that knows when a
 *  byte is valid (see the SDC for how Quartus is told about it). Every input is registered once, straight
 *  off the pin, before any logic looks at it: one cycle of latency on all of them together, which nothing
 *  downstream can tell, and the shortest pin-to-flop path.
 *
 *  Which edge. The datasheet (Table 4, Figure 6) has the outputs changing up to 5 ns after the FALLING edge,
 *  which would make the rising edge the place to sample. The board says otherwise: with the capture flops in
 *  the I/O cells (sampling a few nanoseconds after the rising edge as the clock reaches them), 40 and 50 MHz
 *  builds showed columns of unrelated colours at the left of every row and a green cast, i.e. bits caught
 *  mid-transition, while the same flops in the core (sampling right at the edge) were clean, and the 2025 code's
 *  100 MHz could never have worked under the datasheet timing. So the data moves just after the RISING edge,
 *  and the middle of its valid window is the FALLING edge: SAMPLE_ON_FALL = 1 latches the pins there (the way
 *  the hamsterworks capture always did) and hands them to the rising-edge logic half a cycle later.
 */
module ov7670_capture #(
    parameter bit INPUT_STAGE    = 1,  // 1: register every pin once before any logic (I/O cell flops); 0: the logic reads the pins directly
    parameter bit SAMPLE_ON_FALL = 0   // 1: latch the pins on the FALLING edge of PCLK (see below); 0: on the rising edge, as the datasheet reads
) (
    input  logic        pclk,          // camera PCLK: the clock of this module
    input  logic        vsync,         // camera VSYNC
    input  logic        href,          // camera HREF
    input  logic [7:0]  d,             // camera D[7:0]
    output logic        frame_start,   // one PCLK, when VSYNC drops: the frame's rows follow
    output logic        valid,         // one PCLK per complete pixel
    output logic [15:0] pixel,         // {first byte, second byte}: RGB565 as configured
    output logic [9:0]  x,             // column of `pixel`, 0..639
    output logic [8:0]  y              // row of `pixel`, 0..479
);
    logic       vsync_r, href_r;       // the pins, registered once straight off the I/O (FAST_INPUT_REGISTER in the .qsf puts
    logic [7:0] d_r;                   //   these flops in the I/O cells: the shortest possible path, which matters at 50 MHz)
    logic       vsync_q, href_q;       // last cycle's values, for the edges
    logic       second;                // 0: the next byte is a pixel's first byte, 1: its second
    logic [7:0] first_byte;
    logic [9:0] col;                   // pixels completed on this row
    logic [8:0] row;                   // rows completed in this frame

    generate if (!INPUT_STAGE) begin : g_direct
        assign vsync_r = vsync;
        assign href_r  = href;
        assign d_r     = d;
    end else if (SAMPLE_ON_FALL) begin : g_fall
        always_ff @(negedge pclk) begin
            vsync_r <= vsync;
            href_r  <= href;
            d_r     <= d;
        end
    end else begin : g_rise
        always_ff @(posedge pclk) begin
            vsync_r <= vsync;
            href_r  <= href;
            d_r     <= d;
        end
    end endgenerate

    always_ff @(posedge pclk) begin
        vsync_q     <= vsync_r;
        href_q      <= href_r;
        frame_start <= vsync_q & ~vsync_r;        // falling edge of VSYNC
        valid       <= 1'b0;
        if (vsync_r) begin                        // between frames
            row    <= '0;
            col    <= '0;
            second <= 1'b0;
        end
        else if (href_r) begin                    // a row's bytes are on the bus
            second <= ~second;
            if (!second)
                first_byte <= d_r;
            else begin
                pixel <= {first_byte, d_r};
                x     <= col;
                y     <= row;
                valid <= 1'b1;
                col   <= col + 1'b1;
            end
        end
        else begin                                // horizontal blanking
            second <= 1'b0;
            col    <= '0;
            if (href_q) row <= row + 1'b1;        // HREF just fell: that row is done
        end
    end
endmodule
