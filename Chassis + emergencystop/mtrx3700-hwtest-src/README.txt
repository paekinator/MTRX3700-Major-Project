MTRX3700 2026 hardware test: the source, to change and recompile
=================================================================

This is the Quartus Prime 18.1 project behind hwtest.sof and hwtest.jic, cut down to the files a
compile needs. Its main use is changing how often the DE1-SoC sends a motion command to the robot.

You need Quartus Prime 18.1 (Lite is fine) with Cyclone V device support. Nothing else: the VGA
Controller is included as ready-generated files, so Platform Designer and the University Program
IP are not needed. Unzip to a short folder such as C:\mtrx3700\ rather than deep inside Downloads.


1. Change the rate
------------------
Open hwtest\rtl\top_level.sv in any text editor. Line 41 is:

    parameter int HEARTBEAT_CLKS  = 10_000_000,  // chassis command period, CLOCK_50 clocks (200 ms)

Change the number. It is the period in cycles of the board's 50 MHz clock, so the value is the
period in seconds times 50,000,000. Underscores inside the number are allowed. Update the comment
after it to match, so the next person is not misled; the compiler ignores it.

    command every   value         wheels start within   wheels stop within
    200 ms          10_000_000    0.27 s                0.5 s       as shipped
    100 ms           5_000_000    0.17 s                0.4 s
     50 ms           2_500_000    0.12 s                0.35 s

The start and stop times are worked out from the design's timers, not measured, and leave out the
robot's own reaction. The robot stops by itself after 3 s without a command, so keep the period
well under that. Below a few milliseconds nothing improves: one command takes about 2.3 ms to send.
Only 200 ms has been tried on a real robot. Leave the other parameters next to it as they are.


2. Compile
----------
Start Quartus Prime 18.1. File > Open Project, open hwtest\quartus\hwtest.qpf.
Processing > Start Compilation. It takes a few minutes and should end with "Quartus Prime Full
Compilation was successful" and 0 critical warnings; ordinary warnings are expected.
The result is hwtest\quartus\output_files\hwtest.sof.


3. Try it: until the next power-cycle, flash untouched
------------------------------------------------------
USB Blaster cable in, board powered. Tools > Programmer:
  - Hardware Setup: DE-SoC [USB-1]. Mode: JTAG.
  - Auto Detect, pick 5CSEMA5. Two devices appear: SOCVHPS and 5CSEMA5.
  - Click the 5CSEMA5 row, Change File, open output_files\hwtest.sof.
  - Tick Program/Configure on that row. Start.
Or from a Command Prompt in hwtest\quartus:

    C:\intelFPGA_lite\18.1\quartus\bin64\quartus_pgm -m jtag -o "p;output_files\hwtest.sof@2"


4. Keep it: into the flash
--------------------------
From a Command Prompt in hwtest\quartus, make the flash image:

    C:\intelFPGA_lite\18.1\quartus\bin64\quartus_cpf -c -d EPCS128 -s 5CSEMA5F31C6 output_files\hwtest.sof output_files\hwtest.jic

then write it, which takes about 70 s, and power-cycle the board:

    C:\intelFPGA_lite\18.1\quartus\bin64\quartus_pgm -m jtag -o "IPV;output_files\hwtest.jic@2"

The Programmer-window steps on page 4 of the test guide work too, with this hwtest.jic. On Linux the
same programs are in /opt/intelFPGA_lite/18.1/quartus/bin, or wherever Quartus is installed.

The new files have the same names as the ones in the test package, so rename them, for example to
hwtest-50ms.jic. To go back, flash the original hwtest.jic from the test package.


What is in here
---------------
hwtest\quartus\           the project: hwtest.qpf; hwtest.qsf, every pin; hwtest.sdc, the timing;
                          vga_sink\, the VGA Controller as Platform Designer generated it
hwtest\rtl\               the test's own modules; top_level.sv joins everything up
camera\, sonar\, ir\      the course modules it reuses
The full project, with its simulations and build scripts, is mp/hwtest in the course repository.
