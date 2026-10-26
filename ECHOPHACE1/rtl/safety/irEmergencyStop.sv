// ECHO-7 team; AI-assisted by OpenAI Codex. Human review required.
// POWER_KEY is a measured NEC command byte, not a guessed remote code.
module irEmergencyStop (
    input logic clk, reset,
    input logic code_valid,
    input logic [31:0] code,
    input logic power_configured,
    input logic [7:0] power_key,
    output logic estop_latched
);
    always_ff @(posedge clk) begin
        if (reset) estop_latched <= 1'b0;
        else if (power_configured && code_valid &&
                 code[31:24] == ~code[23:16] && code[23:16] == power_key)
            estop_latched <= 1'b1;
    end
endmodule
