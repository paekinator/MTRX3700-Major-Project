// Wrap the unchanged teacher driver. One transaction per 100 ms.
module sonar_guard(input logic clk50, reset, input logic echo,
 output wire trig, output logic [11:0] distance_mm,
 output logic distance_valid, output logic sample_pulse);
 wire sc, locked;
 sonar_pll pll(.refclk(clk50),.rst(reset),.outclk_0(sc),.locked(locked));
 logic [1:0] sr=3;
 always_ff @(posedge sc or posedge reset) begin
   if(reset) sr<=3; else sr<={sr[0],!locked};
 end
 wire rst_s=sr[1];
 logic [22:0] phase;
 logic start, driver_reset, pending, sent;
 wire [11:0] raw;
 wire ready, valid;
 logic [1:0] es;
 always_ff @(posedge sc) es<={es[0],echo};
 sonar_range ranger(.clk(sc),.rst(rst_s || driver_reset),.start_measure(start),
 .echo(echo),.trig(trig),.distance(raw),.ready(ready),.valid(valid));
 // Bundled-data mailbox: payload stays fixed until synchronized ACK returns.
 logic [12:0] payload;
 logic req, ack;
 (* async_reg = "true" *) logic [1:0] ack_sync;
 always_ff @(posedge sc) begin
   if(rst_s) begin
     phase<=12; start<=0; driver_reset<=1; pending<=0; sent<=0;
     payload<=0; req<=0; ack_sync<=0;
   end else begin
     ack_sync<={ack_sync[0],ack};
     phase <= phase==4390399 ? 0 : phase+1'b1;
     start <= phase>=4 && phase<12;
     driver_reset <= phase==0;
     if(phase==0) begin pending<=1; sent<=0; end
     // 30 ms watchdog also covers stuck-low, stuck-high and no rising ECHO.
     if(pending && !sent && (valid || phase==1317119) && ack_sync[1]==req) begin
       payload <= {valid && raw>=20 && raw<4000 && !es[1],raw};
       req<=~req; sent<=1; pending<=0;
     end
   end
 end
 (* async_reg = "true" *) logic [1:0] req_sync;
 logic [25:0] age;
 always_ff @(posedge clk50) begin
   if(reset) begin
     req_sync<=0; ack<=0; age<=0; distance_mm<=0;
     distance_valid<=0; sample_pulse<=0;
   end else begin
     req_sync<={req_sync[0],req}; sample_pulse<=0;
     if(req_sync[1]!=ack) begin
       distance_mm<=payload[11:0]; distance_valid<=payload[12];
       ack<=req_sync[1]; age<=0; sample_pulse<=1;
     end else if(age<49999999) age<=age+1'b1;
     else distance_valid<=0;
   end
 end
endmodule
