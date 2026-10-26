// ECHO-7 team; AI-assisted by OpenAI Codex. Common final path for manual or future visual requests.
module motorSafetyController #(parameter int WATCHDOG_CLKS=25_000_000, SONAR_STALE_CLKS=15_000_000) (
    input logic clk,reset,estop_latched,critical_fault,dock_complete,
    input logic request_valid,
    input logic signed [3:0] request_left,request_right,
    input logic sonar_safety_enable,
    input logic [11:0] sonar1_distance_mm,sonar2_distance_mm,
    input logic sonar1_valid,sonar2_valid,sonar1_update,sonar2_update,
    output logic signed [3:0] safe_left,safe_right,
    output logic stop_active,control_expired,sonar_blocked,
    output logic [2:0] stop_reason
);
    logic signed [3:0] held_left,held_right;
    logic invalidate,accepted,bad_request;
    assign bad_request=request_valid && (request_left>5 || request_left< -5 || request_right>5 || request_right< -5);
    assign invalidate=estop_latched || critical_fault || sonar_blocked || dock_complete || bad_request;
    assign accepted=request_valid && !invalidate;
    controlWatchdog #(.TIMEOUT_CLKS(WATCHDOG_CLKS)) watchdog_u (
        .clk(clk),.reset(reset),.invalidate(invalidate),.request_valid(accepted),.expired(control_expired));
    ultrasonicSafety #(.STALE_CLKS(SONAR_STALE_CLKS)) sonar_u (
        .clk(clk),.reset(reset),.enable(sonar_safety_enable),
        .sonar1_distance_mm(sonar1_distance_mm),.sonar2_distance_mm(sonar2_distance_mm),
        .sonar1_valid(sonar1_valid),.sonar2_valid(sonar2_valid),
        .sonar1_update(sonar1_update),.sonar2_update(sonar2_update),.blocked(sonar_blocked),.fault(),.danger());
    always_ff @(posedge clk) begin
        if (reset || invalidate) begin held_left<=0; held_right<=0; end
        else if (accepted) begin held_left<=request_left; held_right<=request_right; end
        else if (control_expired) begin held_left<=0; held_right<=0; end
    end
    motorSafetyArbiter arbiter_u (
        .reset(reset),.estop_latched(estop_latched),.control_expired(control_expired),
        .critical_fault(critical_fault || bad_request),.sonar_blocked(sonar_blocked),.dock_complete(dock_complete),
        .requested_left(held_left),.requested_right(held_right),.safe_left(safe_left),.safe_right(safe_right),
        .stop_active(stop_active),.stop_reason(stop_reason));
endmodule
