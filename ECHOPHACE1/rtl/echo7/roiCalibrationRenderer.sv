// ECHO-7 team | AI-assisted by OpenAI Codex; human review required.
module roiCalibrationRenderer (
    input logic [9:0] x,
    input logic [8:0] y,
    input logic [1:0] mode,
    input logic detected,
    input echo7_diag_pkg::region_result_t measurement,
    output logic hit,
    output logic [29:0] data
);
    logic border, panel, ink;
    logic [7:0] character;
    logic [2:0] font_column, font_row;
    logic [35:0] digits;
    integer line_index, char_index, digit_index;
    logic [127:0] text_line;
    always_comb begin
        border=x>=220 && x<=419 && y>=160 && y<=319 &&
               (x==220 || x==419 || y==160 || y==319);
        // Four 16-pixel rows; the rest of the image is untouched.
        panel=x>=16 && x<244 && y>=408 && y<472;
        line_index=(int'(y)-408)/16;
        char_index=(int'(x)-16)/12;
        font_column=3'(((int'(x)-16)%12)/2);
        font_row=3'(((int'(y)-408)%16)/2);
        character=" "; text_line='0; digits='0; digit_index=0;
        case(line_index)
            0: begin
                case(mode)
                    1: text_line="MODE: RGB RATIO ";
                    2: text_line="MODE: HSV       ";
                    default: text_line="MODE: FIXED RGB ";
                endcase
                // Strings above contain 16 characters, stored MSB first.
                if(char_index>=0 && char_index<16) character=text_line[127-char_index*8 -:8];
            end
            1,2: begin
                digits=line_index==1 ? measurement.rgb_digits : measurement.hsv_digits;
                case(char_index)
                    0: character=line_index==1 ? "R" : "H";
                    1: character=line_index==1 ? "G" : "S";
                    2: character=line_index==1 ? "B" : "V";
                    3: character=":";
                    8,13: character=",";
                    5,6,7,10,11,12,15,16,17: begin
                        if(char_index<=7) digit_index=char_index-5;
                        else if(char_index<=12) digit_index=char_index-7;
                        else digit_index=char_index-9;
                        character=measurement.valid ? 8'd48+8'(digits[35-digit_index*4 -:4]) : "-";
                    end
                    default: begin end
                endcase
            end
            3: begin
                if(!measurement.valid) text_line="DETECT: ---     ";
                else if(detected) text_line="DETECT: YES     ";
                else text_line="DETECT: NO      ";
                if(char_index>=0 && char_index<16) character=text_line[127-char_index*8 -:8];
            end
            default: begin end
        endcase
        hit=border || panel;
        data=border ? {8'hff,2'b0,8'h00,2'b0,8'h00,2'b0} :
                     (ink ? {8'hff,2'b0,8'hff,2'b0,8'hff,2'b0} : 30'd0);
    end
    diagnosticFont font_u(.character,.column(font_column),.row(font_row),.ink);
endmodule
