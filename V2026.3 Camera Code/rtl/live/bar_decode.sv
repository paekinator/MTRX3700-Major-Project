`timescale 1ns/1ps
/*
 *  bar_decode.sv -- turn a list of edge positions into a number.
 *
 *  A barcode in this course is NB dark bars on a light background. Each bar is either narrow
 *  or wide; wide means 1. The peak picker gives us the edges in order: bar 0 starts at pos[0]
 *  and ends at pos[1], bar 1 at pos[2]..pos[3], and so on, so the width of bar i is
 *  pos[2i+1] - pos[2i]. "Wide" is judged against the narrowest bar found, times 1.5: the
 *  decoder needs no absolute size, so the same code reads at any distance. That is the same
 *  idea as normalising a profile by its maximum, or a spectrum by its total.
 *
 *  Sequential: on `start` it walks the list once (two clocks per bar), finds the minimum
 *  width, then walks it again to classify. `valid` is 1 only if exactly 2*NB edges were found.
 */
module bar_decode #(
    parameter int W    = 320,
    parameter int NB   = 8,       // bars = bits
    parameter int NMAX = 32
) (
    input  logic                     clk,
    input  logic                     reset,
    input  logic                     start,
    input  logic [$clog2(NMAX):0]    count,
    output logic [$clog2(NMAX)-1:0]  idx,
    input  logic [$clog2(W)-1:0]     pos_of,
    output logic                     done,
    output logic                     valid,
    output logic [NB-1:0]            value
);
    localparam int XW = $clog2(W);
    typedef enum logic [2:0] {IDLE, MIN_A, MIN_B, CLS_A, CLS_B, FIN} state_t;
    state_t state;
    logic [$clog2(NB):0] i;
    logic [XW-1:0] left, minw, wd;
    logic [NB-1:0] bits;

    always_ff @(posedge clk) begin
        done <= 1'b0;
        if (reset) begin state <= IDLE; valid <= 1'b0; value <= '0; end
        else case (state)
            IDLE: if (start) begin
                if (count == 2*NB) begin i <= '0; minw <= '1; idx <= '0; state <= MIN_A; end
                else begin valid <= 1'b0; done <= 1'b1; end
            end
            MIN_A: begin left <= pos_of; idx <= idx + 1'b1; state <= MIN_B; end      // read pos[2i]
            MIN_B: begin                                                              // read pos[2i+1]
                if (pos_of - left < minw) minw <= pos_of - left;
                idx <= idx + 1'b1; i <= i + 1'b1;
                if (i == NB-1) begin i <= '0; idx <= '0; state <= CLS_A; end else state <= MIN_A;
            end
            CLS_A: begin left <= pos_of; idx <= idx + 1'b1; state <= CLS_B; end
            CLS_B: begin
                wd = pos_of - left;
                bits[NB-1-i] <= (wd > minw + (minw >> 1));    // wide = more than 1.5 x narrowest; bar 0 is the MSB
                idx <= idx + 1'b1; i <= i + 1'b1;
                if (i == NB-1) state <= FIN; else state <= CLS_A;
            end
            FIN: begin value <= bits; valid <= 1'b1; done <= 1'b1; state <= IDLE; end
            default: state <= IDLE;
        endcase
    end
endmodule
