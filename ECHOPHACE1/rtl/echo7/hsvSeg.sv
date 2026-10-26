// ECHO-7 Phase 1 | Owner: MTRX3700 ECHO-7 team (human review required).
// AI-assisted implementation: OpenAI Codex; see OWNERS.md and AI_STATEMENT.md.
module hsvSeg #(
    parameter int unsigned SAT_MIN = 96, VALUE_MIN = 80,
    parameter int unsigned RED_H_MAX = 85, RED_H_MIN = 1451,
    parameter int unsigned BLUE_H_MIN = 853, BLUE_H_MAX = 1109
) (
    input logic clk, reset, ce, in_valid,
    input logic [15:0] rgb565,
    output logic out_valid,
    output logic [1:0] mask
);
    // Three enabled stages, initiation interval one. Hue units: 256 per sector.
    // Exact rational interval comparison: H = hue_n / delta (0 <= H < 1536).
    // S = 255*delta/value. Cross products avoid division, LUTs and rounding.
    // Parameters: S/V 0..255, hue bounds 0..1535; blue low <= high.
    import camera_pkg::*;
    wire [23:0] rgb = rgb565_to_rgb888(rgb565);
    wire [7:0] r = rgb[23:16], g = rgb[15:8], b = rgb[7:0];
    wire [7:0] mx = (r >= g && r >= b) ? r : (g >= b) ? g : b;
    wire [7:0] mn = (r <= g && r <= b) ? r : (g <= b) ? g : b;
    logic [7:0] r1, g1, b1, max1, delta1;
    logic valid1, valid2, chromatic2;
    logic [18:0] hue_n2, red_lo2, red_hi2, blue_lo2, blue_hi2;
    integer signed hue_n;
    wire red_hit = chromatic2 && ((hue_n2 <= red_hi2) || (hue_n2 >= red_lo2));
    wire blue_hit = chromatic2 && (hue_n2 >= blue_lo2) && (hue_n2 <= blue_hi2);
    always_comb begin
        if (max1 == r1) begin
            hue_n = 256 * (int'(g1) - int'(b1));
            if (g1 < b1) hue_n = hue_n + 1536 * int'(delta1);
        end else if (max1 == g1)
            hue_n = 512 * int'(delta1) + 256 * (int'(b1) - int'(r1));
        else
            hue_n = 1024 * int'(delta1) + 256 * (int'(r1) - int'(g1));
    end
    always_ff @(posedge clk) begin
        if (reset) begin
            valid1 <= 1'b0; valid2 <= 1'b0; out_valid <= 1'b0; mask <= 2'b00;
            r1 <= '0; g1 <= '0; b1 <= '0; max1 <= '0; delta1 <= '0;
            chromatic2 <= 1'b0; hue_n2 <= '0;
            red_lo2 <= '0; red_hi2 <= '0; blue_lo2 <= '0; blue_hi2 <= '0;
        end else if (ce) begin
            valid1 <= in_valid;
            r1 <= r; g1 <= g; b1 <= b; max1 <= mx; delta1 <= mx - mn;
            valid2 <= valid1;
            chromatic2 <= (delta1 != 0) && (32'(max1) >= VALUE_MIN) &&
                          (32'(delta1)*255 >= SAT_MIN*32'(max1));
            hue_n2 <= 19'(hue_n);
            red_lo2 <= 19'(RED_H_MIN*32'(delta1));
            red_hi2 <= 19'(RED_H_MAX*32'(delta1));
            blue_lo2 <= 19'(BLUE_H_MIN*32'(delta1));
            blue_hi2 <= 19'(BLUE_H_MAX*32'(delta1));
            out_valid <= valid2;
            mask <= !valid2 || (red_hit == blue_hit) ? 2'b00 : red_hit ? 2'b01 : 2'b10;
        end
    end
endmodule
