// ECHO-7 team | AI-assisted by OpenAI Codex; human review pending.
`timescale 1ns/1ps
module colourDiagnostics_protocol_tb;
    import echo7_diag_pkg::*;
    import echo7_ref_pkg::*;
    logic clk=0; always #20 clk=~clk;
    logic reset=1,in_valid=0,in_sop=0,in_eop=0,in_overlay=1,out_ready=1;
    logic [29:0] in_data=0;
    logic [1:0] in_mask=1,in_mode=0;
    wire in_ready,out_valid,out_sop,out_eop;
    wire [29:0] out_data;
    region_result_t display_red,display_blue;
    wire [15:0] display_frame_id;
    colourDiagnostics #(.H_RES(264),.V_RES(34),.MIN_AREA(3)) dut(.*);
    transaction q[$],t,u;
    bit green_expected=0,held=0,force_stall=0;
    logic [31:0] held_payload;
    int transfers=0;
    always @(negedge clk) out_ready=!force_stall && $urandom_range(0,3)!=0;
    always @(posedge clk) begin
        if(reset) begin q.delete();held=0;end
        else begin
            if(in_valid && in_ready) begin
                t.data=green_expected ? {8'd0,2'b0,8'd255,2'b0,8'd0,2'b0} : overlay(in_data,in_mask,in_overlay);
                t.sop=in_sop;t.eop=in_eop;t.mask=0;t.enable=0;q.push_back(t);
            end
            if(held && {out_valid,out_data,out_sop,out_eop}!=={1'b1,held_payload}) $fatal(1,"Held diagnostics output changed");
            held=out_valid&&!out_ready; held_payload={out_data,out_sop,out_eop};
            if(out_valid && out_ready) begin
                if(q.size()==0) $fatal(1,"Unexpected protocol output");
                u=q.pop_front();
                if({out_data,out_sop,out_eop}!=={u.data,u.sop,u.eop}) $fatal(1,"Protocol data/metadata mismatch");
                transfers++;
            end
        end
    end
    task automatic pixel(input bit sop,eop);
        int cycles;
        @(negedge clk); in_data=video(16'hc924); in_valid=1; in_sop=sop;in_eop=eop;
        cycles=0;
        @(posedge clk);
        while(!in_ready && cycles<350) begin @(posedge clk);cycles++;end
        if(!in_ready) $fatal(1,"Boundary/input deadlock");
        @(negedge clk); in_valid=0;in_sop=0;in_eop=0;
    endtask
    task automatic clear_reset;
        @(negedge clk);reset=1;in_valid=0;
        repeat(3) @(negedge clk);
        if(out_valid || dut.frame_wait || display_red.valid || display_blue.valid) $fatal(1,"Reset did not clear diagnostics");
        reset=0;green_expected=0;in_mode=0;
    endtask
    task automatic frame;
        for(int p=0;p<264*34;p++) pixel(p==0,p==264*34-1);
    endtask
    initial begin
        logic [29:0] original;
        clear_reset();
        // A stray EOP before SOP must not wedge the boundary barrier.
        pixel(0,1); pixel(0,0);
        // Invalid markers must not start/finish a frame or alter the pixel count.
        @(negedge clk);in_sop=1;in_eop=1;in_valid=0;
        repeat(5) @(negedge clk);in_sop=0;in_eop=0;
        if(dut.frame_wait || dut.stats_id!=0) $fatal(1,"Invalid beat changed frame state");
        frame(); repeat(5) @(negedge clk);
        if(!dut.frame_wait) $fatal(1,"Expected division in progress");
        clear_reset(); // Reset during frame arithmetic.
        frame(); green_expected=1; pixel(1,0);
        original=video(16'hc924);
        if(!display_red.valid || display_red.area!=264*34 || display_red.r!==original[29:22] ||
           display_red.g!==original[19:12] || display_red.b!==original[9:2])
            $fatal(1,"Mean must use original detected pixels, not solid mask RGB");
        green_expected=0; in_mode=2; pixel(1,0);
        if(display_red.valid || display_blue.valid) $fatal(1,"Old algorithm snapshot visible after switch");
        // Reset while an output is held under downstream backpressure.
        wait(q.size()==0); force_stall=1; pixel(0,0); repeat(3) @(negedge clk);
        clear_reset(); force_stall=0;
        in_overlay=0; pixel(1,0); pixel(0,1);
        wait(q.size()==0); repeat(4) @(negedge clk);
        $display("PASS colourDiagnostics_protocol_tb: invalid/stray markers, boundary backpressure, snapshot, original-pixel means, mode switch, reset in arithmetic/stall, raw mode; transfers=%0d",transfers);
        $finish;
    end
    initial begin #5ms;$fatal(1,"Diagnostics protocol timeout");end
endmodule
