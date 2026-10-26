`timescale 1ns/1ps
// hex_digit.sv -- one hexadecimal digit on a DE1-SoC seven-segment display (segments are active LOW).
// (The same decoder as ir/rtl/seven_seg.sv, renamed: this project also uses sonar/rtl/seven_seg.sv,
//  the decimal one that display.sv instantiates.)
module hex_digit (
    input  logic [3:0] d,
    input  logic       blank,
    output logic [6:0] seg
);
    always_comb begin
        case (d)
            4'h0: seg = 7'b1000000;
            4'h1: seg = 7'b1111001;
            4'h2: seg = 7'b0100100;
            4'h3: seg = 7'b0110000;
            4'h4: seg = 7'b0011001;
            4'h5: seg = 7'b0010010;
            4'h6: seg = 7'b0000010;
            4'h7: seg = 7'b1111000;
            4'h8: seg = 7'b0000000;
            4'h9: seg = 7'b0010000;
            4'hA: seg = 7'b0001000;
            4'hB: seg = 7'b0000011;
            4'hC: seg = 7'b1000110;
            4'hD: seg = 7'b0100001;
            4'hE: seg = 7'b0000110;
            default: seg = 7'b0001110;
        endcase
        if (blank) seg = 7'b1111111;
    end
endmodule
