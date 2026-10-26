// ECHO-7 Phase 1 | Owner: MTRX3700 ECHO-7 team; human review required.
// AI-assisted test code: OpenAI Codex. See OWNERS.md and AI_STATEMENT.md.
`timescale 1ns/1ps
module echo7_algorithms_tb;
    import echo7_ref_pkg::*;
    logic clk=0; always #20 clk=~clk;
    logic reset=1,ce=0,in_valid=0;
    logic [15:0] rgb565=0;
    wire fv,rv,hv,eqv,ov;
    wire [1:0] fm,rm,hm,eqm,om;
    rgbFixedSeg f(.clk,.reset,.ce,.in_valid,.rgb565,.out_valid(fv),.mask(fm));
    rgbRatioSeg r(.clk,.reset,.ce,.in_valid,.rgb565,.out_valid(rv),.mask(rm));
    hsvSeg h(.clk,.reset,.ce,.in_valid,.rgb565,.out_valid(hv),.mask(hm));
    rgbFixedSeg #(.RED_R_MIN(165),.RED_G_MAX(97),.RED_B_MAX(99),
        .BLUE_B_MIN(165),.BLUE_R_MAX(99),.BLUE_G_MAX(97)) equality_u
        (.clk,.reset,.ce,.in_valid,.rgb565,.out_valid(eqv),.mask(eqm));
    rgbFixedSeg #(.RED_R_MIN(0),.RED_G_MAX(255),.RED_B_MAX(255),
        .BLUE_B_MIN(0),.BLUE_R_MAX(255),.BLUE_G_MAX(255)) overlap_u
        (.clk,.reset,.ce,.in_valid,.rgb565,.out_valid(ov),.mask(om));
    logic [1:0] ef,er,eh[0:2];
    bit ev,vh[0:2];
    int checks=0, red_count=0, blue_count=0;
    task automatic step(input logic [15:0] p,input bit valid_i,input bit enable_i,input bit rst_i);
        @(negedge clk); rgb565=p; in_valid=valid_i; ce=enable_i; reset=rst_i;
        if(rst_i) begin
            ev=0; ef=0; er=0;
            for(int j=0;j<3;j++) begin vh[j]=0; eh[j]=0; end
        end else if(enable_i) begin
            ev=valid_i; ef=valid_i?classify(p,0):2'b00; er=valid_i?classify(p,1):2'b00;
            for(int j=2;j>0;j--) begin vh[j]=vh[j-1]; eh[j]=eh[j-1]; end
            vh[0]=valid_i; eh[0]=valid_i?classify(p,2):2'b00;
        end
        @(posedge clk); #1;
        if({fv,fm,rv,rm,hv,hm} !== {ev,ef,ev,er,vh[2],eh[2]})
            $fatal(1,"Algorithm mismatch p=%h ce=%b rst=%b fixed=%b/%b ratio=%b/%b hsv=%b/%b",p,ce,reset,fm,ef,rm,er,hm,eh[2]);
        // Equivalent reachable limits: 160 -> 165, 100 -> R/B99 and G97.
        if({eqv,eqm} !== {ev,ef} || {ov,om} !== {ev,2'b00}) $fatal(1,"Equality/overlap mismatch");
        checks++;
    endtask
    initial begin
        step(0,0,0,1);
        for(int p=0;p<65536;p++) begin
            step(16'(p),1,1,0);
            if(fm==1) red_count++;
            if(fm==2) blue_count++;
        end
        if(red_count!=3900 || blue_count!=3900) $fatal(1,"Fixed exhaustive count mismatch");
        for(int i=0;i<10000;i++) step(16'($urandom),($urandom_range(0,3)!=0),($urandom_range(0,3)!=0),(i%997==0));
        step(16'hf800,1,1,0); step(16'h001f,1,0,0); step(0,0,0,1);
        repeat(4) step(0,0,1,0);
        $display("PASS echo7_algorithms_tb: all 65536 RGB565 values per algorithm; CE/reset/bubbles/equality/overlap; checks=%0d",checks);
        $finish;
    end
    initial begin #10ms; $fatal(1,"Algorithm timeout"); end
endmodule
