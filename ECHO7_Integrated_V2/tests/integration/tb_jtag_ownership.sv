`timescale 1ns/1ps
module tb_jtag_ownership;
 import perception_pkg::*;
 logic clk=0,reset=1;always #10 clk=~clk;
 logic [DEBUG_WORD_COUNT*32-1:0] debugWords='0;
 wire commandValid;logic commandReady=1;
 targetOperation_t commandOperation;markerType_t commandMarkerType;wire [3:0] commandDigit;
 queryResult_t queryResult='0;logic queryResultValid=0,queryBusy=0;wire queryResultReady;
 wire calibrateArm,speechArm,autoCycle;logic interactionArmReady=1;wire [1:0] orientationProfile;
 memberBDebug #(.ALLOW_TARGET_COMMANDS(0)) dut(.*);
 bit toggle=0;int checks=0,calPulses=0,speechPulses=0;
 always @(posedge clk)if(!reset)begin
   if(commandValid)$fatal(1,"Competing JTAG target command escaped");
   if(calibrateArm)calPulses++;if(speechArm)speechPulses++;
 end
 task automatic issue(input int opcode,input int value=0,input bit reject=0);
   toggle=!toggle;dut.probes.src_jtag={toggle,3'd0,4'(opcode),18'd0,6'(value)};
   repeat(20)@(negedge clk);
   if(dut.ackToggle!==toggle || dut.commandError!==reject ||
      (reject && dut.rejectionReason!=2))$fatal(1,"JTAG opcode %0d acknowledgement/rejection",opcode);
   checks++;
 endtask
 initial begin
   repeat(5)@(negedge clk);reset=0;repeat(12)@(negedge clk);
   issue(1,6'h12,1);issue(2,0,1);issue(7,1,1);issue(8,0,1);issue(9,6'h12,1);
   issue(3);issue(4);issue(6,2);issue(5);
   if(calPulses!=1||speechPulses!=1||orientationProfile!=2||autoCycle)$fatal(1,"Unrelated visual debug controls changed");
   $display("PASS: tb_jtag_ownership %0d commands: sole C owner, visual debug retained",checks);$finish;
 end
endmodule
