// ECHO-7 Phase 1.5 | Owner: MTRX3700 ECHO-7 team; human review pending.
// AI-assisted implementation: OpenAI Codex. See OWNERS.md and AI_STATEMENT.md.
module diagnosticRenderer #(parameter int H_RES=640, V_RES=480) (
    input logic [9:0] x,
    input logic [8:0] y,
    input logic hsv_mode,
    input echo7_diag_pkg::region_result_t red_region, blue_region,
    output logic hit,
    output logic [29:0] data,
    output logic [9:0] red_label_x, blue_label_x,
    output logic [8:0] red_label_y, blue_label_y
);
    import echo7_diag_pkg::*;
    localparam int TEXT_W=264, TEXT_H=16; // 22 characters, 5x7 font at 2x scale.
    localparam logic [29:0] GREEN={8'h00,2'b00,8'hff,2'b00,8'h00,2'b00};
    localparam logic [29:0] WHITE={8'hff,2'b00,8'hff,2'b00,8'hff,2'b00};
    logic red_box, blue_box, red_text, blue_text, text_active, is_blue, ink;
    logic [9:0] dx;
    logic [8:0] dy;
    logic [4:0] character_index;
    logic [2:0] font_column, font_row;
    logic [7:0] character;
    logic [35:0] digits;

    function automatic logic border(input region_result_t r,input logic [9:0] px,input logic [8:0] py);
        return r.valid && px>=r.xmin && px<=r.xmax && py>=r.ymin && py<=r.ymax &&
               (px==r.xmin || px==r.xmax || py==r.ymin || py==r.ymax);
    endfunction
    function automatic logic [8:0] label_y(input region_result_t r);
        if(int'(r.ymax)+2+TEXT_H<=V_RES) return 9'(int'(r.ymax)+2);
        if(int'(r.ymin)>=TEXT_H+2) return 9'(int'(r.ymin)-TEXT_H-2);
        return 9'(V_RES-TEXT_H);
    endfunction
    always_comb begin
        red_label_x = red_region.xmin>H_RES-TEXT_W ? 10'(H_RES-TEXT_W) : red_region.xmin;
        blue_label_x = blue_region.xmin>H_RES-TEXT_W ? 10'(H_RES-TEXT_W) : blue_region.xmin;
        red_label_y=label_y(red_region); blue_label_y=label_y(blue_region);
        // Labels normally sit below each box. At edges use above/inside. If labels
        // overlap, move BLUE to the next free row adjacent to RED, always in bounds.
        if(red_region.valid && blue_region.valid &&
           int'(red_label_x)<int'(blue_label_x)+TEXT_W && int'(blue_label_x)<int'(red_label_x)+TEXT_W &&
           int'(red_label_y)<int'(blue_label_y)+TEXT_H && int'(blue_label_y)<int'(red_label_y)+TEXT_H) begin
            if(int'(red_label_y)+2*TEXT_H+2<=V_RES) blue_label_y=9'(int'(red_label_y)+TEXT_H+2);
            else blue_label_y=9'(int'(red_label_y)-TEXT_H-2);
        end
        red_box=border(red_region,x,y); blue_box=border(blue_region,x,y);
        red_text=red_region.valid && x>=red_label_x && int'(x)<int'(red_label_x)+TEXT_W &&
                 y>=red_label_y && int'(y)<int'(red_label_y)+TEXT_H;
        blue_text=blue_region.valid && x>=blue_label_x && int'(x)<int'(blue_label_x)+TEXT_W &&
                  y>=blue_label_y && int'(y)<int'(blue_label_y)+TEXT_H;
        text_active=red_text || blue_text;
        is_blue=blue_text && !red_text;
        dx=x-(is_blue ? blue_label_x : red_label_x);
        dy=y-(is_blue ? blue_label_y : red_label_y);
        character_index=5'(dx/10'd12);
        font_column=3'((dx%10'd12)>>1); font_row=3'(dy>>1);
        digits=is_blue ? (hsv_mode ? blue_region.hsv_digits : blue_region.rgb_digits) :
                         (hsv_mode ? red_region.hsv_digits : red_region.rgb_digits);
        character=" ";
        case(character_index)
            0: character=is_blue ? "B" : "R";
            1: character=is_blue ? "L" : "E";
            2: character=is_blue ? "U" : "D";
            3: character=is_blue ? "E" : " ";
            5: character=hsv_mode ? "H" : "R";
            6,12,18: character=":";
            7: character=8'd48+8'(digits[35:32]);
            8: character=8'd48+8'(digits[31:28]);
            9: character=8'd48+8'(digits[27:24]);
            11: character=hsv_mode ? "S" : "G";
            13: character=8'd48+8'(digits[23:20]);
            14: character=8'd48+8'(digits[19:16]);
            15: character=8'd48+8'(digits[15:12]);
            17: character=hsv_mode ? "V" : "B";
            19: character=8'd48+8'(digits[11:8]);
            20: character=8'd48+8'(digits[7:4]);
            21: character=8'd48+8'(digits[3:0]);
            default: begin end
        endcase
        hit=(x<H_RES && y<V_RES) && (red_box || blue_box || text_active);
        // Text wins over crossing box edges. Both box colours are green.
        data=text_active ? (ink ? WHITE : 30'd0) : GREEN;
    end
    diagnosticFont font_u(.character,.column(font_column),.row(font_row),.ink);
`ifndef SYNTHESIS
    initial assert(H_RES>=TEXT_W && H_RES<=640 && V_RES>=2*TEXT_H+2 && V_RES<=480)
        else $fatal(1,"diagnosticRenderer dimensions cannot fit two labels");
`endif
endmodule
