// ECHO-7 Phase 1 | Owner: MTRX3700 ECHO-7 team (human review required).
// AI-assisted implementation: OpenAI Codex; see OWNERS.md and AI_STATEMENT.md.
module rgbRatioSeg #(
    parameter int unsigned MIN_VALUE = 80,
    parameter int unsigned RATIO_NUM = 3,
    parameter int unsigned RATIO_DEN = 2,
    parameter int unsigned RED_MIN_VALUE = MIN_VALUE,
    parameter int unsigned BLUE_MIN_VALUE = MIN_VALUE
) (
    input logic clk, reset, ce, in_valid,
    input logic [15:0] rgb565,
    output logic out_valid,
    output logic [1:0] mask
);
    // One enabled stage; dominant channel >= 1.5 * each other channel by default.
    // Supported calibration range: MIN_VALUE 0..255, NUM/DEN 1..255.
    import camera_pkg::*;
    wire [23:0] rgb = rgb565_to_rgb888(rgb565);
    wire [31:0] r = {24'b0, rgb[23:16]};
    wire [31:0] g = {24'b0, rgb[15:8]};
    wire [31:0] b = {24'b0, rgb[7:0]};
    wire red_hit = (r >= RED_MIN_VALUE) && (r*RATIO_DEN >= g*RATIO_NUM) && (r*RATIO_DEN >= b*RATIO_NUM);
    wire blue_hit = (b >= BLUE_MIN_VALUE) && (b*RATIO_DEN >= r*RATIO_NUM) && (b*RATIO_DEN >= g*RATIO_NUM);
    always_ff @(posedge clk) begin
        if (reset) begin out_valid <= 1'b0; mask <= 2'b00; end
        else if (ce) begin
            out_valid <= in_valid;
            mask <= !in_valid || (red_hit == blue_hit) ? 2'b00 : red_hit ? 2'b01 : 2'b10;
        end
    end
endmodule
