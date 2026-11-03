`timescale 1ns/1ps
module tb_integrated_pins;
 `include "board_fixture.svh"
 wire echo;int wall=1000,measurements,errors,notes,lastEcho,initialErrors;
 assign gpio[29]=echo;
 hcsr04_model #(.VERBOSE(0)) sensor(.trig(gpio[27]),.echo(echo),.distance_mm(wall),.object_present(1'b1),
 .measurements(measurements),.errors(errors),.notes(notes),.last_echo_us(lastEcho));
 int stoppedBefore;
 initial begin
   sw[4:2]=3'd3;tick(12);initialErrors=errors;key[0]=1;tick(20);
   check(dut.chassis.motionState==0&&!dut.chassis.distance_valid&&!dut.chassis.running,"power-up stops before valid J3 sample");
   // Skip only the initial idle wait, not pulse width, ECHO timing, CDC or subsequent 100 ms cadence.
   force dut.chassis.sonar_u.phase=23'd4390395;
   @(negedge dut.chassis.sonar_u.sc);release dut.chassis.sonar_u.phase;
   wait(dut.chassis.distance_valid);tick(4);
   check(dut.chassis.distance_mm>=998&&dut.chassis.distance_mm<=1001&&led[2],"physical GPIO27/29 -> teacher driver -> CDC: 1000 mm");
   install_observation_fixture();nec_frame(32'hed12ff00);tick(12);
   check(requests==1&&dut.core.activeRequest.digit==3&&dut.core.activeRequest.markerType==MARKER_BAY,"physical IR POWER selects SW blue3 through real request link");
   check(dut.chassis.motionState==1&&!dut.chassis.running,"POWER only starts SEARCH");
   check(dut.chassis.last_code==32'hed12ff00,"original NEC 32-bit capture retained");
   key[1]=0;tick(20);key[1]=1;tick(20);
   check(h5==7'h09&&h3==7'h06&&h2==7'h21&&h1==7'h79&&h0==7'h24,"KEY1 HEX H-ED12 retained");
   observe(120);#10000;observe(120);#10000;observe(120);tick(10);
   check(dut.chassis.running&&dut.chassis.motionState==3,"real tracker locks third report; actual board starts APPROACH");
   wait(moveLines>0);check(moveLines>0,"GPIO31 emits complete 115200-baud negative-forward 0.05 JSON");
   wall=250;stoppedBefore=stopLines;
   wait(dut.chassis.sonar_stop);tick(8);
   check(!dut.chassis.running&&led[4]&&!led[3],"physical J3 250 mm stops safely, not DOCKED");
   wait(stopLines>stoppedBefore);check(stopLines>stoppedBefore,"real J3 safety causes zero JSON on actual UART pin");
   #1000000;nec_frame(32'hf00fff00);tick(8);
   check(dut.chassis.estop&&led[1]&&dut.chassis.stop_reason==1,"physical IR A latches higher-priority E-STOP");
   #2000000;nec_repeat_frame();tick(8);
   check(dut.chassis.estop&&!dut.chassis.running&&requests==1,"physical repeat cannot restart or clear A");
   key[0]=0;tick(10);key[0]=1;tick(20);
   check(!dut.chassis.estop&&!dut.chassis.used&&!dut.chassis.distance_valid&&!dut.chassis.running,"physical KEY0 clears latches and waits for new sensor/POWER");
   check(errors==initialErrors&&measurements>=2,"sensor model: no runtime trigger errors; two physical distance measurements");
   $display("PASS: tb_integrated_pins checks=%0d sensor_measurements=%0d UART_lines=%0d initial_model_events=%0d",checks,measurements,lines,initialErrors);$finish;
 end
 initial begin #400000000;$fatal(1,"physical integration watchdog");end
endmodule
