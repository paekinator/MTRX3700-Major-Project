module member_c_control #(parameter int ULTRASONIC_ESTOP_MM=250, TURN_SIGN=1)(
 input logic clk,reset,power_frame,estop_frame,
 input logic [2:0] selection,
 input logic [31:0] timeUs,
 input perception_pkg::perceptionStatus_t status,
 output perception_pkg::targetRequest_t targetRequest,
 output wire targetRequestValid, input logic targetRequestReady,
 input perception_pkg::targetReport_t targetReport,
 input logic targetReportValid, output wire targetReportReady,
 input logic distance_valid,input logic [11:0] distance_mm,
 output wire signed [6:0] left_cm_s,right_cm_s,
 output wire permit,used,estop,sonar_stop,motionTargetValid,
 output wire [2:0] motionState,stop_reason
);
 wire taskActive,startPulse,taskEnabled;
 wire [3:0] selectedDigit;
 wire [7:0] centreU;
 wire signed [6:0] reqL,reqR;
 perception_adapter adapter(.clk(clk),.reset(reset),.power_frame(power_frame),
   .cancel(estop_frame||estop||sonar_stop),.selection(selection),.timeUs(timeUs),.status(status),
   .targetRequest(targetRequest),.targetRequestValid(targetRequestValid),.targetRequestReady(targetRequestReady),
   .targetReport(targetReport),.targetReportValid(targetReportValid),.targetReportReady(targetReportReady),
   .taskActive(taskActive),.startPulse(startPulse),.selectedDigit(selectedDigit),
   .centreU(centreU),.motionTargetValid(motionTargetValid));
 motion_fsm #(.SAFETY_MM(ULTRASONIC_ESTOP_MM),.TURN_SIGN(TURN_SIGN)) motion(
   .clk(clk),.reset(reset),.taskActive(taskActive),
   .safetyHalt(estop_frame||estop||sonar_stop),.motionTargetValid(motionTargetValid),
   .distance_valid(distance_valid),.distance_mm(distance_mm),.centreU(centreU),
   .left_cm_s(reqL),.right_cm_s(reqR),.state(motionState));
 safety_arbiter #(.ULTRASONIC_ESTOP_MM(ULTRASONIC_ESTOP_MM)) safety(
   .clk(clk),.reset(reset),.power_frame(startPulse),.estop_frame(estop_frame),
   .motion_enable((reqL!=0 || reqR!=0)&&motionTargetValid),
   .distance_valid(distance_valid),.distance_mm(distance_mm),.permit(permit),.taskEnabled(taskEnabled),
   .used(used),.estop(estop),.sonar_stop(sonar_stop),.reason(stop_reason));
 assign left_cm_s=permit?reqL:7'sd0;
 assign right_cm_s=permit?reqR:7'sd0;
endmodule
