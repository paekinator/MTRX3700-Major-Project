`timescale 1ns/1ps
/*
 *  adc_pll.sv -- 50 MHz in, 18.432 MHz out, using the PLL Intel FPGA IP.
 *
 *  This is the same altera_pll instantiation that the IP Parameter Editor
 *  generates (Task 1.2), written out by hand so the project has no wizard files.
 *  Quartus picks the closest achievable frequency (18.432 MHz is available on the
 *  Cyclone V: 50 x 1152 / 3125).
 *
 *  Simulators cannot run the PLL primitive without Intel's libraries, so in
 *  simulation (Verilator, or ModelSim via its MODEL_TECH define) the module
 *  becomes a behavioural stand-in: a clock generator at the same frequency.
 *  A two-line simulation model.
 */
module adc_pll (
    input  wire refclk,     // 50 MHz
    input  wire rst,
    output wire outclk_0,   // 18.432 MHz
    output wire locked
);
`ifdef VERILATOR
    `define ADC_PLL_SIM_STANDIN
`elsif MODEL_TECH
    `define ADC_PLL_SIM_STANDIN     // ModelSim predefines MODEL_TECH
`endif
`ifdef ADC_PLL_SIM_STANDIN
    logic clk_sim;
    initial clk_sim = 1'b0;
    always #(27.1267ns) clk_sim = ~clk_sim;   // 18.432 MHz
    assign outclk_0 = clk_sim;
    assign locked   = 1'b1;
`else
    altera_pll #(
        .fractional_vco_multiplier("false"),
        .reference_clock_frequency("50.0 MHz"),
        .operation_mode("normal"),
        .number_of_clocks(1),
        .output_clock_frequency0("18.432000 MHz"),
        .phase_shift0("0 ps"),
        .duty_cycle0(50),
        .pll_type("General"),
        .pll_subtype("General")
    ) altera_pll_i (
        .rst      (rst),
        .outclk   ({outclk_0}),
        .locked   (locked),
        .fboutclk ( ),
        .fbclk    (1'b0),
        .refclk   (refclk)
    );
`endif
endmodule
