`timescale 1ns/1ps
// Serial framing/priority regression, accelerated baud only in this unit test.
module tb_uart_stop_priority;
    logic clk=0, reset=1, armed=0;
    always #10 clk=~clk;
    wire tx,busy;
    localparam time BIT_NS=80;
    localparam logic [207:0] STOP="{\"T\":1,\"L\":0.00,\"R\":0.00}\n";
    localparam logic [207:0] MOVE="{\"T\":1,\"L\":0.10,\"R\":0.10}\n";
    chassis_command #(.CLKS_PER_BIT(4),.PERIOD_CLKS(1_000_000)) dut (
        .clk(clk),.reset(reset),.armed(armed),.motion(2'b00),.speed(2'b00),
        .left_cm_s(7'sd0),.right_cm_s(7'sd0),.feedback(1'b0),.tx(tx),.busy(busy));
    task automatic read_line(output logic [207:0] value);
        logic [7:0] ch;
        value=0;
        for(int n=0;n<26;n++) begin
            @(negedge tx); #(BIT_NS/2);
            if(tx!==0) $fatal(1,"start bit");
            for(int b=0;b<8;b++) begin #(BIT_NS);ch[b]=tx;end
            #(BIT_NS);
            if(tx!==1) $fatal(1,"stop bit");
            value={value[199:0],ch};
        end
    endtask
    logic [207:0] value;
    time stop_at;
    initial begin
        #100; @(negedge clk) reset=0;
        read_line(value);
        if(value!==STOP) $fatal(1,"initial stop");
        for(int n=0;n<26;n++) begin
            wait(!busy); @(negedge clk) armed=1;
            fork
                read_line(value);
                begin
                    @(negedge tx);
                    if(n>0) begin
                        wait(dut.remaining==25-n && dut.tx_u.current_state==dut.tx_u.DATA_BITS);
                    end
                    #(BIT_NS*2); armed=0; stop_at=$time;
                end
            join
            if(value!==MOVE) $fatal(1,"motion JSON truncated/mixed at byte %0d",n);
            read_line(value);
            if(value!==STOP) $fatal(1,"next complete JSON must be zero at byte %0d",n);
            if($time-stop_at>50_000) $fatal(1,"stop waited for 20 ms heartbeat");
        end
        $display("PASS: tb_uart_stop_priority all 26 byte positions");
        $finish;
    end
    initial begin #10_000_000; $fatal(1,"priority test watchdog");end
endmodule
