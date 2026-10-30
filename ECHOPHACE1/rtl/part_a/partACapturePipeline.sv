// ECHO-7 Part A | Human owner: Member A (name/SID pending).
// AI-assisted integration by OpenAI Codex; human review required before submission.
// Native-camera colour baseline + causal cleanup + bounded candidates, with a
// frame-qualified capture packet. No CNN, candidate association, or motion logic.
// Packet specification: ../../packet_schema.json (78 unsigned 32-bit words, EPA2).
module partACapturePipeline #(
    parameter int W = 320,
    parameter int H = 240,
    parameter int CAP = 8,
    parameter int MIN_AREA = 32,
    parameter int CONTROL_STABLE_CYCLES = 250000,
    parameter int RATIO_RED_MIN_VALUE = 64,
    parameter int RATIO_BLUE_MIN_VALUE = 32,
    parameter int RATIO_NUM = 3,
    parameter int RATIO_DEN = 2
) (
    input logic pclk, reset,
    input logic camera_frame_start,
    input logic px_valid,
    input logic [15:0] pixel,
    input logic [9:0] px_x,
    input logic [8:0] px_y,
    input logic [3:0] control_async,
    output logic [78*32-1:0] snapshot_results
);
    import camera_pkg::*;
    import part_a_pkg::*;

    // Same raw kept pixels as frame_snap MODE0 and the 320x240 frame buffer.
    wire [8:0] native_x = px_x[9:1];
    wire [7:0] native_y = px_y[8:1];
    wire native_kept = px_valid && !px_x[0] && !px_y[0] &&
                       int'(native_x) < W && int'(native_y) < H;
    wire native_sop = native_kept && native_x == 0 && native_y == 0;
    wire native_eop = native_kept && native_x == W-1 && native_y == H-1;
    wire [23:0] rgb = rgb565_to_rgb888(pixel);
    wire [29:0] selector_data = {rgb[23:16],2'b00,rgb[15:8],2'b00,rgb[7:0],2'b00};
    wire classified_valid, classified_sop, classified_eop;
    wire [1:0] classified_mask, classified_mode;
    // The selector advances every PCLK because out_ready=1. Its existing
    // three-stage mask/tag/SOP/EOP pipeline also runs through pixel-valid gaps.
    segmentationSelector #(.CONTROL_WIDTH(4), .STABLE_CYCLES(CONTROL_STABLE_CYCLES),
        .RATIO_RED_MIN_VALUE(RATIO_RED_MIN_VALUE), .RATIO_BLUE_MIN_VALUE(RATIO_BLUE_MIN_VALUE),
        .RATIO_NUM(RATIO_NUM), .RATIO_DEN(RATIO_DEN)) native_seg_u (
        .clk(pclk), .reset(reset), .control_async(control_async),
        .in_data(selector_data), .in_sop(native_sop), .in_eop(native_eop),
        .in_valid(native_kept), .in_ready(), .out_data(),
        .out_sop(classified_sop), .out_eop(classified_eop),
        .out_valid(classified_valid), .out_ready(1'b1),
        .out_mask(classified_mask), .out_overlay(), .out_mode(classified_mode), .out_calibration());
    logic [8:0] x_pipe [0:2];
    logic [7:0] y_pipe [0:2];
    always_ff @(posedge pclk) begin
        if (reset) begin
            for (int i=0; i<3; i++) begin x_pipe[i]<=0; y_pipe[i]<=0; end
        end else begin
            x_pipe[0]<=native_x; y_pipe[0]<=native_y;
            for (int i=1; i<3; i++) begin x_pipe[i]<=x_pipe[i-1]; y_pipe[i]<=y_pipe[i-1]; end
        end
    end

    wire raw_publish, raw_frame_valid, raw_frame_error, raw_overrun, raw_busy;
    wire [15:0] raw_frame_id;
    wire raw_red_valid, raw_blue_valid;
    wire [16:0] raw_red_area, raw_blue_area;
    wire [8:0] raw_red_cx, raw_blue_cx;
    wire [7:0] raw_red_cy, raw_blue_cy;
    rawColourCentroid #(.WIDTH(W), .HEIGHT(H), .MIN_AREA(MIN_AREA)) raw_u (
        .clk(pclk), .reset(reset), .in_valid(classified_valid),
        .in_sop(classified_sop), .in_eop(classified_eop),
        .in_x(x_pipe[2]), .in_y(y_pipe[2]), .in_mask(classified_mask),
        .out_valid(raw_publish), .frame_valid(raw_frame_valid), .frame_error(raw_frame_error),
        .overrun(raw_overrun), .busy(raw_busy), .frame_id(raw_frame_id),
        .red_valid(raw_red_valid), .blue_valid(raw_blue_valid),
        .red_area(raw_red_area), .blue_area(raw_blue_area),
        .red_cx(raw_red_cx), .red_cy(raw_red_cy), .blue_cx(raw_blue_cx), .blue_cy(raw_blue_cy));

    wire clean_valid, clean_sop, clean_eop;
    wire [8:0] clean_x;
    wire [7:0] clean_y;
    wire [1:0] clean_mask;
    causalMaskCleanup #(.WIDTH(W)) cleanup_u (
        .clk(pclk), .reset(reset), .in_valid(classified_valid),
        .in_sop(classified_sop), .in_eop(classified_eop),
        .in_x(x_pipe[2]), .in_y(y_pipe[2]), .in_mask(classified_mask),
        .out_valid(clean_valid), .out_sop(clean_sop), .out_eop(clean_eop),
        .out_x(clean_x), .out_y(clean_y), .out_mask(clean_mask));
    candidate_array_t red_candidates, blue_candidates;
    wire [3:0] red_count, blue_count;
    wire candidate_publish, candidate_frame_valid, candidate_frame_error;
    wire red_overflow, blue_overflow, candidate_overflow, candidate_overrun, candidate_busy;
    wire [15:0] candidate_frame_id;
    boundedCandidates #(.W(W), .H(H), .CAP(CAP), .MIN_AREA(MIN_AREA)) candidate_u (
        .clk(pclk), .reset(reset), .in_valid(clean_valid), .in_sop(clean_sop), .in_eop(clean_eop),
        .in_x(clean_x), .in_y(clean_y), .in_mask(clean_mask),
        .red_candidates(red_candidates), .blue_candidates(blue_candidates),
        .red_count(red_count), .blue_count(blue_count), .out_valid(candidate_publish),
        .frame_valid(candidate_frame_valid), .frame_error(candidate_frame_error),
        .red_overflow(red_overflow), .blue_overflow(blue_overflow), .overflow(candidate_overflow),
        .overrun(candidate_overrun), .frame_id(candidate_frame_id), .busy(candidate_busy));

    // Native counter identifies the frame which frame_snap actually stores.
    // Explicit SOP/publication seen bits permit ID0 after wrap and recover from
    // a reset during a frame; no validity test depends on a nonzero numeric ID.
    logic [15:0] native_sequence;
    logic native_sop_seen, raw_seen, candidates_seen;
    logic [1:0] completed_mode;
    wire raw_available = raw_seen || raw_publish;
    wire candidates_available = candidates_seen || candidate_publish;
    wire ids_match = native_sequence == raw_frame_id && native_sequence == candidate_frame_id;
    wire same_frame = native_sop_seen && raw_available && candidates_available && ids_match;
    logic [31:0] words [0:77];
    always_comb begin
        for (int i=0; i<78; i++) words[i]='0;
        words[0]=32'h45504132; // EPA2: row-reclaimed labels and calibrated ratio metadata
        words[1]=32'd2;
        words[2]={16'd0,native_sequence};
        words[3]={16'd0,raw_frame_id};
        words[4]={16'd0,candidate_frame_id};
        words[5][0]=same_frame;
        words[5][1]=raw_available;
        words[5][2]=candidates_available;
        words[5][3]=ids_match;
        words[5][4]=raw_frame_valid;
        words[5][5]=raw_frame_error;
        words[5][6]=raw_overrun;
        words[5][7]=candidate_frame_valid;
        words[5][8]=candidate_frame_error;
        words[5][9]=candidate_overrun;
        words[5][10]=candidate_overflow;
        words[5][11]=red_overflow;
        words[5][12]=blue_overflow;
        words[5][13]=raw_red_valid;
        words[5][14]=raw_blue_valid;
        words[5][15]=native_sop_seen;
        words[5][16]=raw_busy;
        words[5][17]=candidate_busy;
        words[6]={16'(W),16'(H)};
        words[7][1:0]=completed_mode;
        words[7][7:4]=4'(CAP);
        words[7][24:8]=17'(MIN_AREA);
        words[8]={15'd0,raw_red_area};
        words[9]={7'd0,raw_red_cx,8'd0,raw_red_cy};
        words[10]={15'd0,raw_blue_area};
        words[11]={7'd0,raw_blue_cx,8'd0,raw_blue_cy};
        words[12]={24'd0,blue_count,red_count};
        words[77]={8'(RATIO_RED_MIN_VALUE),8'(RATIO_BLUE_MIN_VALUE),8'(RATIO_NUM),8'(RATIO_DEN)};
        for (int i=0; i<8; i++) begin
            words[13+4*i]={red_candidates[i].valid,14'd0,red_candidates[i].area};
            words[14+4*i]={7'd0,red_candidates[i].xmin,7'd0,red_candidates[i].xmax};
            words[15+4*i]={8'd0,red_candidates[i].ymin,8'd0,red_candidates[i].ymax};
            words[16+4*i]={7'd0,red_candidates[i].cx,8'd0,red_candidates[i].cy};
            words[45+4*i]={blue_candidates[i].valid,14'd0,blue_candidates[i].area};
            words[46+4*i]={7'd0,blue_candidates[i].xmin,7'd0,blue_candidates[i].xmax};
            words[47+4*i]={8'd0,blue_candidates[i].ymin,8'd0,blue_candidates[i].ymax};
            words[48+4*i]={7'd0,blue_candidates[i].cx,8'd0,blue_candidates[i].cy};
        end
    end
    always_ff @(posedge pclk) begin
        if (reset) begin
            native_sequence<=0; native_sop_seen<=0; raw_seen<=0; candidates_seen<=0;
            completed_mode<=0; snapshot_results<='0;
        end else begin
            if (raw_publish) raw_seen<=1;
            if (candidate_publish) candidates_seen<=1;
            if (classified_valid && classified_sop) completed_mode<=classified_mode;
            if (camera_frame_start) begin
                // Course frame_snap then reads this packet at the first raw pixel
                // of the new frame. It cannot see that new frame's later results.
                for (int i=0; i<78; i++) snapshot_results[32*(77-i)+:32]<=words[i];
                native_sop_seen<=0; raw_seen<=0; candidates_seen<=0;
            end
            if (native_sop) begin
                native_sequence<=native_sequence+16'd1;
                native_sop_seen<=1;
            end
        end
    end
`ifndef SYNTHESIS
    initial begin
        assert(W>=2 && W<=320 && H>=2 && H<=240) else $fatal(1,"native geometry out of range");
        assert(CAP>=1 && CAP<=8 && MIN_AREA>=1 && MIN_AREA<=W*H) else $fatal(1,"candidate configuration out of range");
        assert(CONTROL_STABLE_CYCLES>=1) else $fatal(1,"control debounce must be positive");
        assert(RATIO_RED_MIN_VALUE>=0 && RATIO_RED_MIN_VALUE<=255 &&
               RATIO_BLUE_MIN_VALUE>=0 && RATIO_BLUE_MIN_VALUE<=255 &&
               RATIO_NUM>=1 && RATIO_NUM<=255 && RATIO_DEN>=1 && RATIO_DEN<=255)
            else $fatal(1,"ratio calibration must fit packet bytes");
    end
`endif
endmodule
