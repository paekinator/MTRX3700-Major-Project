OV7670 camera on the DE1-SoC (V2026.3)
======================================

The DE1-SoC configures the OV7670 camera, captures its picture and shows it live on a VGA
monitor. The testbenches run the same design against a simulation model of the camera, so
you can test a change without a board.

The picture's path through rtl/:

    camera -> ov7670_capture -> frame_buffer -> camera_display -> vga_sink -> VGA monitor

ov7670_config sets the camera up over its control bus after every reset. The bus is SCCB, which
for writes is the same as I2C, so it uses Lesson 3's I2C master (i2c_master.sv).


Simulate
--------

    ./simulate.sh            all six benches, one after the other (about a minute in our tests)
    ./simulate.sh config     ov7670_config against the camera model
    FPS=25 ./simulate.sh config   the same with the camera at 25 frames a second (below)
    ./simulate.sh capture    ov7670_capture: every pixel of two frames checked
    ./simulate.sh buffer     frame_buffer: written at one clock, read at another
    ./simulate.sh display    camera_display into the VGA model: display_frame_*.png
    ./simulate.sh system     the whole design, pins to monitor: frame_*.png and camera.gif
    ./simulate.sh barcode    a barcode reader on the live stream: barcode_frame_*.png, barcode.gif
    ./simulate.sh handover   frame_buffer with 2 and 3 banks, at the bank handover's closest
                             timings (about 20 s; not part of "all": the top level uses one bank)

Each bench ends with a PASS or FAIL line. The camera model reports every register write it
receives, and what it did with it, in sim_ov7670_config_tb.log.

The config bench always writes waveform.fst. For the other benches add "wave", for example
./simulate.sh system wave. Open the waveform with its save file:

    gtkwave waveform.fst camera_config.gtkw      (or camera_capture.gtkw, camera_system.gtkw)

To show the camera model your own picture, run

    python3 tools/make_scene.py picture.png scene.hex

and give the testbench's ov7670_model the parameter SCENE_FILE("scene.hex").


Build (Quartus 18.1)
--------------------

Open quartus/Camera.qpf and compile it (Processing > Start Compilation). Quartus generates
the VGA system from quartus/vga_sink.qsys as part of the compile. Program
quartus/output_files/Camera.sof with the Programmer (Tools > Programmer).

The same from a Command Prompt in the quartus folder, with Quartus installed in its usual
place (change C:\intelFPGA_lite\18.1 if yours is elsewhere; @2: the FPGA is the second device
on the DE1-SoC's JTAG chain):

    C:\intelFPGA_lite\18.1\quartus\bin64\quartus_sh.exe --flow compile Camera
    C:\intelFPGA_lite\18.1\quartus\bin64\quartus_pgm.exe -m jtag -o "p;output_files/Camera.sof@2"

On Linux, with Quartus's bin folder on the PATH, cd quartus && sh build.sh compiles it and then
prints the resources, the timing slack and any critical warning.


On the board
------------

With the DE1-SoC off, connect the Robot Adaptor Board to GPIO_1, the camera's ribbon to J2
on that board (keyed plug), and a monitor to VGA. The camera uses GPIO_1[10] to GPIO_1[25];
rtl/top_level.sv lists which pin is which.

    LEDR0   on once the camera is configured (about 30 ms after reset)
    LEDR1   a register write is not being acknowledged: check the ribbon, and that XCLK
            (the clock the FPGA sends the camera) reaches it
    LEDR2   flickers while frames arrive
    KEY0    reset: configures the camera again

The camera runs at 50 frames a second. In a dim room the picture goes grey and noisy at that
rate, because a 20 ms frame is the longest the camera can expose. For a dim room, set
CAMERA_FPS = 25 at the top of rtl/top_level.sv: the camera then runs at 25 frames a second
and can expose each frame for twice as long (ov7670_config's FPS parameter halves the
camera's clock, and the banding filter's two values with it). With one frame buffer, 25
frames a second tears more on motion. In room light the two look much the same.

The register list sets MVFP (register 0x1E) to 0x37, mirror and flip, because the camera
hangs upside down on its ribbon. Held the right way up, the camera gives a picture that is
mirrored and upside down, as in the simulation's pictures. MVFP = 0x07 turns both off.

A ribbon longer than the one provided can glitch the picture, because XCLK couples onto PCLK
along it. Use the provided ribbon. The timing constraints cannot fix this: PCLK comes down the
ribbon with the data, so extra length delays both by the same amount.


Files
-----

    rtl/        the design: ov7670_config (with i2c_master and clock_divider), ov7670_capture,
                frame_buffer, camera_display, camera_pkg, video_pll and top_level
    rtl/live/   a barcode reader on the live stream (./simulate.sh barcode)
    tb/         a testbench per module, the system and barcode benches, and the models:
                ov7670_model (the camera), vga_monitor_model and vga_sink_sim
    tools/      render_frames.py and make_gif.py (the benches' pictures), make_scene.py
                (make_gif.py and make_scene.py need the Python package Pillow)
    quartus/    Camera.qpf, Camera.qsf, Camera.sdc, build.sh, vga_sink.qsys (the VGA system)
                and make_vga_sink_qsys.tcl (the script that made it)
