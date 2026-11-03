`timescale 1ns/1ps
module tb_wheel_uart;
 logic clk=0,reset=1,armed=0;
 logic signed [6:0] l=0,r=0;
 wire tx,busy;
 always #10 clk=~clk;
 localparam time BIT_NS=80;
 chassis_command #(.CLKS_PER_BIT(4),.PERIOD_CLKS(10000),.USE_WHEEL_REQUESTS(1)) dut(
 .clk(clk),.reset(reset),.armed(armed),.motion(2'b00),.speed(2'b00),.feedback(1'b0),
 .left_cm_s(l),.right_cm_s(r),.tx(tx),.busy(busy));
 string line;
 task automatic read_line;
 logic [7:0] ch;line="";
 for(int n=0;n<29;n++)begin
 @(negedge tx);#(BIT_NS/2);if(tx!==0)$fatal(1,"start");
 for(int b=0;b<8;b++)begin #(BIT_NS);ch[b]=tx;end
 #(BIT_NS);if(tx!==1)$fatal(1,"stop bit");
 line={line,ch};if(ch==10)return;
 end
 $fatal(1,"missing LF");
 endtask
 task automatic expect_line(input string expected);read_line();if(line!=expected)$fatal(1,"JSON got '%s' expected '%s'",line,expected);endtask
 time stopped;
 initial begin
 #100;@(negedge clk);reset=0;
 expect_line("{\"T\":1,\"L\":0.00,\"R\":0.00}\n");
 for(int n=0;n<28;n++)begin
 wait(!busy);@(negedge clk);l=-5;r=-5;armed=1;
 fork
 expect_line("{\"T\":1,\"L\":-0.05,\"R\":-0.05}\n");
 begin
 @(negedge tx);
 if(n>0)wait(dut.remaining==27-n && dut.tx_u.current_state==dut.tx_u.DATA_BITS);
 #(BIT_NS*2);armed=0;stopped=$time;
 end
 join
 expect_line("{\"T\":1,\"L\":0.00,\"R\":0.00}\n");
 if($time-stopped>50000)$fatal(1,"stop delayed by heartbeat");
 end
 wait(!busy);@(negedge clk);l=4;r=-4;armed=1;
 expect_line("{\"T\":1,\"L\":0.04,\"R\":-0.04}\n");
 wait(!busy);@(negedge clk);l=-4;r=4;
 expect_line("{\"T\":1,\"L\":-0.04,\"R\":0.04}\n");
 wait(!busy);@(negedge clk);l=3;r=5;
 expect_line("{\"T\":1,\"L\":0.03,\"R\":0.05}\n");
 wait(!busy);@(negedge clk);l=15;r=-15;
 expect_line("{\"T\":1,\"L\":0.15,\"R\":-0.15}\n");
 wait(!busy);@(negedge clk);l=16;r=5;
 expect_line("{\"T\":1,\"L\":0.00,\"R\":0.00}\n");
 $display("PASS: tb_wheel_uart signed speeds, clamp, all 28 busy byte positions");$finish;
 end
 initial begin #10000000;$fatal(1,"watchdog");end
endmodule
