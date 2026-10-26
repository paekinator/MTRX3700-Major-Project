`timescale 1ns/1ps
/*
 *  camera_barcode_display.sv -- the live picture with the barcode reader's findings drawn over it.
 *
 *  camera_display.sv (the Avalon-ST source, pixel-doubled from the 320x240 frame buffer) plus the
 *  overlay of Assignment 2's display.sv: each detected edge is a red line, and while the decode is
 *  valid the value is written top-left as two hex digits (hex_glyph.sv). The results arrive in
 *  this clock domain through cdc_latch, updated during vertical blanking, so a frame never shows
 *  half an old and half a new edge list.
 */
module camera_barcode_display #(
    parameter int H_RES = 640,
    parameter int V_RES = 480,
    parameter int W     = 320,
    parameter int H     = 240,
    parameter int NB    = 8,
    parameter int NMAX  = 32
) (
    input  logic                       clk,
    input  logic                       reset,
    // frame buffer read port
    output logic [$clog2(W)-1:0]       rd_x,
    output logic [$clog2(H)-1:0]       rd_y,
    input  logic [15:0]                rd_pixel,
    // the reader's results (already in this clock domain)
    input  logic [$clog2(NMAX):0]      edge_count,
    input  logic [NMAX*$clog2(W)-1:0]  edge_list,
    input  logic                       code_valid,
    input  logic [NB-1:0]              code,
    // Avalon-ST
    output logic [29:0]                data,
    output logic                       startofpacket,
    output logic                       endofpacket,
    output logic                       valid,
    input  logic                       ready,
    output logic                       vblank
);
    import camera_pkg::*;
    localparam int XW = $clog2(W);

    logic [$clog2(H_RES)-1:0] x, x_next;
    logic [$clog2(V_RES)-1:0] y, y_next;
    logic last_pixel, handshake;
    assign last_pixel = (x == H_RES - 1) && (y == V_RES - 1);
    assign handshake  = valid && ready;
    always_comb begin
        if (reset || last_pixel)  begin x_next = '0;         y_next = '0;         end
        else if (x == H_RES - 1)  begin x_next = '0;         y_next = y + 1'b1;   end
        else                      begin x_next = x + 1'b1;   y_next = y;          end
    end
    always_ff @(posedge clk) if (reset || handshake) begin x <= x_next; y <= y_next; end
    assign rd_x = XW'((handshake ? x_next : x) >> 1);
    assign rd_y = ($clog2(H))'((handshake ? y_next : y) >> 1);

    // ---- overlay ----
    logic [XW-1:0] cx;
    assign cx = XW'(x >> 1);
    logic on_edge, on_hi, on_lo;
    always_comb begin
        on_edge = 1'b0;
        for (int i = 0; i < NMAX; i++)
            if (i < edge_count && edge_list[i*XW +: XW] == cx) on_edge = 1'b1;
    end
    hex_glyph #(.XW(XW), .YW($clog2(H)), .SCALE(3)) u_hi (.x(cx), .x0(XW'(4)),  .y(($clog2(H))'(y >> 1)), .y0(($clog2(H))'(4)), .value(code[7:4]), .on(on_hi));
    hex_glyph #(.XW(XW), .YW($clog2(H)), .SCALE(3)) u_lo (.x(cx), .x0(XW'(16)), .y(($clog2(H))'(y >> 1)), .y0(($clog2(H))'(4)), .value(code[3:0]), .on(on_lo));

    logic [23:0] rgb;
    always_comb begin
        rgb = rgb565_to_rgb888(rd_pixel);
        if (on_edge) rgb = 24'hFF3030;
        if (code_valid && (on_hi || on_lo)) rgb = 24'h20E060;
    end
    // Avalon-ST: what is on offer must not change until it is taken. With a single frame buffer the camera can
    // overwrite the word on offer during a stall, so the first stalled cycle freezes the offer, as camera_display.sv does.
    logic [29:0] live, held;
    logic        stalled_q;
    assign live = {rgb[23:16], 2'b00, rgb[15:8], 2'b00, rgb[7:0], 2'b00};
    always_ff @(posedge clk) begin
        stalled_q <= valid && !ready && !reset;
        if (valid && !ready && !stalled_q) held <= live;
    end
    assign data   = stalled_q ? held : live;
    assign valid  = ~reset;
    assign startofpacket = (x == 0) && (y == 0);
    assign endofpacket   = last_pixel;
    assign vblank        = (y == 0) && (x < 8);
endmodule
