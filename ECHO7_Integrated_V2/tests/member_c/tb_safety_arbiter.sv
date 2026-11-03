`timescale 1ns/1ps
module tb_safety_arbiter;
 wire taskEnabled;
 logic motion_enable=1;
 logic clk=0,reset=1,power_frame=0,estop_frame=0,distance_valid=0;
 logic [11:0] distance_mm=500;
 wire permit,used,estop,sonar_stop;
 wire [2:0] reason;
 always #10 clk=~clk;
 safety_arbiter dut(.*);
 task automatic step; @(posedge clk);#1;endtask
 task automatic clear; @(negedge clk);reset=1;step();@(negedge clk);reset=0;endtask
 task automatic power;@(negedge clk);power_frame=1;step();@(negedge clk);power_frame=0;endtask
 initial begin
 step();reset=0;power();if(permit) $fatal(1,"startup blocked");
 distance_valid=1;step();if(permit) $fatal(1,"no automatic recovery");
 clear();power();if(!permit) $fatal(1,"500 permitted");
 distance_mm=400;step();if(!permit) $fatal(1,"400 permitted");
 distance_mm=350;step();if(!permit) $fatal(1,"350 permitted");
 distance_mm=300;step();if(!permit) $fatal(1,"300 permitted");
 distance_mm=200;step();if(permit || !sonar_stop || reason!=2) $fatal(1,"200 safety stop");
 distance_mm=500;power();if(permit) $fatal(1,"safety latch");
 estop_frame=1;step();if(reason!=1 || !estop) $fatal(1,"A priority");
 estop_frame=0;power();if(permit) $fatal(1,"A latch");
 clear();distance_mm=500;power();
 distance_mm=200;estop_frame=1;step();
 if(reason!=1 || permit || !estop) $fatal(1,"simultaneous A and near");
 estop_frame=0;clear();distance_mm=500;power();distance_valid=0;step();
 if(permit || !sonar_stop) $fatal(1,"invalid during run");
 distance_valid=1;power();if(permit) $fatal(1,"fault latch");
 clear();power();repeat(200) step();if(!permit) $fatal(1,"safe motion must continue");
 power();if(!permit) $fatal(1,"repeat POWER must not cancel motion");
 $display("PASS: tb_safety_arbiter priority and lockouts");$finish;
 end
 initial begin #100000;$fatal(1,"watchdog");end
endmodule
