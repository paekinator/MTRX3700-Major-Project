// ECHO-7 team; AI-assisted by OpenAI Codex. Active-low DE1-SoC hexadecimal glyph.
module safetyHex(input logic [3:0] value, output logic [6:0] segments);
    always_comb case(value)
        0:segments=7'h40; 1:segments=7'h79; 2:segments=7'h24; 3:segments=7'h30;
        4:segments=7'h19; 5:segments=7'h12; 6:segments=7'h02; 7:segments=7'h78;
        8:segments=7'h00; 9:segments=7'h10; 10:segments=7'h08; 11:segments=7'h03;
        12:segments=7'h46; 13:segments=7'h21; 14:segments=7'h06; 15:segments=7'h0E;
    endcase
endmodule
