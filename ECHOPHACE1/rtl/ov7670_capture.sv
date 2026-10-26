/*
 *  ov7670_capture.sv -- turn the camera's video port into a pixel stream with coordinates.
 *
 *  What the camera drives (datasheet Figure 6, p.7; Figure 11, p.9), all changing after the
 *  FALLING edge of PCLK, so this module samples on the RISING edge:
 *    VSYNC  high for three lines at the start of every frame, low during the picture;
 *    HREF   high while one row's bytes are on D[7:0], 640 pixels = 1280 PCLKs, then low for the
 *           horizontal blanking; 480 such rows per frame, 17 blank lines after VSYNC, 10 before;
 *    D[7:0] two bytes per pixel in RGB565 (COM7 = 0x04 and COM15 = 0xD0 in ov7670_config.sv, after
 *           its software reset): {R[4:0], G[5:3]} then {G[2:0], B[4:0]}.
 *
 *  Out comes the same stream your Assignment 2 raster_source produced from a ROM, only now it is
 *  live: `valid` for one PCLK per pixel with the pixel's 16 bits and its (x, y), and `frame_start`
 *  once per frame. Nothing here depends on the picture size; the counters just follow HREF and
 *  VSYNC. There is no clock other than PCLK: the camera's clock is the only one that knows when a
 *  byte is valid (see the SDC for how Quartus is told about it). Every input is registered once, straight
 *  off the pin, before any logic looks at it: one cycle of latency on all of them together, which nothing
 *  downstream can tell, and the shortest pin-to-flop path (FAST_INPUT_REGISTER in the .qsf puts these
 *  flops in the I/O cells). At PCLK = 40 MHz the data is stable for only a few nanoseconds before the
 *  rising edge, so that path has to be short.
 *
 *  Which edge. The datasheet (Table 4) has the outputs changing 0 to 5 ns after the FALLING edge, so
 *  sampling on that edge catches them while they change, and the colours come out wrong. The rising
 *  edge, half a period later, is the place to sample. Leave SAMPLE_ON_FALL at 0.
 */
module ov7670_capture #(
    parameter bit INPUT_STAGE    = 1,  // 1: register every pin once before any logic (I/O cell flops); 0: the logic reads the pins directly
    parameter bit SAMPLE_ON_FALL = 0   // 1: latch the pins on the FALLING edge of PCLK (wrong on this chip); 0: on the rising edge, as the datasheet reads
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
    logic       vsync_r, href_r;       // the pins, registered once straight off the I/O
    logic [7:0] d_r;
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
