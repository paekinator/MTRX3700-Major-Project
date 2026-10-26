// ECHO-7 Phase 1 | Owner: MTRX3700 ECHO-7 team (human review required).
// AI-assisted implementation: OpenAI Codex; see OWNERS.md and AI_STATEMENT.md.
module rgbFixedSeg #(
    parameter int unsigned RED_R_MIN = 160, RED_G_MAX = 100, RED_B_MAX = 100,
    parameter int unsigned BLUE_B_MIN = 160, BLUE_R_MAX = 100, BLUE_G_MAX = 100
) (
    input logic clk, reset, ce, in_valid,
    input logic [15:0] rgb565,
    output logic out_valid,
    output logic [1:0] mask
);
    // One enabled register stage. Reset takes precedence over a stalled CE.
    import camera_pkg::*;
    wire [23:0] rgb = rgb565_to_rgb888(rgb565);
    wire red_hit = (32'(rgb[23:16]) >= RED_R_MIN) &&
                   (32'(rgb[15:8]) <= RED_G_MAX) && (32'(rgb[7:0]) <= RED_B_MAX);
    wire blue_hit = (32'(rgb[7:0]) >= BLUE_B_MIN) &&
                    (32'(rgb[23:16]) <= BLUE_R_MAX) && (32'(rgb[15:8]) <= BLUE_G_MAX);
    always_ff @(posedge clk) begin
        if (reset) begin out_valid <= 1'b0; mask <= 2'b00; end
        else if (ce) begin
            out_valid <= in_valid;
            mask <= !in_valid || (red_hit == blue_hit) ? 2'b00 : red_hit ? 2'b01 : 2'b10;
        end
    end
endmodule
