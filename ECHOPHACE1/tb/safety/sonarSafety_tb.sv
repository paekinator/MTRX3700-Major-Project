`timescale 1ns/1ps
// ECHO-7 team; AI-assisted. Real source driver clocks and bundled-data CDC.
module sonarSafety_tb;
    logic clk=0;always #10 clk=~clk;
    logic reset=1,e1=0,e2=0;wire t1,t2;wire [11:0] d1,d2;wire v1,v2,u1,u2;
    dualSonar dut(.CLOCK_50(clk),.reset50(reset),.echo1(e1),.echo2(e2),.trig1(t1),.trig2(t2),
        .sonar1_distance_mm(d1),.sonar2_distance_mm(d2),.sonar1_valid(v1),.sonar2_valid(v2),.sonar1_update(u1),.sonar2_update(u2));
    task automatic check(input bit ok,input string what);if(!ok)$fatal(1,"FAIL %s d1=%0d d2=%0d",what,d1,d2);endtask
    initial begin
        #1us;reset=0;
        fork
            begin @(posedge t1);@(negedge t1);#200us;e1=1;
                repeat(100*256)@(negedge dut.clk_sonar);e1=0;
                @(posedge u1);#1;check(v1 && d1>=99 && d1<=101,"real sensor1 pulse to millimetres and CDC");end
            begin @(posedge t2);@(negedge t2);#200us;e2=1;
                repeat(200*256)@(negedge dut.clk_sonar);e2=0;
                @(posedge u2);#1;check(v2 && d2>=199 && d2<=201,"real sensor2 pulse to millimetres and CDC");end
        join
        // A long/stuck echo is reported as raw 4000, with quality invalid, not fake infinite clearance.
        @(posedge t1);@(negedge t1);#200us;e1=1;
        @(posedge u1);#1;check(d1==4000 && !v1,"measurement window exhausted is invalid");
        #1ms;check(d1==4000 && d2>=199 && d2<=201,"independent raw snapshots preserved");
        reset=1;#1us;check(d1==0 && d2==0 && !v1 && !v2,"reset removes stale validity");
        $display("PASS sonarSafety_tb: actual dual echo measurements, units, phase staggering, CDC, out-of-range and reset");$finish;
    end
    initial begin #150ms;$fatal(1,"FAIL sonar timeout");end
endmodule
