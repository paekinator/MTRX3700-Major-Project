`timescale 1ns/1ps
/*
 *  sonar_pll.sv -- 50 MHz in, 43.904 MHz out, using the PLL Intel FPGA IP.
 *
 *  Why 43.904 MHz? sonar_range.sv counts clock cycles while ECHO is high and
 *  reports distance = count >> 8. Sound covers 1 mm there-and-back in
 *  2 mm / 343 m/s = 5.831 us, and 5.831 us x 43.904 MHz = 256.0 cycles: so
 *  256 cycles per millimetre, and dividing by 256 is a shift. (The 2025
 *  scaffold used the altpll wizard with multiply 2744 / divide 3125, which is
 *  the same ratio, 43.904 / 50.)
 *
 *  Written out by hand like video_pll.sv (Lesson 3, 1.2 PLLs), so the project
 *  has no wizard files. The PLL cannot make every frequency exactly: Quartus
 *  picks the nearest ratio its counters allow and reports the actual output
 *  frequency in the fitter report (Fitter > PLL Usage Summary). A few ppm of
 *  error is a fraction of a millimetre; the sensor itself is worse than that.
 *
 *  Simulators cannot run the PLL primitive without Intel's libraries, so in
 *  simulation (Verilator, or ModelSim via its MODEL_TECH define) the module
 *  becomes a behavioural stand-in: a clock generator at the same frequency.
 */
module sonar_pll (
    input  wire refclk,     // 50 MHz
    input  wire rst,
    output wire outclk_0,   // 43.904 MHz
    output wire locked
);
`ifdef VERILATOR
    `define SONAR_PLL_SIM_STANDIN
`elsif MODEL_TECH
    `define SONAR_PLL_SIM_STANDIN     // ModelSim predefines MODEL_TECH
`endif
`ifdef SONAR_PLL_SIM_STANDIN
    logic clk_sim;
    initial clk_sim = 1'b0;
    always #(11.3885ns) clk_sim = ~clk_sim;   // 43.904 MHz = 22.777 ns period
    assign outclk_0 = clk_sim;
    assign locked   = 1'b1;
`else
    altera_pll #(
        .fractional_vco_multiplier("true"),      // 43.904 = 50 x 2744/3125 needs M = 2744: beyond an integer PLL's
        .pll_fractional_cout(32),                // counters (M <= 512), so the fractional multiplier does it, exactly
        .pll_dsm_out_sel("1st_order"),           // as the 2025 wizard file (altpll 2744/3125) did underneath
        .reference_clock_frequency("50.0 MHz"),
        .operation_mode("normal"),
        .number_of_clocks(1),
        .output_clock_frequency0("43.904000 MHz"),
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
