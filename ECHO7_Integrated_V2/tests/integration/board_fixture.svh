
 import perception_pkg::*;
 logic clk=0,pclk=0;always #10 clk=~clk;always #25 pclk=~pclk;
 logic [3:0] key=4'b1110;logic [9:0] sw=0;logic ir=1;
 tri [35:0] gpio;wire [9:0] led;wire [6:0] h0,h1,h2,h3,h4,h5;
 wire vc,vh,vv,vb,vs;wire [7:0] red,green,blue;
 assign gpio[21]=pclk;assign gpio[22]=1'b0;assign gpio[23]=1'b0;
 assign gpio[19:12]=8'd0;assign gpio[33]=1'b1;pullup(gpio[24]);
 echo7IntegratedTop dut(.CLOCK_50(clk),.KEY(key),.SW(sw),.IRDA_RXD(ir),.GPIO_1(gpio),
 .LEDR(led),.HEX0(h0),.HEX1(h1),.HEX2(h2),.HEX3(h3),.HEX4(h4),.HEX5(h5),
 .VGA_CLK(vc),.VGA_HS(vh),.VGA_VS(vv),.VGA_BLANK_N(vb),.VGA_SYNC_N(vs),.VGA_R(red),.VGA_G(green),.VGA_B(blue));
 defparam dut.chassis.KEY_DEBOUNCE_CLKS=8;
 // No acceleration of UART baud, NEC timing or sonar measurement clock.
 int checks=0,requests=0,reports=0,lines=0,moveLines=0,stopLines=0;
 string uartLines[0:2047];string uartLine="";logic [7:0] uartByte;
 initial forever begin
   @(negedge gpio[31]);#4340;if(gpio[31]!==0)$fatal(1,"UART start bit");
   for(int b=0;b<8;b++)begin #8680;uartByte[b]=gpio[31];end
   #8680;if(gpio[31]!==1)$fatal(1,"UART stop bit");
   uartLine={uartLine,uartByte};
   if(uartByte==10)begin
     if(uartLine=="{\"T\":1,\"L\":0.00,\"R\":0.00}\n")stopLines++;
     else if(uartLine=="{\"T\":1,\"L\":-0.05,\"R\":-0.05}\n" ||
             uartLine=="{\"T\":1,\"L\":-0.03,\"R\":-0.03}\n" ||
             uartLine=="{\"T\":1,\"L\":0.04,\"R\":-0.04}\n" ||
             uartLine=="{\"T\":1,\"L\":-0.04,\"R\":0.04}\n")moveLines++;
     else $fatal(1,"Corrupt or unexpected UART JSON: %s",uartLine);
     uartLines[lines]=uartLine;lines++;uartLine="";
   end
 end
 task automatic tick(input int n=1);repeat(n)@(negedge clk);endtask
 task automatic check(input bit ok,input string why);
   if(!ok)$fatal(1,"CHECK %0d: %s at %0t state=%0d U=%0d valid=%0b reason=%0d",checks,why,$time,
     dut.chassis.motionState,dut.chassis.control_u.centreU,dut.chassis.motionTargetValid,dut.chassis.stop_reason);
   checks++;$display("OK %0d: %s",checks,why);
 endtask
 // Live public-interface endpoint equality checks, not duplicated wiring in the TB.
 always @(posedge clk) if(!dut.reset50)begin
   if(dut.core.clk!==dut.chassis.CLOCK_50 || dut.core.reset!==dut.chassis.reset50 ||
      dut.core.timeUs!==dut.chassis.timeUs)$fatal(1,"B/C clock, reset or shared time mismatch");
   if(dut.core.targetRequest!==dut.chassis.targetRequest ||
      dut.core.targetRequestValid!==dut.chassis.targetRequestValid ||
      dut.core.targetRequestReady!==dut.chassis.targetRequestReady ||
      dut.core.targetReport!==dut.chassis.targetReport ||
      dut.core.targetReportValid!==dut.chassis.targetReportValid ||
      dut.core.targetReportReady!==dut.chassis.targetReportReady)$fatal(1,"Public v3 connection mismatch");
   if(dut.requestValid&&dut.requestReady)requests++;
   if(dut.reportValid&&dut.reportReady)reports++;
   if(dut.chassis.running && (!dut.chassis.distance_valid || dut.chassis.distance_mm<=250 ||
      dut.chassis.estop || dut.chassis.sonar_stop || !dut.chassis.motionTargetValid))$fatal(1,"Safety bypass");
   if($isunknown({gpio[31],gpio[27],led}))$fatal(1,"Unknown/multiple-driven physical output");
 end
 // Fixture boundary: completed camera observations, NOT the public B/C link.
 // The production targetTracker creates every 141-bit report itself.
 frameObservation_t observationStim;
 logic observationPulse=0;
 int frameNumber=0;
 task automatic observe(input int u,input int matchCountStim=1,input int bad=0);
   @(negedge clk);
   observationStim='0;observationStim.boundRequest=dut.core.activeRequest;
   if(bad==1)observationStim.boundRequest.digit=observationStim.boundRequest.digit==6?1:6;
   if(bad==2)observationStim.boundRequest.markerType=MARKER_FUNCTION;
   if(bad==3)observationStim.boundRequest.requestTag++;
   observationStim.frameId=16'(++frameNumber);
   observationStim.captureStartUs=dut.timeUs-1;
   observationStim.configVersion=dut.core.configVersion;
   if(bad==4)observationStim.configVersion++;
   observationStim.frameGood=bad!=5;observationStim.matchCount=5'(matchCountStim);
   observationStim.xMin=100;observationStim.xMax=140;
   observationStim.yMin=8'(u-4);observationStim.yMax=8'(u+4);observationStim.quality=200;
   observationPulse=1;tick();observationPulse=0;tick(8);
 endtask
 task automatic install_observation_fixture;
   force dut.core.observation=observationStim;
   force dut.core.observationValid=observationPulse;
   // Emulate a healthy completed pipeline, while keeping real status generation,
   // SW9 processing gate, targetTracker and adapter intact.
   force dut.core.haveFrame=1'b1;
   force dut.core.activeProcessing=1'b1;
   force dut.core.lastCompletionUs=dut.timeUs;
 endtask
 task automatic nec_frame(input logic [31:0] code);
   ir=0;#9000000;ir=1;#4500000;
   for(int b=0;b<32;b++)begin ir=0;#562500;ir=1;if(code[b])#1687500;else #562500;end
   ir=0;#562500;ir=1;#1000;
 endtask
 task automatic nec_repeat_frame;
   ir=0;#9000000;ir=1;#2250000;ir=0;#562500;ir=1;#1000;
 endtask
