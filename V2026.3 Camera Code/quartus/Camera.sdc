# Camera.sdc -- timing constraints for the OV7670 camera project (DE1-SoC, Quartus 18.1).
#
# Five clocks: the 50 MHz oscillator, the 25 MHz pixel clock and the 10 MHz camera XCLK the PLL
# makes from it, the camera's own 40 MHz PCLK coming back in on GPIO_1[21], and the 100 kHz SCCB
# clock from a counter (below). PCLK is NOT a PLL
# clock: XCLK went out through 33 R and a ribbon, and the sensor's own PLL multiplied it, so PCLK
# is a separate, unrelated clock. The Lesson 4 rule applies: every path between two domains is either a
# proper crossing (the frame buffer's dual-clock RAM) or a false path.

create_clock -name CLOCK_50 -period 20.000 [get_ports CLOCK_50]
create_clock -name PCLK     -period 25.000 [get_ports {GPIO_1[21]}]
derive_pll_clocks
derive_clock_uncertainty

# The 100 kHz SCCB clock comes out of a counter (clock_divider.sv), 250 x slower than the PLL
# clock; declare it so that the I2C master's paths are checked (as in Lesson 3's mic-input).
create_generated_clock -name sccb_clk -source [get_pins {video_pll_u|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}] \
    -divide_by 250 [get_registers {clock_divider:sccb_clk_u|clk_out}]

# The camera drives D[7:0], HREF and VSYNC up to 5 ns after the FALLING edge of PCLK (datasheet Table 4), plus
# about 2 ns of margin for skew between the ribbon's wires and the DE1-SoC's 47 R + clamp on each pin. PCLK comes
# down the same ribbon, so a longer ribbon delays the clock and the data alike and does not change these numbers. The capture latches them on the RISING edge, 12.5 ns after the fall at 40 MHz: 5.5 ns
# of margin outside the chip, and the capture flops sit in the I/O cells (FAST_INPUT_REGISTER in the .qsf) so the
# path inside is as short as it can be. At a 100 MHz PCLK the same numbers would leave none, even on paper.
set_input_delay -clock PCLK -clock_fall -max 7.0 [get_ports {GPIO_1[12] GPIO_1[13] GPIO_1[14] GPIO_1[15] GPIO_1[16] GPIO_1[17] GPIO_1[18] GPIO_1[19] GPIO_1[22] GPIO_1[23]}]
set_input_delay -clock PCLK -clock_fall -min 0.0 [get_ports {GPIO_1[12] GPIO_1[13] GPIO_1[14] GPIO_1[15] GPIO_1[16] GPIO_1[17] GPIO_1[18] GPIO_1[19] GPIO_1[22] GPIO_1[23]}]

# Domains that only meet through the frame buffer RAM (PCLK -> pixel clock), through synchronisers
# (KEY0's reset) or not at all (the frame toggle only drives an LED): asynchronous.
set_clock_groups -asynchronous -group [get_clocks CLOCK_50] -group [get_clocks PCLK] \
    -group [get_clocks {*video_pll* sccb_clk}]

# Slow or static I/O: the buttons, the LEDs, the camera's control pins and XCLK, the VGA pins
# (the VGA Controller registers them at the pixel clock and the DAC tolerates the skew).
set_false_path -from [get_ports {KEY[*]}]
set_false_path -to   [get_ports {LEDR[*] GPIO_1[10] GPIO_1[11] GPIO_1[20] GPIO_1[24] GPIO_1[25]}]
set_false_path -from [get_ports {GPIO_1[24]}]
set_false_path -to   [get_ports {VGA_*}]
