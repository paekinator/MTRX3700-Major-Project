`timescale 1ns/1ps
module tb_integrated_link;
 `include "board_fixture.svh"
 assign gpio[29]=1'b0;
 logic [31:0] simTime=10000,necCode=0;
 logic necValid=0,necRepeat=0,rangeValid=1,acceptRequest=1;
 logic [11:0] rangeMm=1000;
 logic [15:0] cfgVersion=0,simFaults=0;
 wire reqReadyStim=acceptRequest&&!dut.reset50;
 targetRequest_t heldRequest;targetReport_t heldReport;
 int prevRequests,startLine,oldMoves;
 task automatic press(input logic [7:0] command);
   tick();necCode={~command,command,16'hff00};necValid=1;tick();necValid=0;tick(12);
 endtask
 task automatic restart(input int digit);
   tick();key[0]=0;sw=10'(digit<<2);observationPulse=0;necValid=0;necRepeat=0;
   simTime+=1000;cfgVersion=0;simFaults=0;rangeMm=1000;rangeValid=1;acceptRequest=1;
   tick(8);key[0]=1;tick(20);
   check(dut.chassis.motionState==0&&!dut.chassis.running&&!dut.chassis.estop,"KEY0 shared reset/IDLE");
 endtask
 task automatic frame_at(input int u,input int matchCountStim=1,input int bad=0);
   simTime+=1000;tick(2);observe(u,matchCountStim,bad);
 endtask
 task automatic lock_target(input int u=120);
   frame_at(u);frame_at(u);frame_at(u);tick(8);
 endtask
 task automatic await_running_json;
   wait(dut.chassis.chassis_u.sentL==-5 && dut.chassis.chassis_u.sentR==-5 &&
        dut.chassis.chassis_u.state==1 && dut.chassis.chassis_u.remaining<23 && dut.chassis.chassis_u.remaining>12);
   startLine=lines;
 endtask
 task automatic check_priority_zero;
   wait(lines>=startLine+2);tick(4);
   check(uartLines[startLine]=="{\"T\":1,\"L\":-0.05,\"R\":-0.05}\n","busy movement JSON completes intact");
   check(uartLines[startLine+1]=="{\"T\":1,\"L\":0.00,\"R\":0.00}\n","immediately following JSON is zero (no 200 ms wait)");
 endtask
 initial begin
   force dut.timeUs=simTime;force dut.chassis.nec_valid=necValid;force dut.chassis.nec_code=necCode;
   force dut.chassis.nec_repeat=necRepeat;
   force dut.chassis.sonar_u.distance_valid=rangeValid;force dut.chassis.sonar_u.distance_mm=rangeMm;
   force dut.core.configVersion=cfgVersion;force dut.core.faults=simFaults;
   force dut.core.tracker.targetRequestReady=reqReadyStim;
   install_observation_fixture();tick(12);
   check($bits(targetRequest_t)==24&&$bits(targetReport_t)==141,"original public v3 packed widths 24/141");
   restart(0);prevRequests=requests;press(8'h12);check(requests==prevRequests&&!dut.chassis.used,"SW000 cannot start");
   restart(7);press(8'h12);check(requests==prevRequests&&!dut.chassis.used,"SW111 cannot start");
   for(int digit=1;digit<=6;digit++)begin
     restart(digit);acceptRequest=0;prevRequests=requests;press(8'h12);
     heldRequest=dut.targetRequest;
     check(dut.requestValid&&heldRequest.operation==TARGET_SELECT&&heldRequest.markerType==MARKER_BAY&&heldRequest.digit==digit,"SW1..6 creates typed TARGET_SELECT");
     sw[4:2]=3'(7-digit);tick(12);
     check(dut.targetRequest===heldRequest&&dut.requestValid&&requests==prevRequests,"request held through backpressure; selection latched");
     frame_at(120);heldReport=dut.targetReport;tick(12);
     check(dut.reportValid&&!dut.reportReady&&dut.targetReport===heldReport,"actual tracker report held under C backpressure");
     acceptRequest=1;tick(16);
     check(requests==prevRequests+1&&dut.core.activeRequest===heldRequest,"request handshakes exactly once into real tracker");
     frame_at(120);check(!dut.chassis.running,"first observed frame not locked");
     frame_at(120);check(!dut.chassis.running,"second observed frame not locked");
     frame_at(120);tick(8);
     check(dut.chassis.running&&dut.chassis.motionState==3&&dut.chassis.motorL==-5&&dut.chassis.motorR==-5,"third locked report permits APPROACH -0.05/-0.05");
     press(8'h12);check(requests==prevRequests+1,"repeated POWER does not replace request/restart");
   end
   frame_at(80);check(dut.chassis.motionState==2&&dut.chassis.motorL==4&&dut.chassis.motorR==-4,"centre80 ALIGN candidate turn signs");
   frame_at(120);check(dut.chassis.motionState==3,"centre120 returns APPROACH");
   frame_at(180);check(dut.chassis.motionState==2&&dut.chassis.motorL==-4&&dut.chassis.motorR==4,"centre180 opposite ALIGN turn");
   frame_at(120);rangeMm=400;tick(8);check(dut.chassis.running&&dut.chassis.motorL==-3,"400 mm fine approach 0.03 m/s");
   rangeMm=350;tick(8);check(dut.chassis.motionState==4&&!dut.chassis.running&&!dut.chassis.sonar_stop,"350 mm is normal DOCKED, not sonar E-STOP");
   rangeMm=1000;press(8'h12);check(dut.chassis.motionState==4&&!dut.chassis.running,"DOCKED does not restart after range rebound/POWER");
   restart(2);press(8'h12);check(dut.chassis.motionState==1&&!dut.chassis.running,"SEARCH stays still without report");
   lock_target();simTime+=150001;tick(8);
   check(!dut.chassis.motionTargetValid&&!dut.chassis.running&&dut.chassis.motionState==5,"capture older than 150 ms clears position and enters LOST");
   lock_target();check(dut.chassis.running,"fresh locked reports recover LOST");
   for(int bad=1;bad<=5;bad++)begin
     frame_at(120,1,bad);check(!dut.chassis.running,"wrong digit/type/tag/config or frameGood revokes movement");
     lock_target();check(dut.chassis.running,"recover only from fresh matching locked sequence");
   end
   frame_at(120,2);check(!dut.chassis.running,"ambiguous real tracker report stops");
   lock_target();frame_at(120,0);check(!dut.chassis.running,"target lost stops");lock_target();
   cfgVersion=1;tick(8);check(!dut.chassis.running,"status config version change invalidates cache");
   lock_target();check(dut.chassis.running,"new configuration confirmed after fresh captures");
   simFaults=16'b1;tick(8);check(!dut.chassis.running,"camera transport fault blocks motion");simFaults=0;lock_target();
   sw[0]=1;sw[1]=1;sw[8]=1;tick(20);
   check(dut.switchSync==3&&dut.bypassSync&&dut.overlay.showCandidates&&dut.overlay.showCentre,"SW0/1 overlay and SW8 perspective wiring retained");
   sw[9]=1;tick(12);check(!dut.core.processingEnable&&!dut.status.perceptionReady&&!dut.chassis.running,"SW9 pure-camera mode blocks perception motion");
   sw[9]=0;tick(12);lock_target();check(dut.chassis.running,"SW9 release requires fresh reports");
   // Existing JTAG interface must explicitly reject competing target commands.
   dut.debugControl.probes.src_jtag=32'h81000012;tick(20);
   check(dut.debugControl.commandError&&dut.debugControl.rejectionReason==2&&!dut.commandValid,"JTAG SELECT rejected, no second request master");
   // Check the real UART wire, with no artificial baud acceleration.
   await_running_json();rangeMm=250;tick(8);
   check(!dut.chassis.running&&dut.chassis.sonar_stop&&dut.chassis.stop_reason==2&&dut.chassis.motionState!=4,"250 mm safety stop cannot masquerade as DOCKED");
   check_priority_zero();rangeMm=1000;press(8'h12);check(!dut.chassis.running,"latched sonar stop cannot be released by POWER");
   restart(1);press(8'h12);lock_target();await_running_json();
   rangeValid=0;tick(8);check(dut.chassis.sonar_stop&&!dut.chassis.running,"invalid J3 data cancels movement");check_priority_zero();
   restart(1);press(8'h12);lock_target();await_running_json();
   tick();rangeMm=250;necCode=32'hf00fff00;necValid=1;tick();necValid=0;tick(8);
   check(dut.chassis.estop&&dut.chassis.stop_reason==1&&!dut.chassis.running,"simultaneous A and sonar stop: A priority");check_priority_zero();
   press(8'h12);necRepeat=1;tick();necRepeat=0;tick(8);check(dut.chassis.estop&&!dut.chassis.running,"POWER/repeat cannot clear A latch");
   restart(1);press(8'h12);lock_target();await_running_json();key[0]=0;rangeValid=0;tick(8);
   check(!dut.chassis.running&&dut.core.reset&&dut.chassis.reset50,"KEY0 simultaneously resets B/C; UART frame preserved");check_priority_zero();
   key[0]=1;tick(20);check(!dut.chassis.used&&!dut.chassis.running&&!dut.chassis.distance_valid,"KEY0 release has no automatic start without new distance/POWER");
   $display("PASS: tb_integrated_link checks=%0d requests=%0d reports=%0d UART_lines=%0d",checks,requests,reports,lines);$finish;
 end
 initial begin #100000000;$fatal(1,"integration watchdog");end
endmodule
