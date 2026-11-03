# CLOCK_50, video/PCLK and derived PLL clocks are declared once in PartBDebug.sdc.
# The public v3 link/timeUs/reset are internal synchronous paths: NO false paths,
# virtual ports, or board input/output delay constraints on this interface.
set_false_path -from [get_ports {IRDA_RXD GPIO_1[29] GPIO_1[33]}]
set_false_path -to [get_ports {GPIO_1[27] GPIO_1[31]}]
# Held sonar payload has a 20 ns data-path bound; sync stages remain timed.
set_max_delay 20.0 -from [get_registers {*sonar_u*payload*}] -to [get_registers {*sonar_u*distance_mm* *sonar_u*distance_valid*}]
set_min_delay 0.0 -from [get_registers {*sonar_u*payload*}] -to [get_registers {*sonar_u*distance_mm* *sonar_u*distance_valid*}]
set_false_path -to [get_registers {*sonar_u*req_sync[0] *sonar_u*ack_sync[0]}]
# Only asynchronous assertion into the sonar reset synchroniser.
set_false_path -from [get_registers {rs50[1]}] -to [get_registers {*sonar_u*sr[*]}]
