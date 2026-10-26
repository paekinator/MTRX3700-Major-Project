# hwtest.sdc -- timing constraints for the hardware test (DE1-SoC, Quartus 18.1).
#
# Six clock domains (four without HWTEST_EXTRAS): the 50 MHz oscillator (UARTs, IR, and the codec's
# 100 kHz I2C clock divided from it); the video PLL (25 MHz display, 10 MHz camera XCLK) and the 100 kHz SCCB clock divided
# from it; the camera's own 40 MHz PCLK coming back on GPIO_1[21] (a separate oscillator as far as
# timing is concerned: XCLK went out through 33 R and a ribbon, and the sensor's PLL multiplied it
# by four); the 43.904 MHz sonar PLL; the
# 18.432 MHz codec MCLK PLL; and AUD_BCLK, 3.072 MHz from the codec. They only meet through the
# frame buffer's dual-clock RAM, two-flop synchronisers and quasi-static display values, so every
# pair is declared asynchronous (Lesson 4 1.3).

create_clock -name CLOCK_50 -period 20.000  [get_ports CLOCK_50]
create_clock -name PCLK     -period 25.000  [get_ports {GPIO_1[21]}]
create_clock -name AUD_BCLK -period 325.500 [get_ports AUD_BCLK]
derive_pll_clocks
derive_clock_uncertainty

# the two divided clocks (clock_divider.sv counters), so that the I2C masters' paths are checked
create_generated_clock -name sccb_clk -source [get_pins {video_pll_u|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}] \
    -divide_by 250 [get_registers {clock_divider:sccb_clk_u|clk_out}]
# The codec's I2C divider (and its MCLK PLL, adc_pll) exist only with HWTEST_EXTRAS; a constraint on an
# empty collection is a critical warning, so they are declared only when the registers are there.
set g_50  [get_clocks {CLOCK_50}]
set g_adc [list]
if {[get_collection_size [get_registers -nowarn {clock_divider:i2c_clk_u|clk_out}]] > 0} {
    create_generated_clock -name i2c_clk -source [get_ports CLOCK_50] \
        -divide_by 500 [get_registers {clock_divider:i2c_clk_u|clk_out}]
    set g_50  [get_clocks {CLOCK_50 i2c_clk}]
    set g_adc [list -group [get_clocks {*adc_pll*}]]
}

# The camera drives D[7:0], HREF and VSYNC after the FALLING edge of PCLK (datasheet; the board agrees), 1 to
# 5 ns, plus about 2 ns for the ribbon and the DE1-SoC's 47 R + clamp on each pin. The capture latches them on
# the RISING edge, 12.5 ns after the fall at 40 MHz, in flops placed in the I/O cells (mp/camera/quartus/Camera.sdc).
set_input_delay -clock PCLK -clock_fall -max 7.0 [get_ports {GPIO_1[12] GPIO_1[13] GPIO_1[14] GPIO_1[15] GPIO_1[16] GPIO_1[17] GPIO_1[18] GPIO_1[19] GPIO_1[22] GPIO_1[23]}]
set_input_delay -clock PCLK -clock_fall -min 0.0 [get_ports {GPIO_1[12] GPIO_1[13] GPIO_1[14] GPIO_1[15] GPIO_1[16] GPIO_1[17] GPIO_1[18] GPIO_1[19] GPIO_1[22] GPIO_1[23]}]

set_clock_groups -asynchronous \
    -group $g_50 \
    -group [get_clocks {PCLK}] \
    -group [get_clocks {*video_pll* sccb_clk}] \
    -group [get_clocks {*sonar_pll*}] \
    -group [get_clocks {AUD_BCLK}] \
    {*}$g_adc

# Slow, static or synchronised I/O: buttons, switches, the IR receiver, the UART lines (the
# receivers synchronise them; a bit is 8.7 us), ECHO (synchronised in sonar_range), the SCCB data
# line, the LEDs, the displays, the camera's control pins and XCLK, TRIG, the Nano's RESET, the
# codec's MCLK and I2C, and the VGA pins (the VGA Controller registers them at the pixel clock).
set_false_path -from [get_ports {KEY[*] SW[*] IRDA_RXD GPIO_1[3] GPIO_1[24] GPIO_1[29] GPIO_1[33] GPIO_1[34] FPGA_I2C_SDAT}]
set_false_path -to   [get_ports {LEDR[*] HEX0[*] HEX1[*] HEX2[*] HEX3[*] HEX4[*] HEX5[*] \
                                 GPIO_1[0] GPIO_1[5] GPIO_1[10] GPIO_1[11] GPIO_1[20] GPIO_1[24] GPIO_1[25] GPIO_1[27] GPIO_1[31] GPIO_1[35] \
                                 AUD_XCK FPGA_I2C_SCLK FPGA_I2C_SDAT VGA_*}]
