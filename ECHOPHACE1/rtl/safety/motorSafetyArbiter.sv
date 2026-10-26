// ECHO-7 team; AI-assisted by OpenAI Codex. Speeds are signed 0.1 m/s units.
module motorSafetyArbiter (
    input logic reset, estop_latched, control_expired, critical_fault,
    input logic sonar_blocked, dock_complete,
    input logic signed [3:0] requested_left,requested_right,
    output logic signed [3:0] safe_left,safe_right,
    output logic stop_active,
    output logic [2:0] stop_reason
);
    // 0 normal, 1 estop, 2 stale/fault/reset, 3 sonar, 4 docking stop.
    always_comb begin
        stop_reason=0;
        if (estop_latched) stop_reason=1;
        else if (reset || control_expired || critical_fault) stop_reason=2;
        else if (sonar_blocked) stop_reason=3;
        else if (dock_complete) stop_reason=4;
        stop_active=(stop_reason!=0);
        safe_left=stop_active ? 4'sd0 : requested_left;
        safe_right=stop_active ? 4'sd0 : requested_right;
    end
endmodule
