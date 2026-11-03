`timescale 1ns/1ps
// Extend an event for human-visible LED indication, cleared by KEY0 reset.
module pulse_stretch #(
    parameter int CLKS = 2_500_000
) (
    input  logic clk,
    input  logic reset,
    input  logic trigger,
    output logic q
);
    localparam int CW = (CLKS > 0) ? $clog2(CLKS + 1) : 1;
    logic [CW-1:0] count = '0;
    always_ff @(posedge clk)
        if (reset)           count <= '0;
        else if (trigger)    count <= CW'(CLKS);
        else if (count != 0) count <= count - 1'b1;
    assign q = (count != 0);
endmodule
