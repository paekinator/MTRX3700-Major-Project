# 50 MHz board clock: the whole design runs on it.
create_clock -name CLOCK_50 -period 20.000 [get_ports CLOCK_50]
derive_clock_uncertainty
# The keys and switches change at any time and go through two flip-flops; the outputs are slow (a UART at
# 115200 baud, LEDs, displays).
set_false_path -from [get_ports {KEY[*] SW[*] GPIO_1[*]}]
set_false_path -to   [get_ports {GPIO_1[*] HEX0[*] HEX1[*] HEX2[*] HEX3[*] HEX4[*] HEX5[*] LEDR[*]}]
