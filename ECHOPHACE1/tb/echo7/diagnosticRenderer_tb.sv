// ECHO-7 team | AI-assisted by OpenAI Codex; human review pending.
`timescale 1ns/1ps
module diagnosticRenderer_tb;
    import echo7_diag_pkg::*;
    import echo7_diag_ref_pkg::*;
    logic [9:0] x=0;
    logic [8:0] y=0;
    logic hsv_mode=0;
    region_result_t red_region='0,blue_region='0;
    wire hit;
    wire [29:0] data;
    wire [9:0] red_label_x,blue_label_x;
    wire [8:0] red_label_y,blue_label_y;
    diagnosticRenderer dut(.*);
    logic [7:0] character=0;
    logic [2:0] column=0,row=0;
    wire ink;
    diagnosticFont font_u(.*);
    task automatic scan;
        logic [30:0] expected;
        for(int py=0;py<480;py++) for(int px=0;px<640;px++) begin
            x=10'(px); y=9'(py); #1;
            expected=reference_graphics(px,py,red_region,blue_region,hsv_mode);
            if(hit!==expected[30] || (hit && data!==expected[29:0]))
                $fatal(1,"Renderer mismatch at (%0d,%0d), mode=%0d got=%h expected=%h char=%c digits=%h",px,py,hsv_mode,{hit,data},expected,dut.character,dut.digits);
        end
        if(red_label_x>376 || blue_label_x>376 || red_label_y>464 || blue_label_y>464)
            $fatal(1,"Label out of bounds");
        if(red_region.valid && blue_region.valid && int'(red_label_x)+264>int'(blue_label_x) &&
           int'(blue_label_x)+264>int'(red_label_x) && int'(red_label_y)+16>int'(blue_label_y) &&
           int'(blue_label_y)+16>int'(red_label_y)) $fatal(1,"Labels overlap");
    endtask
    initial begin
        region_acc_t a;
        logic [34:0] bitmap;
        // All ASCII inputs, including unsupported characters and spacer rows/columns.
        for(int c=0;c<128;c++) for(int r=0;r<8;r++) for(int col=0;col<8;col++) begin
            character=8'(c); row=3'(r); column=3'(col); bitmap=reference_font(byte'(c)); #1;
            if(ink !== ((r<7 && col<5) ? 1'((bitmap>>(5*(6-r)))>>(4-col)) : 1'b0))
                $fatal(1,"Font glyph/spacing mismatch c=%0d r=%0d col=%0d",c,r,col);
        end
        scan();
        a='0; a.valid=1; a.area=1; a.xmin=20; a.xmax=90; a.ymin=30; a.ymax=80;
        a.sum_r=211; a.sum_g=62; a.sum_b=57; red_region=finish_region(a);
        a.xmin=300; a.xmax=490; a.ymin=150; a.ymax=200;
        a.sum_r=49; a.sum_g=102; a.sum_b=194; blue_region=finish_region(a);
        scan(); hsv_mode=1; scan();
        // Colliding labels near lower/right edges; BLUE must relocate in bounds.
        red_region.xmin=600; red_region.xmax=639; red_region.ymin=470; red_region.ymax=479;
        blue_region.xmin=610; blue_region.xmax=639; blue_region.ymin=470; blue_region.ymax=479;
        scan();
        red_region.xmin=0; red_region.ymin=0; red_region.xmax=639; red_region.ymax=479;
        blue_region.xmin=1; blue_region.ymin=1; blue_region.xmax=638; blue_region.ymax=478;
        hsv_mode=0; scan();
        x=640; y=480; #1; if(hit) $fatal(1,"Drawing outside VGA");
        $display("PASS diagnosticRenderer_tb: all glyphs, RGB/HSV decimal text, full raster, box edges, no targets, clipping, overlap priority");
        $finish;
    end
    initial begin #10ms; $fatal(1,"Renderer timeout"); end
endmodule
