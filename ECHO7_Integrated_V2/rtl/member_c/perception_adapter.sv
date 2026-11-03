// Public v3 types are copied verbatim from the read-only Member B package.
module perception_adapter #(parameter logic [31:0] MAX_AGE_US=150000)(
 input logic clk, reset, power_frame, cancel,
 input logic [2:0] selection,
 input logic [31:0] timeUs,
 input perception_pkg::perceptionStatus_t status,
 output perception_pkg::targetRequest_t targetRequest,
 output logic targetRequestValid, input logic targetRequestReady,
 input perception_pkg::targetReport_t targetReport,
 input logic targetReportValid, output logic targetReportReady,
 output logic taskActive, startPulse,
 output logic [3:0] selectedDigit,
 output wire [7:0] centreU, output wire motionTargetValid
);
 import perception_pkg::*;
 logic accepted, haveMeasurement, haveSequence;
 logic [15:0] tag, lastFrame, cachedConfig, previousConfig;
 logic [31:0] fenceUs, stamp;
 logic [7:0] cachedU;
 wire healthy=status.perceptionReady && !status.interactionBusy &&
     ((status.faultFlags & ~(16'b1 << FAULT_AUDIO_CAPTURE))==0);
 wire configChange=previousConfig!=status.activeCfgVersion;
 wire [31:0] afterFence=targetReport.captureStartUs-fenceUs;
 wire [31:0] afterLast=targetReport.captureStartUs-stamp;
 wire goodReport=accepted && taskActive && healthy && !configChange && !cancel &&
     targetReport.requestTag==tag && targetReport.markerType==MARKER_BAY &&
     targetReport.digit==selectedDigit && targetReport.configVersion==status.activeCfgVersion &&
     targetReport.frameGood && targetReport.observed && targetReport.locked &&
     targetReport.targetSelected && !targetReport.ambiguous && targetReport.reason==REPORT_OK &&
     targetReport.quality!=0 && targetReport.centreU<240 &&
     freshTime(timeUs,targetReport.captureStartUs,MAX_AGE_US) &&
     afterFence!=0 && !afterFence[31] &&
     (!haveSequence || (newerSequence(targetReport.frameId,lastFrame) && afterLast!=0 && !afterLast[31]));
 assign targetReportReady=!reset && !targetRequestValid;
 wire takeReport=targetReportValid && targetReportReady;
 assign motionTargetValid=!reset && !cancel && taskActive && accepted && healthy && !configChange &&
     (takeReport ? goodReport : (haveMeasurement && cachedConfig==status.activeCfgVersion &&
       freshTime(timeUs,stamp,MAX_AGE_US)));
 assign centreU=takeReport && goodReport ? targetReport.centreU : cachedU;
 always_ff @(posedge clk) begin
   if(reset) begin
     targetRequest<='0;targetRequestValid<=0;taskActive<=0;startPulse<=0;selectedDigit<=0;
     accepted<=0;haveMeasurement<=0;haveSequence<=0;tag<=0;lastFrame<=0;
     cachedConfig<=0;previousConfig<=0;fenceUs<=0;stamp<=0;cachedU<=0;
   end else begin
     startPulse<=0;previousConfig<=status.activeCfgVersion;
     if(targetRequestValid && targetRequestReady) begin
       targetRequestValid<=0;accepted<=1;fenceUs<=timeUs;haveMeasurement<=0;haveSequence<=0;
     end
     if(takeReport) begin
       // Any unusable report revokes the cache, including wrong identity/replays.
       haveMeasurement<=goodReport;
       if(goodReport) begin
         cachedU<=targetReport.centreU;stamp<=targetReport.captureStartUs;
         cachedConfig<=targetReport.configVersion;lastFrame<=targetReport.frameId;haveSequence<=1;
       end
     end
     if(configChange) begin haveMeasurement<=0;haveSequence<=0;fenceUs<=timeUs;end
     if(!healthy || cancel || (!takeReport && !freshTime(timeUs,stamp,MAX_AGE_US))) haveMeasurement<=0;
     if(power_frame && !taskActive && !cancel && selection>=1 && selection<=6) begin
       taskActive<=1;startPulse<=1;selectedDigit<={1'b0,selection};tag<=tag+1'b1;
       targetRequest.operation<=TARGET_SELECT;targetRequest.requestTag<=tag+1'b1;
       targetRequest.markerType<=MARKER_BAY;targetRequest.digit<={1'b0,selection};
       targetRequestValid<=1;accepted<=0;haveMeasurement<=0;haveSequence<=0;fenceUs<=timeUs;
     end
   end
 end
endmodule
