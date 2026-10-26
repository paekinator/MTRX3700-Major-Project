`timescale 1ns/1ps
/*
 *  blink.sv -- make a one-clock event visible on an LED.
 *
 *  pulse_stretch:  q is high for CLKS clocks after every trigger (retriggered while it is high).
 *  line_activity:  q is high for CLKS clocks after any edge on an asynchronous line (a UART
 *                  pin, say): the line is synchronised with two flip-flops first.
 */
module pulse_stretch #(
    parameter int CLKS = 2_500_000      // 50 ms at 50 MHz
) (
    input  logic clk,
    input  logic trigger,
    output logic q
);
    localparam int CW = $clog2(CLKS + 1);
    logic [CW-1:0] count = '0;
    always_ff @(posedge clk)
        if (trigger)         count <= CW'(CLKS);
        else if (count != 0) count <= count - 1'b1;
    assign q = (count != 0);
endmodule

module line_activity #(
    parameter int CLKS = 2_500_000
) (
    input  logic clk,
    input  logic line,
    output logic q
);
    logic [2:0] s = 3'b111;
    always_ff @(posedge clk) s <= {s[1:0], line};
    pulse_stretch #(.CLKS(CLKS)) u_stretch (.clk(clk), .trigger(s[2] ^ s[1]), .q(q));
endmodule
