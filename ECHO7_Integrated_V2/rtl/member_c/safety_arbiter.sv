module safety_arbiter #(parameter int ULTRASONIC_ESTOP_MM=250)(
 input logic clk, reset, power_frame, estop_frame, motion_enable,
 input logic distance_valid, input logic [11:0] distance_mm,
 output wire permit, taskEnabled, output logic used, estop, sonar_stop,
 output logic [2:0] reason);
 logic running;
 wire hazard=!distance_valid || distance_mm<=ULTRASONIC_ESTOP_MM;
 assign taskEnabled=running;
 assign permit=motion_enable && running && !reset && !estop_frame && !estop && !sonar_stop && !hazard;
 always_comb begin
   if(estop || estop_frame) reason=1;
   else if(sonar_stop || hazard) reason=2;
   else reason=0;
 end
 always_ff @(posedge clk) begin
   if(reset) begin running<=0;used<=0;estop<=0;sonar_stop<=0;end
   else if(estop_frame) begin estop<=1;running<=0;used<=1;end
   else if(distance_valid && distance_mm<=ULTRASONIC_ESTOP_MM || running && !distance_valid) begin
     sonar_stop<=1;running<=0;used<=1;
   end else if(power_frame && !used && !estop && !sonar_stop) begin
     // Consume even an unsafe POWER; recovery never starts the wheels later.
     used<=1;
     if(!hazard) begin running<=1;end
     else sonar_stop<=1;
   end
 end
endmodule
