// ECHO-7 Phase 1 | Owner: MTRX3700 ECHO-7 team; human review required.
// AI-assisted test code: OpenAI Codex. See OWNERS.md and AI_STATEMENT.md.
`timescale 1ns/1ps
module vgaMaskOverlay_tb;
    import echo7_ref_pkg::*;
    logic clk=0; always #20 clk=~clk;
    logic reset=1,in_valid=0,out_ready=0,in_overlay=0,in_sop=0,in_eop=0;
    logic [29:0] in_data=0;
    logic [1:0] in_mask=0;
    wire in_ready,out_valid,out_sop,out_eop;
    wire [29:0] out_data;
    vgaMaskOverlay dut(.*);
    bit ev=0,es=0,ee=0;
    logic [29:0] ed=0;
    initial begin
        for(int i=0;i<10000;i++) begin
            @(negedge clk);
            reset=(i%991==0); out_ready=($urandom_range(0,3)!=0);
            // A compliant source holds a pending offer until accepted.
            if(!in_valid || in_ready || reset) begin
                in_valid=($urandom_range(0,3)!=0); in_data=30'($urandom);
                in_mask=2'(i%4); in_overlay=1'(i/4); in_sop=1'($urandom); in_eop=1'($urandom);
            end
            #1;
            if(reset) begin ev=0; es=0; ee=0; ed=0; end
            else if(in_ready) begin
                ev=in_valid; es=in_valid && in_sop; ee=in_valid && in_eop;
                ed=in_valid?overlay(in_data,in_mask,in_overlay):in_data;
            end
            @(posedge clk); #1;
            if({out_valid,out_sop,out_eop,out_data} !== {ev,es,ee,ed}) $fatal(1,"Overlay mismatch i=%0d",i);
        end
        $display("PASS vgaMaskOverlay_tb: all mask/enable combinations, reserved mask, arbitrary original bits, stalls/reset/bubbles");
        $finish;
    end
endmodule
