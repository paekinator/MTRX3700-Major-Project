// ECHO-7 team | AI-assisted self-checking protocol test; human review required.
`timescale 1ns/1ps
module roiCalibration_protocol_tb;
    import echo7_diag_pkg::*;
    logic clk=0; always #20 clk=~clk;
    logic reset=1,in_valid=0,in_sop=0,in_eop=0,in_calibration=1,in_overlay=1,out_ready=1;
    logic [29:0] in_data={8'hff,2'b0,8'h00,2'b0,8'h00,2'b0};
    logic [1:0] in_mask=1,in_mode=0;
    wire in_ready,out_valid,out_sop,out_eop,out_calibration,display_detected;
    wire [29:0] out_data;
    region_result_t display_measurement;
    roiCalibration dut(.*);
    task automatic beat(input bit s,e);
        int cycles;
        @(negedge clk);in_valid=1;in_sop=s;in_eop=e;cycles=0;
        @(posedge clk);
        while(!in_ready && cycles<350) begin @(posedge clk);cycles++;end
        if(!in_ready) $fatal(1,"ROI boundary deadlock");
        @(negedge clk);in_valid=0;in_sop=0;in_eop=0;
    endtask
    task automatic clear;
        @(negedge clk);reset=1;in_valid=0;in_sop=0;in_eop=0;
        repeat(3) @(negedge clk);
        if(out_valid || display_measurement.valid || display_detected || dut.frame_wait)
            $fatal(1,"Reset failed");
        reset=0;
    endtask
    initial begin
        clear();beat(0,1);repeat(10) @(negedge clk);
        if(dut.frame_wait || dut.stats_id!=0) $fatal(1,"Orphan EOP changed frame state");
        in_sop=1;in_eop=1;repeat(10) @(negedge clk);in_sop=0;in_eop=0;
        if(dut.stats_id!=0) $fatal(1,"Invalid markers counted");
        beat(1,0);beat(0,1); // Deliberately early EOP, no complete sample.
        repeat(350) @(negedge clk);
        beat(1,0);
        if(display_measurement.valid || display_detected) $fatal(1,"Malformed frame published numbers");
        clear();
        // Continuous all-red frame reaches the maximum ROI count without wrapping.
        for(int p=0;p<640*480;p++) beat(p==0,p==640*480-1);
        if(dut.detect_count!=32000 || !dut.detected_snapshot) $fatal(1,"ROI maximum count mismatch");
        repeat(8) @(negedge clk);
        if(!dut.frame_wait) $fatal(1,"Expected arithmetic boundary wait");
        clear(); // Abort restoring division and its pending snapshot.
        repeat(350) @(negedge clk);
        if(dut.available || dut.metrics_done) $fatal(1,"Stale arithmetic result survived reset");
        // With no downstream ready a pending output and coordinates must hold.
        out_ready=0;beat(1,0);
        repeat(20) @(negedge clk);
        if(!out_valid || !out_sop || in_ready || dut.x!=1 || dut.y!=0)
            $fatal(1,"CE/backpressure altered coordinate or output");
        clear();out_ready=1;
        $display("PASS roiCalibration_protocol_tb: invalid/orphan markers, malformed frame, full ROI count, reset in division, CE/backpressure");
        $finish;
    end
    initial begin #100000000; $fatal(1,"Timeout"); end
endmodule
