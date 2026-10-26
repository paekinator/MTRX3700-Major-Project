// ECHO-7 team; AI-assisted by OpenAI Codex. All control runs at CLOCK_50.
// POWER_KEY=00 is a placeholder. Unconfigured mode prevents all motion while reading codes.
module safetySystem #(
    parameter bit POWER_KEY_CONFIGURED=0,
    parameter logic [7:0] POWER_KEY=8'h00,
    parameter int CLK_HZ=50_000_000, HOLD_CLKS=15_000_000,
    parameter int WATCHDOG_CLKS=25_000_000, PERIOD_CLKS=10_000_000, CLKS_PER_BIT=434
) (
    input logic clk,reset,ir_rx,chassis_rx,
    input logic [11:0] sonar1_distance_mm,sonar2_distance_mm,
    input logic sonar1_valid,sonar2_valid,sonar1_update,sonar2_update,
    output logic chassis_tx,estop_latched,control_expired,stop_active,rx_seen,
    output logic [7:0] last_ir_key,
    output logic [31:0] last_ir_code,
    output logic ir_seen,
    output logic [2:0] stop_reason
);
    logic code_valid,repeat_code,request_valid,sonar_blocked;
    logic [31:0] code;
    logic signed [3:0] request_left,request_right,safe_left,safe_right;
    necDecoderSafe #(.CLK_HZ(CLK_HZ)) decoder_u(.clk(clk),.rst(reset),.ir(ir_rx),.valid(code_valid),.code(code),.repeat_code(repeat_code));
    irEmergencyStop emergency_u(.clk(clk),.reset(reset),.code_valid(code_valid),.code(code),
        .power_configured(POWER_KEY_CONFIGURED),.power_key(POWER_KEY),.estop_latched(estop_latched));
    irMotionControl #(.HOLD_CLKS(HOLD_CLKS)) manual_u(.clk(clk),.reset(reset),.inhibit(estop_latched || !POWER_KEY_CONFIGURED),
        .code_valid(code_valid),.repeat_code(repeat_code),.code(code),
        .request_valid(request_valid),.request_left(request_left),.request_right(request_right));
    motorSafetyController #(.WATCHDOG_CLKS(WATCHDOG_CLKS)) controller_u(
        .clk(clk),.reset(reset),.estop_latched(estop_latched),.critical_fault(!POWER_KEY_CONFIGURED),.dock_complete(1'b0),
        .request_valid(request_valid),.request_left(request_left),.request_right(request_right),
        .sonar_safety_enable(1'b0), // Ultrasonic Safety DISABLED; real data remain connected.
        .sonar1_distance_mm(sonar1_distance_mm),.sonar2_distance_mm(sonar2_distance_mm),
        .sonar1_valid(sonar1_valid),.sonar2_valid(sonar2_valid),.sonar1_update(sonar1_update),.sonar2_update(sonar2_update),
        .safe_left(safe_left),.safe_right(safe_right),.stop_active(stop_active),.control_expired(control_expired),
        .sonar_blocked(sonar_blocked),.stop_reason(stop_reason));
    safeChassisCommand #(.CLKS_PER_BIT(CLKS_PER_BIT),.PERIOD_CLKS(PERIOD_CLKS)) sender_u(
        .clk(clk),.reset(reset),.stop_active(stop_active),.safe_left(safe_left),.safe_right(safe_right),
        .tx(chassis_tx),.busy(),.zero_line_started(),.line_done());
    logic rx_valid,rx_error;
    uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) rx_u(.clk(clk),.rst(reset),.rx(chassis_rx),.data_rx(),
        .valid(rx_valid),.ready(1'b1),.parity_error(),.framing_error(rx_error));
    always_ff @(posedge clk) begin
        if(reset) begin last_ir_key<=0; last_ir_code<=0; ir_seen<=0; rx_seen<=0; end
        else begin
            if(code_valid) begin last_ir_key<=code[23:16]; last_ir_code<=code; ir_seen<=1; end
            if(rx_valid && !rx_error) rx_seen<=1; // Activity only, not a command acknowledgement.
        end
    end
endmodule
