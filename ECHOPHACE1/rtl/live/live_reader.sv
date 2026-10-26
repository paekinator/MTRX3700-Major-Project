`timescale 1ns/1ps
/*
 *  live_reader.sv -- the Assignment 2 barcode pipeline on the LIVE camera stream.
 *
 *      ov7670_capture -> decimate 2:1 + grey -> hdiff -> col_profile -> pick_runs -> bar_decode
 *
 *  This is the barcode mini-project's barcode_reader.sv with one change: the picture comes from the
 *  camera instead of a ROM sweep (raster_source), one pixel per two PCLKs, with the coordinates the
 *  capture module attached. Nothing downstream can tell the difference: raster_source was a model
 *  of exactly this stream. The camera's vertical blanking (30 lines, 47,000 PCLKs) takes the place
 *  of the pause between the ROM's sweeps, and is plenty for the picker and the decoder.
 *  Everything runs in the PCLK domain; the results cross to the display through cdc_latch as in A2.
 */
module live_reader #(
    parameter int    W        = 320,
    parameter int    H        = 240,
    parameter int    NB       = 8,
    parameter int    NMAX     = 32,
    parameter int    Y0       = 60,       // rows summed into the profile
    parameter int    Y1       = 180
) (
    input  logic                     clk,           // the camera's PCLK
    input  logic                     reset,
    // the picture: the camera's stream, full resolution, from ov7670_capture
    input  logic                     cam_frame_start,
    input  logic                     cam_valid,
    input  logic [15:0]              cam_pixel,     // RGB565
    input  logic [9:0]               cam_x,
    input  logic [8:0]               cam_y,
    input  logic [19:0]              thr,          // profile threshold
    input  logic [$clog2(W)-1:0]     min_gap,      // minimum spacing between edges
    output logic                     result_valid,
    output logic [$clog2(NMAX):0]    edge_count,
    output logic [NMAX*$clog2(W)-1:0] edge_list,   // packed positions, entry 0 in the low bits
    output logic                     code_valid,
    output logic [NB-1:0]            code,
    // the profile, for the display's profile view (read in another clock via prof_* below)
    output logic                     prof_wr,
    output logic [$clog2(W)-1:0]     prof_wr_x,
    output logic [19:0]              prof_wr_val
);
    localparam int XW = $clog2(W);

    // ---- the live picture: every second pixel of every second row, as 8-bit grey ----
    // (the same decimation the frame buffer does, so the analysis sees the picture the display shows)
    import camera_pkg::*;
    logic frame_start, px_valid; logic [7:0] px; logic [XW-1:0] px_x; logic [$clog2(H)-1:0] px_y;
    always_ff @(posedge clk) begin
        frame_start <= cam_frame_start;
        px_valid    <= cam_valid && cam_x[0] == 1'b0 && cam_y[0] == 1'b0 && (cam_x >> 1) < W && (cam_y >> 1) < H;
        px          <= rgb565_to_grey(cam_pixel);
        px_x        <= XW'(cam_x >> 1);
        px_y        <= ($clog2(H))'(cam_y >> 1);
    end

    // ---- edges: the 1-D difference |p[x] - p[x-1]| (R-V0). Your Lesson 4 Sobel replaces it at R-V2. ----
    logic e_valid; logic [7:0] e_val; logic [XW-1:0] e_x; logic [$clog2(H)-1:0] e_y;
    hdiff #(.W(W), .H(H)) u_edge (.clk, .reset, .in_valid(px_valid), .in_pixel(px), .in_x(px_x), .in_y(px_y),
        .out_valid(e_valid), .out_val(e_val), .out_x(e_x), .out_y(e_y));

    // ---- column profile of the edge strength over rows Y0..Y1 ----
    // (X_LAST is W-1 here: hdiff outputs every column. After an interior-only 3x3 filter it is W-2.)
    logic prof_done; logic [XW-1:0] prof_rd_x; logic [19:0] prof_rd_val;
    col_profile #(.W(W), .H(H), .VW(8), .AW(20), .Y0(Y0), .Y1(Y1), .X_LAST(W-1)) u_prof (.clk, .reset,
        .in_valid(e_valid), .in_val(e_val), .in_x(e_x), .in_y(e_y), .frame_start,
        .done(prof_done), .rd_x(prof_rd_x), .rd_val(prof_rd_val));

    // ---- peaks -> edge list ----
    logic pick_done; logic [$clog2(NMAX):0] count; logic [$clog2(NMAX)-1:0] pk_idx; logic [XW-1:0] pk_pos;
    logic pick_busy;
    // ---- the simple picker: runs above the threshold, merged within min_gap. Lesson 4's peak picker replaces it at R-V3. ----
    pick_runs #(.W(W), .AW(20), .NMAX(NMAX)) u_pick (.clk, .reset, .start(prof_done), .thr, .min_gap,
        .rd_x(prof_rd_x), .rd_val(prof_rd_val), .busy(pick_busy), .done(pick_done), .count, .idx(pk_idx), .pos_of(pk_pos));

    // ---- decode ----
    logic dec_done, dec_valid; logic [NB-1:0] dec_value; logic [$clog2(NMAX)-1:0] dec_idx;
    bar_decode #(.W(W), .NB(NB), .NMAX(NMAX)) u_dec (.clk, .reset, .start(pick_done), .count,
        .idx(dec_idx), .pos_of(pk_pos), .done(dec_done), .valid(dec_valid), .value(dec_value));

    // the decoder owns the list-read port while it runs; afterwards we copy the list out
    typedef enum logic [1:0] {RUN, COPY, PUBLISH} st_t;
    st_t st; logic [$clog2(NMAX)-1:0] cp_i;
    assign pk_idx = (st == COPY) ? cp_i : dec_idx;
    logic [NMAX*XW-1:0] list_q;
    always_ff @(posedge clk) begin
        result_valid <= 1'b0;
        if (reset) begin st <= RUN; cp_i <= '0; end
        else case (st)
            RUN: if (dec_done) begin cp_i <= '0; st <= COPY; end
            COPY: begin
                list_q[cp_i*XW +: XW] <= (cp_i < count) ? pk_pos : '0;
                if (cp_i == NMAX-1) st <= PUBLISH; else cp_i <= cp_i + 1'b1;
            end
            PUBLISH: begin
                edge_list <= list_q; edge_count <= count; code <= dec_value; code_valid <= dec_valid;
                result_valid <= 1'b1; st <= RUN;
            end
            default: st <= RUN;
        endcase
    end

    // The picker's walk presents every profile entry in order on (rd_x, rd_val), one cycle apart:
    // tap it, so the display can keep a copy of the finished profile for its profile view.
    logic busy_d; logic [XW-1:0] rd_x_d;
    always_ff @(posedge clk) begin
        busy_d <= pick_busy; rd_x_d <= prof_rd_x;
        prof_wr <= busy_d; prof_wr_x <= rd_x_d; prof_wr_val <= prof_rd_val;
    end
endmodule
