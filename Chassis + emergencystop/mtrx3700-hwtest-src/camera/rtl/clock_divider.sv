/*
 *  clock_divider.sv -- divide a clock by an even integer with a counter.
 *
 *  clk_out toggles every DIVISOR/2 cycles of clk_in, so f_out = f_in / DIVISOR
 *  with a 50% duty cycle. Used here for the I2C bit clock (100 kHz from 50 MHz),
 *  which is far too slow for the PLL. A divided clock like this is fine for a
 *  slow serial interface; for anything fast use a PLL or a clock enable instead.
 */
module clock_divider #(
    parameter int DIVISOR = 500          // must be even
) (
    input  logic clk_in,
    output logic clk_out
);
    localparam int HALF = DIVISOR / 2;
    logic [$clog2(HALF)-1:0] count = '0;

    initial clk_out = 1'b0;          // simulation start value (a plain always block, so ModelSim allows the initial)
    always @(posedge clk_in) begin
        if (count == HALF - 1) begin
            count   <= '0;
            clk_out <= ~clk_out;
        end else begin
            count <= count + 1'b1;
        end
    end
endmodule
