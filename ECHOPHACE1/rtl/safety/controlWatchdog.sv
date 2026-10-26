// ECHO-7 team; AI-assisted by OpenAI Codex. Counts accepted control updates, not UART activity.
module controlWatchdog #(parameter int TIMEOUT_CLKS=25_000_000) (
    input logic clk, reset, invalidate, request_valid,
    output logic expired
);
    localparam int W=$clog2(TIMEOUT_CLKS+1);
    logic [W-1:0] remaining;
    always_ff @(posedge clk) begin
        if (reset || invalidate) remaining <= '0;
        else if (request_valid) remaining <= W'(TIMEOUT_CLKS);
        else if (remaining != 0) remaining <= remaining-1'b1;
    end
    assign expired=(remaining==0);
endmodule
