`timescale 1ns/1ps
/*
 *  hdiff.sv -- the simplest edge detector: the difference between a pixel and its left neighbour.
 *
 *      out_val = | pixel(y, x) - pixel(y, x-1) |
 *
 *  It is the Lesson 4 1-D convolution turned sideways, with the two-tap table {-1, +1} slid along each
 *  row. No line buffer: only the previous pixel of the same row is kept. A vertical edge (the side of a
 *  bar, the gap between two keys) gives a large value; flat areas give 0. Its weakness is that it also
 *  responds to every noisy pixel, because nothing is averaged: the 3x3 Sobel table (Lesson 4, 2.3b)
 *  smooths along the column as it differentiates along the row, and replaces this module at R-V2.
 *
 *  Pixels arrive in raster order with their coordinates; the output for (x, y) appears one clock later,
 *  with the same coordinates. Column 0 has no left neighbour and is output as 0.
 */
module hdiff #(
    parameter int W  = 320,
    parameter int H  = 240,
    parameter int DW = 8
) (
    input  logic                  clk,
    input  logic                  reset,
    input  logic                  in_valid,
    input  logic [DW-1:0]         in_pixel,
    input  logic [$clog2(W)-1:0]  in_x,
    input  logic [$clog2(H)-1:0]  in_y,
    output logic                  out_valid,
    output logic [DW-1:0]         out_val,
    output logic [$clog2(W)-1:0]  out_x,
    output logic [$clog2(H)-1:0]  out_y
);
    logic [DW-1:0] prev;                                   // the pixel to the left
    always_ff @(posedge clk) begin
        out_valid <= in_valid & ~reset;
        out_x     <= in_x;
        out_y     <= in_y;
        if (in_valid) begin
            prev    <= in_pixel;
            out_val <= (in_x == 0) ? '0 : ((in_pixel > prev) ? in_pixel - prev : prev - in_pixel);
        end
    end
endmodule
