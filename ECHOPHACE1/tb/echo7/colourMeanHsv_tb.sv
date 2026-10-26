// ECHO-7 team | AI-assisted by OpenAI Codex; human review pending.
`timescale 1ns/1ps
module colourMeanHsv_tb;
    import echo7_diag_pkg::*;
    import echo7_diag_ref_pkg::*;
    logic clk=0; always #20 clk=~clk;
    logic reset=1,start=0;
    region_acc_t red_stats='0,blue_stats='0;
    wire busy,done;
    logic [1:0] in_mode=0;
    logic [15:0] in_frame_id=0;
    wire [1:0] out_mode;
    wire [15:0] out_frame_id;
    region_result_t red_result,blue_result,er,eb;
    colourMeanHsv dut(.*);
    function automatic region_acc_t sample(input int r,g,b,area);
        region_acc_t a;
        a='0; a.valid=1; a.area=19'(area); a.sum_r=27'(r*area);
        a.sum_g=27'(g*area); a.sum_b=27'(b*area);
        a.xmin=17; a.xmax=639; a.ymin=23; a.ymax=479;
        return a;
    endfunction
    task automatic check_pair(input region_acc_t a,b);
        int cycles;
        @(negedge clk); red_stats=a; blue_stats=b; in_frame_id++; in_mode=2'(in_frame_id); start=1;
        er=finish_region(a); eb=finish_region(b);
        @(negedge clk); start=0; cycles=0;
        while(!done && cycles<310) begin @(negedge clk); cycles++; end
        if(!done || busy) $fatal(1,"Metrics exceeded boundary budget");
        if(red_result!==er || blue_result!==eb) $fatal(1,"Mean/HSV/BCD mismatch case %0d red got RGB=%0d,%0d,%0d HSV=%0d,%0d,%0d expected H=%0d",in_frame_id,red_result.r,red_result.g,red_result.b,red_result.h,red_result.s,red_result.v,er.h);
        if(out_mode!==in_mode || out_frame_id!==in_frame_id) $fatal(1,"Frame identity mismatch");
    endtask
    initial begin
        region_acc_t a,b;
        repeat(3) @(negedge clk); reset=0;
        check_pair(sample(255,0,0,307200),sample(0,0,255,307200));
        if(red_result.h!=0 || blue_result.h!=240) $fatal(1,"Primary hue mismatch");
        check_pair(sample(255,255,0,7),sample(0,255,255,9));
        if(red_result.h!=60 || blue_result.h!=180) $fatal(1,"Secondary hue mismatch");
        check_pair(sample(0,255,0,1),sample(255,0,255,1));
        check_pair(sample(0,0,0,42),sample(255,255,255,307200));
        check_pair(sample(255,0,1,19),sample(255,1,0,21));
        if(red_result.h!=0 || blue_result.h!=0) $fatal(1,"Hue wrap rounding mismatch");
        check_pair(sample(128,127,128,1),sample(2,1,1,1));
        a=sample(0,0,0,2); a.sum_r=1; a.sum_g=3; a.sum_b=5;
        b='0; check_pair(a,b);
        if(red_result.r!=1 || red_result.g!=2 || red_result.b!=3) $fatal(1,"Mean ties must round up");
        a=sample(255,0,0,10); a.overflow=1; check_pair(a,b);
        for(int i=0;i<500;i++) begin
            a=sample($urandom_range(0,255),$urandom_range(0,255),$urandom_range(0,255),$urandom_range(1,307200));
            b=sample($urandom_range(0,255),$urandom_range(0,255),$urandom_range(0,255),$urandom_range(1,307200));
            check_pair(a,b);
        end
        @(negedge clk); start=1; red_stats=sample(200,50,20,20);
        @(negedge clk); start=0; repeat(5) @(negedge clk); reset=1;
        @(negedge clk); if(busy || done || red_result.valid || blue_result.valid) $fatal(1,"Reset during division");
        reset=0; check_pair(sample(255,0,0,4),sample(0,0,255,4));
        $display("PASS colourMeanHsv_tb: mean rounding, max sums, HSV sectors/wrap/grey/black, BCD, random, reset, frame tags, <=310 clocks");
        $finish;
    end
    initial begin #20ms; $fatal(1,"Metrics timeout"); end
endmodule
