`timescale 1ns/1ps
// ECHO-7 team; AI-assisted. Drive NEC waveforms through the real decoder.
// Synthetic A5 POWER code only; it does not establish the physical remote's code.
module irSafety_tb;
    logic clk=0;always #500 clk=~clk; // 1 MHz, NEC pulse durations remain real.
    logic reset=1,ir=1;wire tx,estop,expired,stopped,seen;
    wire [7:0] lastkey;wire [31:0] lastcode;
    safetySystem #(.POWER_KEY_CONFIGURED(1),.POWER_KEY(8'hA5),.CLK_HZ(1_000_000),
        .HOLD_CLKS(300000),.WATCHDOG_CLKS(500000),.PERIOD_CLKS(200000),.CLKS_PER_BIT(10)) dut(
        .clk(clk),.reset(reset),.ir_rx(ir),.chassis_rx(1'b1),.sonar1_distance_mm(12'd0),.sonar2_distance_mm(12'd199),
        .sonar1_valid(1'b0),.sonar2_valid(1'b1),.sonar1_update(1'b0),.sonar2_update(1'b1),
        .chassis_tx(tx),.estop_latched(estop),.control_expired(expired),.stop_active(stopped),.rx_seen(),
        .last_ir_key(lastkey),.last_ir_code(lastcode),.ir_seen(seen),.stop_reason());
    wire unconfigured_stop;
    safetySystem #(.CLK_HZ(1_000_000),.HOLD_CLKS(300000),.WATCHDOG_CLKS(500000),.PERIOD_CLKS(200000),.CLKS_PER_BIT(10)) unconfigured(
        .clk(clk),.reset(reset),.ir_rx(ir),.chassis_rx(1'b1),.sonar1_distance_mm(12'd300),.sonar2_distance_mm(12'd300),
        .sonar1_valid(1'b1),.sonar2_valid(1'b1),.sonar1_update(1'b0),.sonar2_update(1'b0),
        .chassis_tx(),.estop_latched(),.control_expired(),.stop_active(unconfigured_stop),.rx_seen(),
        .last_ir_key(),.last_ir_code(),.ir_seen(),.stop_reason());
    time decoded_time;time max_event_latency=0;
    always @(posedge clk) if(!reset && dut.code_valid && dut.code[23:16]==8'hA5) decoded_time=$time;
    always @(posedge dut.sender_u.zero_line_started) if(estop) begin
        if($time-decoded_time>max_event_latency)max_event_latency=$time-decoded_time;
    end
    task automatic check(input bit ok,input string what);if(!ok)$fatal(1,"FAIL %s",what);endtask
    task automatic frame(input logic [7:0] key,input bit corrupt=0);
        logic [31:0] word;word={~key,key,16'h00ff};if(corrupt)word[31]=~word[31];
        #20ms;ir=0;#9ms;ir=1;#4500us;
        for(int b=0;b<32;b++)begin ir=0;#562us;ir=1;if(word[b])#1688us;else #563us;end
        ir=0;#562us;ir=1;#20us;
    endtask
    task automatic rpt();#20ms;ir=0;#9ms;ir=1;#2250us;ir=0;#562us;ir=1;#20us;endtask
    task automatic rst();reset=1;#10us;reset=0;#10us;endtask
    initial begin
        rst();check(stopped,"safe boot");frame(8'hA5,1);check(!estop && !seen,"invalid NEC ignored");
        frame(8'h1A);check(seen && lastkey==8'h1A && dut.safe_left==1 && dut.safe_right==1,"CH+ starts with decoded real frame");
        check(unconfigured_stop && unconfigured.safe_left==0,"unconfirmed POWER setting blocks movement");
        rpt();check(dut.safe_left==1,"associated NEC repeat refreshes movement");
        frame(8'hA5);check(estop && stopped && dut.safe_left==0,"full POWER frame locks stop");
        rpt();check(estop,"POWER repeat does not clear");#10ms;check(estop,"release maintains latch");
        frame(8'h1A);check(estop && dut.safe_left==0,"CH ignored during estop");
        frame(8'h1B);check(estop && dut.safe_right==0,"VOL ignored during estop");
        frame(8'hA5);check(estop,"second POWER cannot reset");
        rst();check(!estop && stopped && dut.safe_left==0,"KEY0 safe idle");rpt();check(dut.safe_left==0,"repeat after reset cannot restart");
        frame(8'h1E);check(dut.safe_left== -1 && dut.safe_right== -1,"fresh motion restarts");
        #301ms;check(dut.safe_left==0,"deadman expires before watchdog");rpt();check(dut.safe_left==0,"late repeat cannot restart old motion");
        frame(8'h1F);check(dut.safe_left== -1 && dut.safe_right==1,"VOL direction preserved");
        frame(8'h02);check(dut.safe_left== -2,"speed key accepted while active");
        repeat(4)rpt();#301ms;check(dut.safe_left==0,"speed-key repeats do not renew motion");
        $display("PASS irSafety_tb: full NEC/checksum/repeat -> manual -> latched POWER -> arbiter -> UART; safe configuration, reset and new-command restart");$finish;
    end
    initial begin #3s;$fatal(1,"FAIL IR test timeout");end
endmodule
