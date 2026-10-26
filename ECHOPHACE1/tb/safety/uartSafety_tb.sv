`timescale 1ns/1ps
// ECHO-7 team; AI-assisted. Decode actual wire bits; no dependency on DUT message builder.
module uartSafety_tb;
    localparam int CPB=434,PERIOD=140000;
    logic clk=0;always #10 clk=~clk;
    logic reset=1,stop=1,power_event=0;logic signed [3:0] l=0,r=0;
    wire estop;wire signed [3:0] sl,sr;wire arbitration_stop;
    irEmergencyStop emergency_u(.clk(clk),.reset(reset),.code_valid(power_event),.code(32'h5AA500ff),
        .power_configured(1'b1),.power_key(8'hA5),.estop_latched(estop));
    motorSafetyArbiter arbiter_u(.reset(reset),.estop_latched(estop),.control_expired(1'b0),.critical_fault(stop),
        .sonar_blocked(1'b0),.dock_complete(1'b0),.requested_left(l),.requested_right(r),
        .safe_left(sl),.safe_right(sr),.stop_active(arbitration_stop),.stop_reason());
    wire tx,busy,zero_start,done;
    safeChassisCommand #(.CLKS_PER_BIT(CPB),.PERIOD_CLKS(PERIOD)) dut(.clk(clk),.reset(reset),.stop_active(arbitration_stop),
        .safe_left(sl),.safe_right(sr),.tx(tx),.busy(busy),.zero_line_started(zero_start),.line_done(done));
    string lines[$];time starts[$];string current="";time current_start;
    logic [7:0] byte_value;
    initial forever begin
        @(negedge tx);
        if(current.len()==0) current_start=$time;
        #(CPB*20/2);if(tx!==0)$fatal(1,"FAIL UART start");
        for(int b=0;b<8;b++)begin #(CPB*20);byte_value[b]=tx;end
        #(CPB*20);if(tx!==1)$fatal(1,"FAIL UART stop");
        current={current,byte_value};
        if(byte_value==10)begin lines.push_back(current);starts.push_back(current_start);current="";end
    end
    task automatic check(input bit ok,input string what);if(!ok)$fatal(1,"FAIL %s",what);endtask
    task automatic tick(input int n=1);repeat(n)@(negedge clk);endtask
    task automatic next_line(input int previous);wait(lines.size()>previous);tick();endtask
    time event_time,latency,max_latency=0,max_wire_start=0,max_wire_complete=0;int before_count,n;
    initial begin
        tick(5);reset=0;wait(lines.size()>=1);check(lines[0]=="{\"T\":1,\"L\":0.0,\"R\":0.0}\n","boot stop JSON");
        // Sweep each byte of the longest nonzero line, including near its first start bit.
        for(int offset=0;offset<26;offset++) begin
            stop=0;l=-5;r=-5;
            wait(dut.remaining==26);tick(offset*(10*CPB+1)+1);
            before_count=lines.size();event_time=$time;power_event=1;tick();power_event=0;
            wait(zero_start);latency=$time-event_time;if(latency>max_latency)max_latency=latency;
            check(latency<=((26*(10*CPB+1)+8)*20),"bounded priority zero launch");
            wait(lines.size()>=before_count+2);tick();
            check(lines[before_count]=="{\"T\":1,\"L\":-0.5,\"R\":-0.5}\n","in-flight nonzero frame finishes intact");
            check(lines[before_count+1]=="{\"T\":1,\"L\":0.0,\"R\":0.0}\n","next complete frame is zero");
            if(starts[before_count+1]-event_time>max_wire_start)max_wire_start=starts[before_count+1]-event_time;
            // The byte monitor samples the last stop bit at its midpoint. Also wait for
            // the transmitter to finish the ENTIRE final stop bit before timing completion.
            wait(done);
            if($time-event_time>max_wire_complete)max_wire_complete=$time-event_time;
            check(starts[before_count+1]-event_time<=((26*(10*CPB+1)+10)*20),"wire zero start bound");
            check($time-event_time<=((50*(10*CPB+1)+10)*20),"zero newline delivered bound");
            wait(!busy);stop=1;l=0;r=0;reset=1;tick(2);reset=0;tick(2);
        end
        // Both spin directions, forward and stop formatting.
        wait(!busy && !dut.pending_stop);tick(2);
        stop=0;l=-2;r=3;n=lines.size();next_line(n);check(lines[n]=="{\"T\":1,\"L\":-0.2,\"R\":0.3}\n","independent signed wheel values");
        wait(!busy);l=1;r=-1;n=lines.size();next_line(n);check(lines[n]=="{\"T\":1,\"L\":0.1,\"R\":-0.1}\n","other signed direction");
        wait(!busy);l=2;r=2;wait(dut.remaining==24);tick(500);n=lines.size();reset=1;stop=1;l=0;r=0;
        wait(lines.size()>=n+2);check(lines[n]=="{\"T\":1,\"L\":0.2,\"R\":0.2}\n","KEY0 does not truncate in-flight JSON");
        check(lines[n+1]=="{\"T\":1,\"L\":0.0,\"R\":0.0}\n","KEY0 prioritizes zero");reset=0;
        n=lines.size();wait(lines.size()>=n+2);check(lines[n+1]=="{\"T\":1,\"L\":0.0,\"R\":0.0}\n","stop heartbeat persists");
        $display("PASS uartSafety_tb: 26 stop phases, JSON/8N1, KEY0 in-flight, priority stop and persistent heartbeat; max decoded-event to zero-load/start/complete-stop-bit ns = %0d / %0d / %0d",max_latency,max_wire_start,max_wire_complete);$finish;
    end
    initial begin #500ms;$fatal(1,"FAIL UART test timeout");end
endmodule
