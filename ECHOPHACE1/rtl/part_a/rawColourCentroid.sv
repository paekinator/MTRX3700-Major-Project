// ECHO-7 Part A | Human owner: Member A (name/SID pending).
// AI-assisted implementation; human review required before submission.
module rawColourCentroid #(
    parameter int WIDTH = 320,
    parameter int HEIGHT = 240,
    parameter int MIN_AREA = 32
) (
    input logic clk, reset,
    input logic in_valid, in_sop, in_eop,
    input logic [8:0] in_x,
    input logic [7:0] in_y,
    input logic [1:0] in_mask,
    output logic out_valid, frame_valid, frame_error, overrun, busy,
    output logic [15:0] frame_id,
    output logic red_valid, blue_valid,
    output logic [16:0] red_area, blue_area,
    output logic [8:0] red_cx, blue_cx,
    output logic [7:0] red_cy, blue_cy
);
    // Baseline includes ALL raw pixels of each colour, including distractors.
    // Exact floor(sum/area), unlike candidate bbox-midpoint centres.
    logic active, bad_frame, bad_overrun, waiting;
    logic [8:0] expected_x;
    logic [7:0] expected_y;
    logic [15:0] sequence_id, capture_id;
    logic [16:0] count_r, count_b;
    logic [26:0] sx_r, sy_r, sx_b, sy_b;
    logic [16:0] next_r, next_b;
    logic [26:0] nx_r, ny_r, nx_b, ny_b;
    logic start_div;
    logic [26:0] numer [0:3], denom [0:3], quotient [0:3], saved [0:3];
    wire [3:0] div_done;
    logic [3:0] seen;
    logic pending_bad, pending_overrun;
    logic [15:0] pending_id;
    logic [16:0] pending_r, pending_b;
    wire publishing = waiting && (&seen);
    wire abort_div = in_valid && in_sop && waiting && !publishing;
    wire last_expected = expected_x == WIDTH-1 && expected_y == HEIGHT-1;
    assign busy = waiting;
    genvar d;
    generate for (d=0; d<4; d=d+1) begin : divisions
        unsignedDivider #(.WIDTH(27)) div_u (
            .clk, .reset(reset || abort_div), .start(start_div),
            .numerator(numer[d]), .denominator(denom[d]),
            .busy(), .done(div_done[d]), .divide_by_zero(), .quotient(quotient[d])
        );
    end endgenerate
    always_comb begin
        next_r = in_sop ? 17'd0 : count_r;
        next_b = in_sop ? 17'd0 : count_b;
        nx_r = in_sop ? 27'd0 : sx_r; ny_r = in_sop ? 27'd0 : sy_r;
        nx_b = in_sop ? 27'd0 : sx_b; ny_b = in_sop ? 27'd0 : sy_b;
        if (in_mask == 1) begin
            next_r = next_r + 1'b1;
            nx_r = nx_r + {18'd0,in_x}; ny_r = ny_r + {19'd0,in_y};
        end
        if (in_mask == 2) begin
            next_b = next_b + 1'b1;
            nx_b = nx_b + {18'd0,in_x}; ny_b = ny_b + {19'd0,in_y};
        end
    end
    always_ff @(posedge clk) begin
        if (reset) begin
            active<=0; bad_frame<=0; bad_overrun<=0; waiting<=0;
            expected_x<=0; expected_y<=0; sequence_id<=0; capture_id<=0;
            count_r<=0; count_b<=0; sx_r<=0; sy_r<=0; sx_b<=0; sy_b<=0;
            start_div<=0; seen<=0; pending_bad<=0; pending_overrun<=0;
            pending_id<=0; pending_r<=0; pending_b<=0;
            out_valid<=0; frame_valid<=0; frame_error<=0; overrun<=0; frame_id<=0;
            red_valid<=0; blue_valid<=0; red_area<=0; blue_area<=0;
            red_cx<=0; red_cy<=0; blue_cx<=0; blue_cy<=0;
            for (int i=0;i<4;i++) begin numer[i]<=0; denom[i]<=0; saved[i]<=0; end
        end else begin
            out_valid<=0; start_div<=0;
            if (waiting) begin
                seen <= seen | div_done;
                for (int i=0;i<4;i++) if(div_done[i]) saved[i]<=quotient[i];
                if(in_valid && !in_sop && !publishing) begin
                    pending_bad<=1;pending_overrun<=1;
                end
                // Wait an extra clock so all saved values, including zero divisors,
                // are available together for one atomic frame publication.
                if (&seen) begin
                    waiting<=0; out_valid<=1; frame_id<=pending_id;
                    frame_valid<=!pending_bad; frame_error<=pending_bad;
                    overrun<=pending_overrun;
                    red_area<=pending_r; blue_area<=pending_b;
                    red_valid<=!pending_bad && pending_r>=MIN_AREA;
                    blue_valid<=!pending_bad && pending_b>=MIN_AREA;
                    red_cx<=saved[0][8:0]; red_cy<=saved[1][7:0];
                    blue_cx<=saved[2][8:0]; blue_cy<=saved[3][7:0];
                end
            end
            if (in_valid && in_sop) begin
                sequence_id<=sequence_id+1'b1; capture_id<=sequence_id+1'b1;
                active<=1; waiting<=0; seen<=0;
                bad_frame<=active || (waiting && !publishing) || in_x!=0 || in_y!=0 || in_eop || in_mask==3;
                bad_overrun<=waiting && !publishing;
                expected_x<=9'd1; expected_y<=0;
                count_r<=next_r; count_b<=next_b;
                sx_r<=nx_r; sy_r<=ny_r; sx_b<=nx_b; sy_b<=ny_b;
                // A new frame can start on the prior frame's publication edge.
                out_valid<=publishing;
                if(active || (waiting && !publishing)) begin
                    // Publish a labelled invalid result for the abandoned old frame.
                    out_valid<=1;frame_valid<=0;frame_error<=1;overrun<=waiting;
                    frame_id<=waiting ? pending_id : capture_id;
                    red_valid<=0;blue_valid<=0;
                    red_area<=waiting ? pending_r : count_r;
                    blue_area<=waiting ? pending_b : count_b;
                    red_cx<=0;red_cy<=0;blue_cx<=0;blue_cy<=0;
                end
                if(in_eop) begin
                    // A one-pixel truncated frame must still publish an invalid
                    // result, rather than leaving the pairing consumer waiting.
                    active<=0;waiting<=1;start_div<=1;
                    pending_id<=sequence_id+1'b1;pending_r<=next_r;pending_b<=next_b;
                    pending_bad<=1;pending_overrun<=waiting && !publishing;
                    numer[0]<=nx_r;numer[1]<=ny_r;numer[2]<=nx_b;numer[3]<=ny_b;
                    denom[0]<={10'd0,next_r};denom[1]<={10'd0,next_r};
                    denom[2]<={10'd0,next_b};denom[3]<={10'd0,next_b};
                end
            end else if (in_valid && active) begin
                count_r<=next_r; count_b<=next_b;
                sx_r<=nx_r; sy_r<=ny_r; sx_b<=nx_b; sy_b<=ny_b;
                if (in_x!=expected_x || in_y!=expected_y || in_x>=WIDTH || in_y>=HEIGHT || in_mask==3)
                    bad_frame<=1;
                if (expected_x==WIDTH-1) begin expected_x<=0; expected_y<=expected_y+1'b1; end
                else expected_x<=expected_x+1'b1;
                if (in_eop || last_expected) begin
                    active<=0; waiting<=1; seen<=0; start_div<=1;
                    pending_id<=capture_id; pending_r<=next_r; pending_b<=next_b;
                    pending_bad<=bad_frame || in_x!=expected_x || in_y!=expected_y ||
                                 in_x!=WIDTH-1 || in_y!=HEIGHT-1 || in_eop!=last_expected || in_mask==3;
                    pending_overrun<=bad_overrun;
                    numer[0]<=nx_r; numer[1]<=ny_r; numer[2]<=nx_b; numer[3]<=ny_b;
                    denom[0]<={10'd0,next_r}; denom[1]<={10'd0,next_r};
                    denom[2]<={10'd0,next_b}; denom[3]<={10'd0,next_b};
                end
            end
        end
    end
`ifndef SYNTHESIS
    initial begin
        assert(WIDTH>=2 && WIDTH<=320 && HEIGHT>=2 && HEIGHT<=240)
            else $fatal(1,"rawColourCentroid geometry must fit native camera and be at least 2x2");
        assert(MIN_AREA>=1 && MIN_AREA<=WIDTH*HEIGHT) else $fatal(1,"MIN_AREA out of range");
    end
`endif
endmodule
