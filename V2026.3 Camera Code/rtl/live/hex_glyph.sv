`timescale 1ns/1ps
/*
 *  hex_glyph.sv -- draw one hexadecimal digit (0-9, A-F) on the screen, as a 3x5 dot font.
 *
 *  A font is a table: 16 characters, each 15 bits (3 columns x 5 rows, row-major, top-left first).
 *  For the pixel being drawn at (x, y), the module says whether it falls on a lit dot of the digit
 *  `value` whose top-left corner is (x0, y0), with every dot drawn SCALE x SCALE pixels. Purely
 *  combinational: put it in the pixel path and OR its `on` into your colour choice.
 *
 *      hex_glyph #(.SCALE(3)) u_tens (.x(px_x), .y(px_y), .x0(4), .y0(4), .value(code[7:4]), .on(on_tens));
 *
 *  Width of a digit: 3*SCALE; height 5*SCALE; leave one dot column between digits. The two
 *  divisions by SCALE are on tiny numbers (a handful of logic cells); a power-of-two SCALE makes them
 *  shifts. (Quartus 18.1 cannot index a function call, hence the intermediate `g`.)
 */
module hex_glyph #(
    parameter int XW    = 9,       // width of x and x0
    parameter int YW    = 8,       // width of y and y0
    parameter int SCALE = 3
) (
    input  logic [XW-1:0] x, x0,
    input  logic [YW-1:0] y, y0,
    input  logic [3:0]    value,
    output logic          on
);
    function automatic logic [14:0] glyph(input logic [3:0] d);
        case (d)
            4'h0: glyph = 15'b111_101_101_101_111;  4'h1: glyph = 15'b010_110_010_010_111;
            4'h2: glyph = 15'b111_001_111_100_111;  4'h3: glyph = 15'b111_001_111_001_111;
            4'h4: glyph = 15'b101_101_111_001_001;  4'h5: glyph = 15'b111_100_111_001_111;
            4'h6: glyph = 15'b111_100_111_101_111;  4'h7: glyph = 15'b111_001_001_001_001;
            4'h8: glyph = 15'b111_101_111_101_111;  4'h9: glyph = 15'b111_101_111_001_111;
            4'hA: glyph = 15'b010_101_111_101_101;  4'hB: glyph = 15'b110_101_110_101_110;
            4'hC: glyph = 15'b111_100_100_100_111;  4'hD: glyph = 15'b110_101_101_101_110;
            4'hE: glyph = 15'b111_100_111_100_111;  4'hF: glyph = 15'b111_100_111_100_100;
            default: glyph = '0;
        endcase
    endfunction
    logic [14:0] g;
    always_comb begin
        on = 1'b0;
        g  = glyph(value);
        if (x >= x0 && x < x0 + 3 * SCALE && y >= y0 && y < y0 + 5 * SCALE) begin
            automatic int gx = int'(x - x0) / SCALE, gy = int'(y - y0) / SCALE;
            on = g[14 - (gy * 3 + gx)];
        end
    end
endmodule
