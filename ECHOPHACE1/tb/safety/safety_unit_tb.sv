`timescale 1ns/1ps
// ECHO-7 team; AI-assisted self-checks. Synthetic POWER A5 is a test fixture only.
module safety_unit_tb;
    logic clk=0; always #5 clk=~clk;
    logic reset=1,ev=0; logic [31:0] code=0; wire estop;
    logic rv=0,critical=0,dock=0,en=0;
    logic signed [3:0] l=0,r=0; wire signed [3:0] sl,sr;
    logic [11:0] d1=300,d2=300; logic v1=1,v2=1,u1=0,u2=0;
    wire stopped,expired,blocked; wire [2:0] reason;
    irEmergencyStop es(.clk(clk),.reset(reset),.code_valid(ev),.code(code),.power_configured(1'b1),.power_key(8'hA5),.estop_latched(estop));
    motorSafetyController #(.WATCHDOG_CLKS(40),.SONAR_STALE_CLKS(80)) dut(
        .clk(clk),.reset(reset),.estop_latched(estop),.critical_fault(critical),.dock_complete(dock),
        .request_valid(rv),.request_left(l),.request_right(r),.sonar_safety_enable(en),
        .sonar1_distance_mm(d1),.sonar2_distance_mm(d2),.sonar1_valid(v1),.sonar2_valid(v2),.sonar1_update(u1),.sonar2_update(u2),
        .safe_left(sl),.safe_right(sr),.stop_active(stopped),.control_expired(expired),.sonar_blocked(blocked),.stop_reason(reason));
    task automatic tick(input int n=1); repeat(n) begin @(posedge clk); #1; @(negedge clk); end endtask
    task automatic check(input bit ok,input string what); if(!ok) $fatal(1,"FAIL %s",what); endtask
    task automatic request(input int a,b); l=4'(a);r=4'(b);rv=1;tick();rv=0; endtask
    task automatic sample(input int a,b,input bit av=1,bv=1);d1=12'(a);d2=12'(b);v1=av;v2=bv;u1=1;u2=1;tick();u1=0;u2=0;endtask
    task automatic key(input logic [7:0] k);code={~k,k,16'h00ff};ev=1;tick();ev=0;endtask
    task automatic rst();reset=1;tick(2);reset=0;tick();endtask
    initial begin
        rst();check(stopped && sl==0 && sr==0,"reset safe idle");
        request(2,2);check(sl==2 && sr==2,"fresh request starts");
        sample(1,1,0,0);tick();check(sl==2 && !blocked,"disabled sonar ignores bad/near data");
        key(8'hA5);check(estop && stopped && reason==1 && sl==0,"POWER locks zero immediately");
        tick(5);check(estop,"release does not clear");key(8'hA5);check(estop,"second POWER does not clear");
        key(8'h1A);request(5,5);check(sl==0 && sr==0,"CH/new manual request inhibited");
        key(8'h1B);request(-5,5);check(sl==0 && sr==0,"VOL/visual request inhibited");
        critical=1;en=1;dock=1;tick();check(reason==1,"estop priority over all faults");
        critical=0;en=0;dock=0;rst();tick(3);check(sl==0 && sr==0,"reset cannot resume held request");
        request(1,-1);check(sl==1 && sr== -1,"new post-reset request accepted");
        tick(39);check(!expired,"watchdog not early");tick();check(expired && sl==0,"watchdog expires at 40 clocks");
        tick(4);check(sl==0,"old request cannot resume");request(3,3);check(sl==3,"new request recovers");
        critical=1;tick();check(sl==0 && reason==2,"critical fault stop");critical=0;tick();check(sl==0,"fault clearing needs fresh request");
        request(2,2);dock=1;#1;check(reason==4 && sl==0,"docking stop");tick();dock=0;tick();check(sl==0,"dock release safe idle");
        en=1;sample(300,300);tick();request(2,2);check(sl==2,"fresh healthy sonar enables");
        sample(200,300);check(blocked && sl==0,"sensor1 boundary 200 mm");
        sample(229,300);check(blocked,"hysteresis holds at 229");sample(230,300);tick();request(1,1);check(sl==1,"release at 230 after fresh request");
        sample(300,199);check(blocked && sl==0,"sensor2 danger");sample(300,300);tick();request(1,1);
        sample(300,300,0,1);check(blocked && sl==0,"invalid sensor1 stops");sample(300,300,1,0);check(blocked,"invalid sensor2 stops");
        sample(201,201);tick();request(1,1);check(sl==1,"201 mm after clear is safe");
        // Keep control fresh while only sensor1 reports: sensor2 must age out independently.
        repeat(4) begin tick(19);d1=300;u1=1;request(1,1);u1=0;end
        tick(2);check(blocked && sl==0,"sensor2 stale despite sensor1 updates");
        sample(300,300);tick();request(1,1);
        repeat(4) begin tick(19);d2=300;u2=1;request(1,1);u2=0;end
        tick(2);check(blocked && sl==0,"sensor1 stale despite sensor2 updates");
        en=0;request(7,1);check(sl==0,"out of range control fails closed");
        rst();code=32'h00A500ff;ev=1;tick();ev=0;check(!estop,"bad NEC complement ignored");
        $display("PASS safety_unit_tb: estop/reset, manual/visual inhibition, watchdog boundaries/recovery, sonar disable/dual threshold/hysteresis/invalid/stale, fault priority");$finish;
    end
    initial begin #100us;$fatal(1,"FAIL safety unit timeout");end
endmodule
