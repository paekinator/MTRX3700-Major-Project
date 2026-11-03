// Wheel requests use logical forward-positive cm/s. Map motor polarity at UART boundary.
module motion_fsm #(
 parameter int ALIGN_LOW=110, ALIGN_HIGH=130, DOCK_STOP_MM=350,
 parameter int SAFETY_MM=250, FINE_MM=500,
 parameter int TURN_CM_S=4, APPROACH_CM_S=5, FINE_CM_S=3,
 // +1 is the candidate left/right image convention, NOT a hardware calibration.
 parameter int TURN_SIGN=1
)(input logic clk,reset,taskActive,safetyHalt,motionTargetValid,distance_valid,
 input logic [7:0] centreU, input logic [11:0] distance_mm,
 output logic signed [6:0] left_cm_s,right_cm_s,
 output logic [2:0] state);
 localparam logic [2:0] IDLE=0,SEARCH=1,ALIGN=2,APPROACH=3,DOCKED=4,LOST=5;
 wire centred=centreU>=ALIGN_LOW && centreU<=ALIGN_HIGH;
 wire safeRange=distance_valid && distance_mm>SAFETY_MM;
 wire usable=motionTargetValid && safeRange && !safetyHalt;
 localparam int TURN=(TURN_CM_S>=3 && TURN_CM_S<=5 && (TURN_SIGN==1 || TURN_SIGN==-1)) ? TURN_CM_S*TURN_SIGN : 0;
 localparam int DRIVE=(APPROACH_CM_S>=3 && APPROACH_CM_S<=15)?APPROACH_CM_S:0;
 localparam int FINE=(FINE_CM_S>=3 && FINE_CM_S<=15)?FINE_CM_S:0;
 always_ff @(posedge clk) begin
   if(reset || !taskActive) state<=IDLE;
   else if(safetyHalt || !safeRange) state<=LOST;
   else case(state)
     IDLE: state<=SEARCH;
     SEARCH: if(motionTargetValid) state<=ALIGN;
     ALIGN: if(!motionTargetValid) state<=LOST; else if(centred) state<=APPROACH;
     APPROACH: if(!motionTargetValid) state<=LOST;
       else if(!centred) state<=ALIGN;
       else if(distance_mm<=DOCK_STOP_MM) state<=DOCKED;
     DOCKED: state<=DOCKED;
     LOST: if(motionTargetValid) state<=ALIGN;
     default: state<=IDLE;
   endcase
 end
 always_comb begin
   left_cm_s=0;right_cm_s=0;
   if(!reset && taskActive && usable) begin
     if(state==ALIGN) begin
       if(centreU<ALIGN_LOW) begin left_cm_s=7'(-TURN);right_cm_s=7'(TURN);end
       else if(centreU>ALIGN_HIGH) begin left_cm_s=7'(TURN);right_cm_s=7'(-TURN);end
     end else if(state==APPROACH && centred && distance_mm>DOCK_STOP_MM) begin
       left_cm_s=distance_mm<=FINE_MM ? 7'(FINE):7'(DRIVE);
       right_cm_s=left_cm_s;
     end
   end
 end
endmodule
