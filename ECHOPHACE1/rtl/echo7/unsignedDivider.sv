// ECHO-7 Phase 1.5 | Owner: MTRX3700 ECHO-7 team; human review pending.
// AI-assisted implementation: OpenAI Codex. See OWNERS.md and AI_STATEMENT.md.
module unsignedDivider #(parameter int WIDTH=27) (
    input logic clk, reset, start,
    input logic [WIDTH-1:0] numerator, denominator,
    output logic busy, done, divide_by_zero,
    output logic [WIDTH-1:0] quotient
);
    // Restoring unsigned division: WIDTH iterations, one subtraction per clock.
    // start is accepted only while idle. No pixel CE: work continues during VGA stalls.
    localparam int CW = (WIDTH < 2) ? 1 : $clog2(WIDTH);
    logic [WIDTH-1:0] dividend, divisor, q;
    logic [WIDTH:0] remainder, trial;
    logic [CW-1:0] iteration;
    logic [WIDTH-1:0] next_q;
    always_comb begin
        trial = {remainder[WIDTH-1:0], dividend[WIDTH-1]};
        next_q = {q[WIDTH-2:0], 1'b0};
        if (trial >= {1'b0, divisor}) begin
            trial = trial - {1'b0, divisor};
            next_q[0] = 1'b1;
        end
    end
    always_ff @(posedge clk) begin
        if (reset) begin
            busy<=0; done<=0; divide_by_zero<=0; quotient<='0;
            dividend<='0; divisor<='0; q<='0; remainder<='0; iteration<='0;
        end else begin
            done<=0;
            if (start && !busy) begin
                divide_by_zero <= (denominator == 0);
                if (denominator == 0) begin quotient<='0; done<=1; end
                else begin
                    busy<=1; dividend<=numerator; divisor<=denominator;
                    q<='0; remainder<='0; iteration<='0;
                end
            end else if (busy) begin
                dividend <= dividend << 1; remainder <= trial; q <= next_q;
                if (iteration == CW'(WIDTH-1)) begin
                    quotient<=next_q; busy<=0; done<=1;
                end else iteration<=iteration+1'b1;
            end
        end
    end
endmodule
