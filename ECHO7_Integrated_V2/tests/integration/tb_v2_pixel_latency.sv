`timescale 1ns/1ps
// Actual latest B pixel pipeline + unchanged C, no observation/status injection.
// Six repeated synthetic full-page RGB565 frames: normal then bounding-box bypass.
// This samples latency; it is not a worst-case bound or live-camera validation.
module tb_v2_pixel_latency;
 import perception_pkg::*;
 logic clk=0,pclk=0,reset=1,resetPclk=1;always #10 clk=~clk;
 initial begin #7;forever #25 pclk=~pclk;end
 logic cameraFrameStart=0,cameraPixelValid=0;logic [15:0] cameraPixel=0;
 logic [9:0] cameraX=0;logic [8:0] cameraY=0;
 logic [31:0] timeUs=0;int divUs=0;
 always @(posedge clk)if(reset)begin divUs<=0;timeUs<=0;end
 else if(divUs==49)begin divUs<=0;timeUs<=timeUs+1'b1;end else divUs<=divUs+1;
 logic interactionEnable=1,interactionPermit=1,debugCalArm=0,debugSpeechArm=0;
 logic [1:0] orientationProfile=0;logic bypassPerspective=0,processingEnable=1;
 wire debugInteractionArmReady;
 targetRequest_t targetRequest;wire targetRequestValid,targetRequestReady;
 targetReport_t targetReport,lastReport;wire targetReportValid,targetReportReady;
 queryResult_t queryResult;wire queryResultValid,queryBusy;logic queryResultReady=1;
 userEvent_t userEvent;wire userEventValid;logic userEventReady=1;
 perceptionStatus_t status;wire [DEBUG_WORD_COUNT*32-1:0] debugWords;
 wire completedFrame;wire [15:0] completedFrameId;
 perceptionCore dut(.*);
 logic power_frame=0;wire signed [6:0] l,r;wire permit,used,estop,sonarStop,motionTargetValid;
 wire [2:0] motionState,reason;
 member_c_control c(.clk(clk),.reset(reset),.power_frame(power_frame),.estop_frame(1'b0),
 .selection(3'd1),.timeUs(timeUs),.status(status),.targetRequest(targetRequest),
 .targetRequestValid(targetRequestValid),.targetRequestReady(targetRequestReady),
 .targetReport(targetReport),.targetReportValid(targetReportValid),.targetReportReady(targetReportReady),
 .distance_valid(1'b1),.distance_mm(12'd1000),.left_cm_s(l),.right_cm_s(r),.permit(permit),
 .used(used),.estop(estop),.sonar_stop(sonarStop),.motionTargetValid(motionTargetValid),
 .motionState(motionState),.stop_reason(reason));
 logic [15:0] pixels[0:76799];int reportCount=0,maximumAge=0,normalMax=0,bypassMax=0;
 int currentFrame=0,oldReports,normalLocked=0,bypassLocked=0;time sofTime;
 always @(posedge clk)if(!reset&&targetReportValid&&targetReportReady)begin
   int age;age=timeUs-targetReport.captureStartUs;lastReport=targetReport;reportCount++;
   if(age>maximumAge)maximumAge=age;
   if(bypassPerspective)begin if(age>bypassMax)bypassMax=age;if(targetReport.locked)bypassLocked++;end
   else begin if(age>normalMax)normalMax=age;if(targetReport.locked)normalLocked++;end
   if(age>150000 || !targetReport.frameGood || !targetReport.observed || targetReport.ambiguous ||
      targetReport.markerType!=MARKER_BAY || targetReport.digit!=1 || targetReport.requestTag!=1)
      $fatal(1,"Invalid/late pixel report id=%0d age=%0d good=%0b observed=%0b reason=%0d faults=%h",
         targetReport.frameId,age,targetReport.frameGood,targetReport.observed,targetReport.reason,status.faultFlags);
   $display("PIXEL_REPORT frame=%0d bypass=%0b age_us=%0d locked=%0b centreU=%0d interactionBusy=%0b",
       targetReport.frameId,bypassPerspective,age,targetReport.locked,targetReport.centreU,status.interactionBusy);
 end
 task automatic frame;
   oldReports=reportCount;currentFrame++;
   @(negedge pclk);cameraFrameStart=1;sofTime=$time;
   @(negedge pclk);cameraFrameStart=0;repeat(8)@(negedge pclk);
   for(int py=0;py<240;py++)begin
     for(int px=0;px<320;px++)begin
       cameraX=10'(px*2);cameraY=9'(py*2);cameraPixel=pixels[py*320+px];cameraPixelValid=1;
       @(negedge pclk);cameraPixelValid=0;repeat(3)@(negedge pclk);
     end
     repeat(150)@(negedge pclk);
   end
   // No recognition-dependent slowing of a 25 fps source.
   while($time-sofTime<40000000)@(negedge pclk);

 endtask
 task automatic drain(input int wanted);
   int started;started=timeUs;
   while(reportCount<wanted && timeUs-started<150000)@(negedge clk);
   if(reportCount!=wanted||lastReport.frameId!=wanted)$fatal(1,"Missing/reordered pixel report after bounded drain");
 endtask
 initial begin
   $readmemh("../tests/vectors/sheet_320x240_rgb565.hex",pixels);
   repeat(10)@(negedge clk);reset=0;resetPclk=0;
   if($bits(targetRequest_t)!=24||$bits(targetReport_t)!=141||$bits(perceptionStatus_t)!=76)$fatal(1,"public v3 widths");
   repeat(10)@(negedge clk);power_frame=1;@(negedge clk);power_frame=0;
   wait(!targetRequestValid);repeat(30)@(negedge pclk);
   repeat(3)frame();drain(3);
   if(!lastReport.locked||normalLocked!=1)$fatal(1,"normal-mode three-frame lock");
   bypassPerspective=1;repeat(3)frame();drain(6);
   if(!lastReport.locked||bypassLocked!=1||status.faultFlags!=0)$fatal(1,"bypass relock/config fault");
   $display("PASS: tb_v2_pixel_latency reports=%0d normal_max_us=%0d bypass_max_us=%0d limit_us=150000",reportCount,normalMax,bypassMax);
   $finish;
 end
 initial begin #500000000;$fatal(1,"pixel replay watchdog");end
endmodule
