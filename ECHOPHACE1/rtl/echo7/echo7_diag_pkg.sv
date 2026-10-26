// ECHO-7 Phase 1.5 | Owner: MTRX3700 ECHO-7 team; human review pending.
// AI-assisted implementation: OpenAI Codex. See OWNERS.md and AI_STATEMENT.md.
package echo7_diag_pkg;
    // Coordinates and area are DISPLAY pixels (640x480), not framebuffer samples.
    typedef struct packed {
        logic valid, overflow;
        logic [9:0] xmin, xmax;
        logic [8:0] ymin, ymax;
        logic [18:0] area;
        logic [26:0] sum_r, sum_g, sum_b;
    } region_acc_t;
    typedef struct packed {
        logic valid;
        logic [9:0] xmin, xmax;
        logic [8:0] ymin, ymax;
        logic [18:0] area;
        logic [7:0] r, g, b;
        logic [8:0] h; // Degrees, 0..359. Achromatic hue is defined as zero.
        logic [7:0] s, v; // 0..255
        logic [35:0] rgb_digits, hsv_digits; // Three decimal digits per channel.
    } region_result_t;

    function automatic logic [11:0] decimal3(input logic [8:0] value);
        logic [11:0] digits;
        digits = '0;
        for (int bit_index=8; bit_index>=0; bit_index--) begin
            for (int digit_index=0; digit_index<3; digit_index++)
                if (digits[digit_index*4 +: 4] >= 5)
                    digits[digit_index*4 +: 4] = digits[digit_index*4 +: 4] + 4'd3;
            digits = {digits[10:0], value[bit_index]};
        end
        return digits;
    endfunction
endpackage
