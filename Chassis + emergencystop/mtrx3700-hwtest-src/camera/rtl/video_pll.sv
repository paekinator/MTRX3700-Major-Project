`timescale 1ns/1ps
/*
 *  video_pll.sv -- 50 MHz in, 25 MHz pixel clock and 10 MHz camera clock out, using the PLL Intel FPGA IP.
 *
 *  The same altera_pll instantiation that the IP Parameter Editor generates
 *  (Task 1.2), written out by hand so the project has no wizard files, exactly
 *  like adc_pll.sv in the mic-input project. The VGA Controller in vga.qsys (or vga_text.qsys)
 *  is configured for 640x480, whose pixel clock is 25.175 MHz nominal; 25 MHz
 *  is what the University Program cores use and every monitor accepts it. The second output,
 *  10 MHz, is the camera's XCLK: its own PLL multiplies it by 4 to a 40 MHz pixel clock with the
 *  prescaler left at /1 (a prescaler other than /1 shifted the rows against HREF on the board).
 *
 *  Simulators cannot run the PLL primitive without Intel's libraries, so in
 *  simulation (Verilator, or ModelSim via its MODEL_TECH define) the module
 *  becomes a behavioural stand-in: a clock generator at the same frequency.
 */
module video_pll (
    input  wire refclk,     // 50 MHz
    input  wire rst,
    output wire outclk_0,   // 25 MHz
    output wire outclk_1,   // 10 MHz
    output wire locked
);
`ifdef VERILATOR
    `define VIDEO_PLL_SIM_STANDIN
`elsif MODEL_TECH
    `define VIDEO_PLL_SIM_STANDIN     // ModelSim predefines MODEL_TECH
`endif
`ifdef VIDEO_PLL_SIM_STANDIN
    logic clk_sim, clk_sim1;
    initial begin clk_sim = 1'b0; clk_sim1 = 1'b0; end
    always #(20ns) clk_sim = ~clk_sim;   // 25 MHz
    always #(50ns) clk_sim1 = ~clk_sim1; // 10 MHz
    assign outclk_0 = clk_sim;
    assign outclk_1 = clk_sim1;
    assign locked   = 1'b1;
`else
    altera_pll #(
        .fractional_vco_multiplier("false"),
        .reference_clock_frequency("50.0 MHz"),
        .operation_mode("normal"),
        .number_of_clocks(2),
        .output_clock_frequency0("25.000000 MHz"),
        .phase_shift0("0 ps"),
        .duty_cycle0(50),
        .output_clock_frequency1("10.000000 MHz"),
        .phase_shift1("0 ps"),
        .duty_cycle1(50),
        .pll_type("General"),
        .pll_subtype("General")
    ) altera_pll_i (
        .rst      (rst),
        .outclk   ({outclk_1, outclk_0}),
        .locked   (locked),
        .fboutclk ( ),
        .fbclk    (1'b0),
        .refclk   (refclk)
    );
`endif
endmodule
