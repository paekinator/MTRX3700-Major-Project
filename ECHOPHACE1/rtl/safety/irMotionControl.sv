// ECHO-7 team; AI-assisted adapter around the supplied ir_drive.
// Full non-motion frames cancel repeat association. Only accepted motion updates feed the watchdog.
module irMotionControl #(parameter int HOLD_CLKS=15_000_000) (
    input logic clk,reset,inhibit,code_valid,repeat_code,
    input logic [31:0] code,
    output logic request_valid,
    output logic signed [3:0] request_left,request_right
);
    logic active,was_active,update_pending,repeat_motion;
    logic [1:0] motion,speed;
    logic motion_key,speed_key;
    logic signed [3:0] magnitude;
    assign motion_key=(code[23:16]==8'h1A || code[23:16]==8'h1E || code[23:16]==8'h1F || code[23:16]==8'h1B);
    assign speed_key=(code[23:16]>=1 && code[23:16]<=4);
    ir_drive #(.HOLD_CLKS(HOLD_CLKS)) drive_u (
        .clk(clk),.reset(reset || inhibit),.valid(code_valid),.repeat_code(repeat_code && repeat_motion),
        .code(code),.active(active),.motion(motion),.speed(speed));
    always_ff @(posedge clk) begin
        if (reset || inhibit) begin update_pending<=0; was_active<=0; repeat_motion<=0; end
        else begin
            was_active<=active;
            update_pending <= (code_valid && (motion_key || (speed_key && active))) ||
                              (repeat_code && !code_valid && repeat_motion && active);
            if (code_valid) repeat_motion<=motion_key;
            else if (!active) repeat_motion<=0;
        end
    end
    always_comb begin
        case(speed) 0:magnitude=1; 1:magnitude=2; 2:magnitude=3; default:magnitude=5; endcase
        request_valid=!reset && !inhibit && (update_pending || (was_active && !active));
        request_left=0; request_right=0;
        if (active) begin
            request_left=(motion==1 || motion==2) ? -magnitude : magnitude;
            request_right=(motion==1 || motion==3) ? -magnitude : magnitude;
        end
    end
endmodule
