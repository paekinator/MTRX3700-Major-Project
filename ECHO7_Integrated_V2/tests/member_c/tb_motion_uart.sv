`timescale 1ns/1ps
module tb_motion_uart;
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
 wire tx,busy;
 chassis_command #(.USE_WHEEL_REQUESTS(1),.CLKS_PER_BIT(4),.PERIOD_CLKS(10000)) sender(
 .clk(clk),.reset(reset),.armed(permit),.left_cm_s(-l),.right_cm_s(-r),
 .motion(2'b00),.speed(2'b00),.feedback(1'b0),.tx(tx),.busy(busy));
 string line;
 task automatic read_line;
 logic [7:0] ch;line="";
 for(int n=0;n<29;n++)begin
 @(negedge tx);#40;
 for(int b=0;b<8;b++)begin #80;ch[b]=tx;end
 #80;if(tx!==1)$fatal(1,"stop bit");line={line,ch};if(ch==10)return;
 end
 $fatal(1,"missing LF");
 endtask
 task automatic zero_next;
 read_line();ck(line=="{\"T\":1,\"L\":0.00,\"R\":0.00}\n","zero must follow old complete JSON");
 endtask
 initial begin
 for(int scenario=0;scenario<5;scenario++)begin
 clear();select_target();report(120);
 // Skip any startup zero still in flight, then intercept the next MOVE.
 wait(!busy); // movement may be queued immediately; UART reader waits for its start
 fork
 begin read_line();ck(line=="{\"T\":1,\"L\":-0.05,\"R\":-0.05}\n","old movement remains intact");end
 begin
 @(negedge tx);#1000;
 case(scenario)
 0:timeUs=rpt.captureStartUs+150001;
 1:begin build(120);rpt.digit=6;send();end
 2:distance_valid=0;
 3:estop_frame=1;
 4:distance_mm=350;
 endcase
 #1;stopped("hazard immediately clears wheel requests");
 end
 join
 zero_next();zero_next();
 ck(scenario!=4 || state==4,"normal DOCKED");
 end
 $display("PASS: tb_motion_uart stale/wrong target/sonar/A/docking zero priority");$finish;
 end
 initial begin #5000000;$fatal(1,"watchdog");end
endmodule
