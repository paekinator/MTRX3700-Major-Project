// ECHO-7 Phase 1 | Owner: MTRX3700 ECHO-7 team (human review required).
// AI-assisted implementation: OpenAI Codex; see OWNERS.md and AI_STATEMENT.md.
module segmentationSelector #(
    parameter int unsigned STABLE_CYCLES = 250000, // 10 ms at 25 MHz; must be >= 1
    parameter int CONTROL_WIDTH = 3, // 4 adds SW4 calibration; legacy users remain 3-bit.
    parameter int RATIO_RED_MIN_VALUE = 80,
    parameter int RATIO_BLUE_MIN_VALUE = 80,
    parameter int RATIO_NUM = 3,
    parameter int RATIO_DEN = 2
) (
    input logic clk, reset,
    input logic [CONTROL_WIDTH-1:0] control_async,
    input logic [29:0] in_data,
    input logic in_sop, in_eop, in_valid,
    output logic in_ready,
    output logic [29:0] out_data,
    output logic out_sop, out_eop, out_valid,
    input logic out_ready,
    output logic [1:0] out_mask,
    output logic out_overlay,
    output logic [1:0] out_mode, // Frame-qualified mode tag for matching diagnostics.
    output wire out_calibration
);
    // Switch synchronization runs even while the pixel pipeline is stalled.
    (* preserve *) logic [CONTROL_WIDTH-1:0] control_meta, control_sync;
    logic [CONTROL_WIDTH-1:0] candidate, stable_control, frame_control;
    localparam int CW = (STABLE_CYCLES < 2) ? 1 : $clog2(STABLE_CYCLES);
    logic [CW-1:0] stable_count;
    always_ff @(posedge clk) begin
        if (reset) begin
            control_meta <= '0; control_sync <= '0; candidate <= '0;
            stable_control <= '0; stable_count <= '0;
        end else begin
            control_meta <= control_async;
            control_sync <= control_meta;
            if (control_sync != candidate) begin candidate <= control_sync; stable_count <= '0; end
            else if (stable_count == CW'(STABLE_CYCLES-1)) stable_control <= candidate;
            else stable_count <= stable_count + 1'b1;
        end
    end
    // Use new control on the accepted SOP itself, not one pixel later.
    wire [CONTROL_WIDTH-1:0] pixel_control = in_sop ? stable_control : frame_control;
    wire advance = !out_valid || out_ready;
    assign in_ready = advance && !reset;
    wire [15:0] rgb565 = {in_data[29:25], in_data[19:14], in_data[9:5]};
    logic fv, rv, hv;
    logic [1:0] fm, rm, hm, fm1, fm2, rm1, rm2;
    rgbFixedSeg fixed_u (.clk, .reset, .ce(advance), .in_valid(in_valid), .rgb565, .out_valid(fv), .mask(fm));
    rgbRatioSeg #(.RED_MIN_VALUE(RATIO_RED_MIN_VALUE), .BLUE_MIN_VALUE(RATIO_BLUE_MIN_VALUE),
                  .RATIO_NUM(RATIO_NUM), .RATIO_DEN(RATIO_DEN)) ratio_u (
        .clk, .reset, .ce(advance), .in_valid(in_valid), .rgb565, .out_valid(rv), .mask(rm));
    hsvSeg hsv_u (.clk, .reset, .ce(advance), .in_valid(in_valid), .rgb565, .out_valid(hv), .mask(hm));
    logic [29:0] data_pipe [0:2];
    logic [CONTROL_WIDTH-1:0] control_pipe [0:2];
    logic [2:0] sop_pipe, eop_pipe;
    always_ff @(posedge clk) begin
        if (reset) begin
            frame_control <= '0;
            fm1 <= '0; fm2 <= '0; rm1 <= '0; rm2 <= '0;
            sop_pipe <= '0; eop_pipe <= '0;
            for (int i=0; i<3; i++) begin data_pipe[i] <= '0; control_pipe[i] <= '0; end
        end else if (advance) begin
            if (in_valid && in_sop) frame_control <= stable_control;
            fm1 <= fm; fm2 <= fm1; rm1 <= rm; rm2 <= rm1;
            data_pipe[0] <= in_data; control_pipe[0] <= pixel_control;
            sop_pipe <= {sop_pipe[1:0], in_sop && in_valid};
            eop_pipe <= {eop_pipe[1:0], in_eop && in_valid};
            for (int i=1; i<3; i++) begin
                data_pipe[i] <= data_pipe[i-1]; control_pipe[i] <= control_pipe[i-1];
            end
        end
    end
    assign out_valid = hv && !reset;
    assign out_data = data_pipe[2];
    assign out_sop = sop_pipe[2];
    assign out_eop = eop_pipe[2];
    assign out_overlay = control_pipe[2][2];
    assign out_mode = control_pipe[2][1:0];
    generate if(CONTROL_WIDTH==4) begin
        assign out_calibration=control_pipe[2][3];
    end else begin
        assign out_calibration=1'b0;
    end endgenerate
    always_comb begin
        case (control_pipe[2][1:0])
            2'b01: out_mask = rm2;
            2'b10: out_mask = hm;
            default: out_mask = fm2; // 00 and reserved 11: Fixed RGB
        endcase
        if (!out_valid) out_mask = 2'b00;
    end
endmodule
