`timescale 1ns/1ps
module tb_member_c;
 import perception_pkg::*;
 logic clk=0,reset=1,power_frame=0,estop_frame=0;
 always #10 clk=~clk;
 logic [2:0] selection=1;
 logic [31:0] timeUs=1000;
 perceptionStatus_t status;
 targetRequest_t req,held;
 targetReport_t rpt;
 wire qv,rr;logic qr=0,rv=0;
 logic distance_valid=1;logic [11:0] distance_mm=1000;
 wire signed [6:0] l,r;
 wire permit,used,estop,sonar_stop,motionTargetValid;
 wire [2:0] state,reason;
 int frame=0,checks=0;
 member_c_control dut(.clk(clk),.reset(reset),.power_frame(power_frame),.estop_frame(estop_frame),
 .selection(selection),.timeUs(timeUs),.status(status),.targetRequest(req),.targetRequestValid(qv),
 .targetRequestReady(qr),.targetReport(rpt),.targetReportValid(rv),.targetReportReady(rr),
 .distance_valid(distance_valid),.distance_mm(distance_mm),.left_cm_s(l),.right_cm_s(r),
 .permit(permit),.used(used),.estop(estop),.sonar_stop(sonar_stop),.motionTargetValid(motionTargetValid),
 .motionState(state),.stop_reason(reason));
 wire signed [6:0] flipL,flipR;wire [2:0] flipState;
 motion_fsm #(.TURN_SIGN(-1)) flipped(.clk(clk),.reset(reset),.taskActive(dut.taskActive),
 .safetyHalt(estop_frame||estop||sonar_stop),.motionTargetValid(motionTargetValid),
 .distance_valid(distance_valid),.distance_mm(distance_mm),.centreU(dut.centreU),
 .left_cm_s(flipL),.right_cm_s(flipR),.state(flipState));
 task automatic ck(input bit c,input string msg);checks++;if(!c)$fatal(1,"%s",msg);endtask
 task automatic step(input int n=1);repeat(n)begin @(posedge clk);#1;end endtask
 task automatic clear;
 @(negedge clk);reset=1;power_frame=0;estop_frame=0;rv=0;qr=0;selection=1;
 distance_valid=1;distance_mm=1000;status='0;status.perceptionReady=1;status.activeCfgVersion=1;
 step(3);@(negedge clk);reset=0;timeUs+=1000;step(3);
 endtask
 task automatic power;@(negedge clk);power_frame=1;step();@(negedge clk);power_frame=0;step(3);endtask
 task automatic select_target;
 power();ck(qv,"SELECT queued");held=req;
 ck(req.operation==TARGET_SELECT && req.markerType==MARKER_BAY && req.digit==selection,"typed identity");
 step(5);ck(req==held && qv,"request stable while backpressured");
 @(negedge clk);qr=1;step();@(negedge clk);qr=0;step(3);
 ck(!qv && state==1 && !permit,"SEARCH stationary");
 endtask
 task automatic build(input int u);
 timeUs+=1000;frame++;rpt='0;rpt.requestTag=req.requestTag;rpt.frameId=16'(frame);
 rpt.captureStartUs=timeUs-10;rpt.configVersion=status.activeCfgVersion;rpt.markerType=MARKER_BAY;
 rpt.digit=req.digit;rpt.frameGood=1;rpt.observed=1;rpt.locked=1;rpt.targetSelected=1;
 rpt.centreU=8'(u);rpt.quality=200;rpt.reason=REPORT_OK;
 endtask
 task automatic send;
 @(negedge clk);rv=1;step();ck(rr,"report handshake");@(negedge clk);rv=0;step(4);
 endtask
 task automatic report(input int u);build(u);send();endtask
 task automatic stopped(input string why);ck(!permit && l==0 && r==0,why);endtask
 initial begin
 ck($bits(targetRequest_t)==24 && $bits(targetReport_t)==141,"v3 widths");
 for(int digit=0;digit<8;digit++)begin
 clear();selection=3'(digit);power();
 if(digit==0 || digit==7)begin ck(!qv && !dut.taskActive,"invalid selection");stopped("invalid selection cannot move");end
 else begin ck(qv && req.digit==digit,"selection 1..6");held=req;selection=0;power();ck(req==held,"switch and repeat cannot change task");end
 end
 clear();power();held=req;build(120);rv=1;step(4);
 ck(!rr && qv && req==held,"report backpressure before SELECT accepted");stopped("no report before request");
 qr=1;step();qr=0;step(3);rv=0;stopped("old pre-request report rejected");
 clear();select_target();build(120);rpt.locked=0;send();stopped("unlocked rejected");
 report(80);ck(state==2 && l==-4 && r==4,"left ALIGN signs");ck(flipL==4 && flipR==-4,"inverted turn convention");
 report(180);ck(state==2 && l==4 && r==-4,"right ALIGN signs");ck(flipL==-4 && flipR==4,"inverted right convention");
 report(120);ck(state==3 && l==5 && r==5,"centred APPROACH");
 distance_mm=450;#1;ck(l==3 && r==3,"fine approach");distance_mm=1000;
 report(180);ck(state==2 && l==4 && r==-4,"offset returns ALIGN");
 report(120);build(120);rpt.digit=6;send();stopped("wrong digit revokes old location");
 report(120);build(120);rpt.markerType=MARKER_FUNCTION;send();stopped("wrong marker");
 report(120);build(120);rpt.requestTag++;send();stopped("wrong tag");
 report(120);build(120);rpt.configVersion++;send();stopped("wrong config");
 report(120);status.activeCfgVersion++;#1;stopped("config changes immediately revoke");step(2);
 report(120);ck(permit,"new config requires new report and recovers");
 build(120);rpt.ambiguous=1;send();stopped("ambiguity");
 report(120);build(120);rpt.observed=0;send();stopped("lost observation");
 report(120);build(120);rpt.frameGood=0;send();stopped("bad frame");
 report(120);build(120);rpt.targetSelected=0;send();stopped("not selected");
 report(120);build(120);rpt.reason=REPORT_RESOURCE_DROP;send();stopped("report reason");
 report(120);timeUs=rpt.captureStartUs+150001;#1;stopped("150ms capture freshness");step(2);
 ck(state==5,"stale -> LOST");rv=1;step();rv=0;step(3);stopped("replayed stale report");
 report(120);rv=1;step();rv=0;step(3);stopped("duplicate frame rejected");
 report(120);status.perceptionReady=0;#1;stopped("not ready immediate");step();status.perceptionReady=1;step();stopped("no cache revival");
 report(120);status.interactionBusy=1;#1;stopped("interaction blocks motion");step();status.interactionBusy=0;
 for(int bitn=0;bitn<7;bitn++)begin
 report(120);status.faultFlags=16'(1<<bitn);#1;
 if(bitn==FAULT_AUDIO_CAPTURE)ck(permit,"audio-only fault not visual");else stopped("visual/protocol fault");
 step();status.faultFlags=0;step();
 end
 clear();select_target();report(120);distance_mm=350;#1;stopped("350 normal stop immediate");step(2);
 ck(state==4 && !sonar_stop,"DOCKED only normal stop");distance_mm=1000;report(120);stopped("DOCKED latched");
 clear();select_target();report(120);distance_mm=250;#1;stopped("250 emergency");step(3);
 ck(sonar_stop && state!=4,"safety never DOCKED");distance_mm=1000;report(120);power();stopped("sonar lockout");
 clear();select_target();report(120);distance_valid=0;#1;stopped("invalid J3");step(3);ck(sonar_stop,"sonar fault latched");
 clear();select_target();report(120);estop_frame=1;distance_mm=250;#1;stopped("A immediate");step();
 ck(estop && reason==1,"A wins simultaneous sonar");estop_frame=0;distance_mm=1000;power();report(120);stopped("A lockout");
 clear();stopped("KEY0 returns IDLE");ck(state==0 && !estop && !sonar_stop,"reset clears latches");
 // Shared microsecond counter wrap is accepted; future timestamps are not.
 timeUs=32'hffff_ff00;select_target();timeUs=32'hffff_fff0;build(120);send();ck(permit,"time wrap fresh");
 build(120);rpt.captureStartUs=timeUs+1;send();stopped("future timestamp");
 $display("PASS: tb_member_c %0d checks",checks);$finish;
 end
 initial begin #1000000;$fatal(1,"watchdog");end
endmodule
