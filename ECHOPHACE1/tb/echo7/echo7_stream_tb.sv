// ECHO-7 Phase 1 | Owner: MTRX3700 ECHO-7 team; human review required.
// AI-assisted test code: OpenAI Codex. See OWNERS.md and AI_STATEMENT.md.
`timescale 1ns/1ps
module echo7_stream_tb;
    import echo7_ref_pkg::*;
    logic clk=0; always #20 clk=~clk;
    logic reset=1;
    logic [2:0] control_async=0, expected_control=0, frame_control=0;
    logic [29:0] in_data=0;
    logic in_sop=0,in_eop=0,in_valid=0;
    wire in_ready;
    wire [29:0] seg_data,out_data;
    wire [1:0] seg_mask;
    wire seg_sop,seg_eop,seg_valid,seg_ready,seg_overlay;
    wire out_sop,out_eop,out_valid;
    logic out_ready=0, force_stall=0, random_ready=1;
    segmentationSelector #(.STABLE_CYCLES(4)) dut(.clk,.reset,.control_async,
        .in_data,.in_sop,.in_eop,.in_valid,.in_ready,
        .out_data(seg_data),.out_sop(seg_sop),.out_eop(seg_eop),.out_valid(seg_valid),.out_ready(seg_ready),
        .out_mask(seg_mask),.out_overlay(seg_overlay));
    vgaMaskOverlay ov(.clk,.reset,.in_data(seg_data),.in_mask(seg_mask),.in_overlay(seg_overlay),
        .in_sop(seg_sop),.in_eop(seg_eop),.in_valid(seg_valid),.in_ready(seg_ready),
        .out_data,.out_sop,.out_eop,.out_valid,.out_ready);
    transaction seg_q[$],out_q[$],t,u;
    int inputs=0,outputs=0;
    logic held=0;
    logic [31:0] held_payload;
    always @(negedge clk) out_ready= !force_stall && (!random_ready || $urandom_range(0,3)!=0);
    always @(posedge clk) begin
        if(reset) begin seg_q.delete(); out_q.delete(); frame_control=0; held=0; end
        else begin
            if(in_valid && in_ready) begin
                if(in_sop) frame_control=expected_control;
                t.data=in_data; t.sop=in_sop; t.eop=in_eop; t.enable=frame_control[2];
                t.mask=classify({in_data[29:25],in_data[19:14],in_data[9:5]},int'(frame_control[1:0]));
                seg_q.push_back(t); t.data=overlay(t.data,t.mask,t.enable); out_q.push_back(t); inputs++;
            end
            if(seg_valid && seg_ready) begin
                if(seg_q.size()==0) $fatal(1,"Unexpected selector output");
                u=seg_q.pop_front();
                if({seg_data,seg_sop,seg_eop,seg_mask,seg_overlay} !== {u.data,u.sop,u.eop,u.mask,u.enable})
                    $fatal(1,"Selector pixel/control alignment mismatch");
            end
            if(held && {out_valid,out_data,out_sop,out_eop} !== {1'b1,held_payload}) $fatal(1,"Output changed during backpressure");
            held=out_valid && !out_ready; held_payload={out_data,out_sop,out_eop};
            if(out_valid && out_ready) begin
                if(out_q.size()==0) $fatal(1,"Unexpected overlay output");
                u=out_q.pop_front();
                if({out_data,out_sop,out_eop} !== {u.data,u.sop,u.eop}) $fatal(1,"Overlay/SOP/EOP mismatch");
                outputs++;
            end
        end
    end
    task automatic settle(input logic [2:0] cfg);
        @(negedge clk); control_async=cfg;
        repeat(16) @(negedge clk);
        expected_control=cfg;
    endtask
    task automatic pixel(input logic [15:0] p,input bit sop,input bit eop);
        @(negedge clk); in_data=video(p); in_valid=1; in_sop=sop; in_eop=eop;
        @(posedge clk); while(!in_ready) @(posedge clk);
        @(negedge clk); in_valid=0; in_sop=0; in_eop=0;
    endtask
    task automatic drain;
        wait(out_q.size()==0 && seg_q.size()==0);
        repeat(4) @(negedge clk);
    endtask
    initial begin
        repeat(3) @(negedge clk); reset=0;
        for(int mode=0;mode<8;mode++) begin
            settle(3'(mode));
            for(int p=0;p<80;p++) pixel(16'($urandom),p==0,p==79);
            drain();
        end
        // A stable request arriving mid-frame must not affect the rest of that frame.
        settle(3'b100); pixel(16'hf800,1,0);
        settle(3'b110); pixel(16'h8410,0,1); drain();
        pixel(16'h8410,1,0); pixel(16'h001f,0,1); drain();
        // Short mechanical excursions do not change the next frame's stable request.
        @(negedge clk); control_async=3'b001;
        @(negedge clk); control_async=3'b110;
        repeat(16) @(negedge clk);
        pixel(16'hf800,1,1); drain();
        // Sustain one accepted input and output each cycle after initial fill.
        random_ready=0; settle(3'b101);
        for(int p=0;p<256;p++) begin
            @(negedge clk); in_valid=1; in_data=video(16'(p*211)); in_sop=(p==0); in_eop=(p==255);
            @(posedge clk); if(!in_ready) $fatal(1,"Throughput stall without backpressure");
        end
        @(negedge clk); in_valid=0; in_sop=0; in_eop=0; drain();
        // Stop the sink, retain data in flight, then reset without waiting for a blocked sender.
        force_stall=1;
        pixel(16'hf800,1,0); pixel(16'h001f,0,0);
        repeat(5) @(negedge clk);
        reset=1; repeat(3) @(negedge clk); expected_control=0; control_async=0; reset=0; force_stall=0;
        settle(3'b100); pixel(16'h001f,1,1); drain();
        $display("PASS echo7_stream_tb: selector/overlay, all modes, frame latch, debounce, backpressure, reset, full throughput; in=%0d out=%0d",inputs,outputs);
        $finish;
    end
    initial begin #5ms; $fatal(1,"Stream timeout"); end
endmodule
