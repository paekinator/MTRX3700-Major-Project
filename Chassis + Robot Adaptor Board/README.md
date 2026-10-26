Driving the UGV02 chassis from the DE1-SoC (V2026.1)
====================================================

chassis_drive.sv drives the robot's chassis. Ten times a second it sends the chassis one line
of JSON on its UART (115200 baud, 8 data bits, no parity, one stop bit):

    {"T":11,"L":<left>,"R":<right>}

left and right are the PWM of the left and the right motors, from -255 (full speed backwards)
to 255 (full speed forwards). The chassis keeps driving at the last PWM it was sent, and stops
by itself 3 s after the last command, so the module sends the command again every 100 ms
whether or not it changed. With enable low it sends stops, {"T":11,"L":0,"R":0}.

Use T:11 rather than T:1 (speed in m/s), although Waveshare's documentation recommends T:1 and
calls T:11 a debugging command. On robots with the 0.96 firmware, T:1 surges and stalls below
about 0.2 m/s; T:11 sets the motor PWM directly on both of the lab's firmwares. To turn a speed
into a PWM, multiply the speed in m/s by 512, round it and limit it to 255. How fast a given PWM
really drives your robot depends on the robot and its battery: measure it.

The testbench runs everything against a simulation model of the chassis (tb/ugv02_model.sv),
which receives the UART bytes, checks each line as strict JSON (the chassis itself is more
forgiving) and drives a simulated robot, so you can test without a robot.


Simulate
--------

    ./simulate.sh         every check; PASS or FAIL at the end (about a minute in our tests)
    ./simulate.sh wave    only the first command, into waveform.fst, then GTKWave (chassis.gtkw)

Part 1 checks the text chassis_drive sends for a range of PWMs (signs, one to three digits,
clamping, stops). Part 2 runs the top level as on the board, with its switches and keys, and
checks what the simulated robot does. The chassis model's report is in sim.log: each new
command it received and what it made of it, and every line it would not take, with the reason.
A command repeated unchanged is counted, not printed.


Build (Quartus 18.1)
--------------------

Open quartus/chassis.qpf and compile it (Processing > Start Compilation). To program it, open
Tools > Programmer: Hardware Setup (DE-SoC), Auto Detect (pick 5CSEMA5), select the 5CSEMA5 row,
Change File to output_files/chassis.sof, tick Program/Configure and press Start.

The same from a Command Prompt in the quartus folder, with Quartus installed in its usual
place (change C:\intelFPGA_lite\18.1 if yours is elsewhere; @2: the FPGA is the second device
on the DE1-SoC's JTAG chain):

    C:\intelFPGA_lite\18.1\quartus\bin64\quartus_sh.exe --flow compile chassis
    C:\intelFPGA_lite\18.1\quartus\bin64\quartus_pgm.exe -m jtag -o "p;output_files/chassis.sof@2"

On Linux, run quartus_sh and quartus_pgm the same way, with Quartus's bin folder on the PATH.

In our tests (Quartus 18.1, 16 October 2026) it compiles in about a minute to 339 ALMs and 371
registers, with 0 critical warnings, and meets timing with 5.3 ns of setup slack (Fmax 68 MHz).


On the board
------------

Wire the chassis to J5 on the Robot Adaptor Board (GND, TX and RX; never J5's 3V3), as slide
2 (UART: Chassis + Robot Adaptor Board) shows. Put the robot on its stand, wheels in the air, before the
first test, and start with a small PWM.

    SW0          go: down, every command is a stop
    SW9..SW2     the PWM, 0 to 255 (SW9 is the top bit), shown in decimal on HEX3..HEX0
    SW1          backwards
    KEY3 held    spin left on the spot
    KEY2 held    spin right on the spot
    KEY0         reset
    LEDR0        go
    LEDR1        flickers ten times a second: a command going out
    LEDR2..LEDR4 backwards, spinning left, spinning right

Low PWMs may not turn the motors at all. Find the smallest PWM that moves your robot, and how
fast a few PWMs drive it on the floor: your design needs those numbers.
On two of the lab's robots the wheels started at about PWM 15 to 20, one wheel before the
others, and a little lower on a full battery: do not count on a PWM below about 20 moving
the robot.


Files
-----

    rtl/       chassis_drive.sv (the commands), uart_tx.sv (the UART transmitter), top_level.sv
               (the switches and keys), display.sv and seven_seg.sv (the PWM on HEX3..HEX0)
    tb/        chassis_drive_tb.sv (the testbench), ugv02_model.sv (the chassis model)
    quartus/   chassis.qpf, chassis.qsf (the DE1-SoC's own pin names), chassis.sdc
    simulate.sh and chassis.gtkw   the Verilator run and the GTKWave signal list
