`timescale 1ns/1ps
/*
 *  camera_system_tb -- the whole camera project, pins to monitor.
 *
 *      OV7670 model --GPIO_1[10..25]--> top_level (PLL, SCCB config, capture, frame buffer,
 *      display) --Avalon-ST--> vga_sink (VGA Controller + monitor model) --> frame_<n>.png
 *
 *  The model watches the "shapes" scene and the bench pans it between camera frames, so the
 *  monitor frames show the world moving: tools/make_gif.py turns them into camera.gif.
 *  The first 30 ms or so are the configuration; the picture on the monitor is whatever the buffer
 *  holds until the first configured frame has been written. PASS: the model accepted the
 *  configuration (check_course_config), no VGA or SCCB protocol errors, LEDR0 on and LEDR1 off,
 *  and at least n_frames monitor frames after the camera's first configured frame. The picture
 *  itself is in frame_*.png.
 *
 *  Run:  ./simulate.sh system        (about 20 s in our tests). For more frames or another pan, run
 *        ./obj_dir/Vcamera_system_tb +frames=<n> +pan=<px> after it, then python3 tools/render_frames.py.
 */
module camera_system_tb;
    logic CLOCK_50 = 0; always #10 CLOCK_50 = ~CLOCK_50;
    logic [3:0] KEY = 4'b1111;
    wire  [9:0] LEDR;
    wire  [35:0] GPIO_1;
    wire  VGA_CLK, VGA_HS, VGA_VS, VGA_BLANK_N, VGA_SYNC_N; wire [7:0] VGA_R, VGA_G, VGA_B;

    top_level dut (.CLOCK_50, .KEY, .LEDR, .GPIO_1, .VGA_CLK, .VGA_HS, .VGA_VS, .VGA_BLANK_N, .VGA_SYNC_N, .VGA_R, .VGA_G, .VGA_B);

    // ---- the camera on the other end of the ribbon ----
    wire pclk, vsync, href; wire [7:0] d;
    assign GPIO_1[21] = pclk; assign GPIO_1[22] = href; assign GPIO_1[23] = vsync; assign GPIO_1[19:12] = d;
    pullup(GPIO_1[24]);                       // SIO_D pull-up (the SCCB data line is open-drain)
    int frames_done, write_count, error_count;
    int scene_x0 = 0, scene_y0 = 0, pan = 24, n_frames = 4;
    ov7670_model #(.VERBOSE(1)) cam (
        .sio_c(GPIO_1[25]), .sio_d(GPIO_1[24]), .xclk(GPIO_1[20]), .reset_n(GPIO_1[11]), .pwdn(GPIO_1[10]),
        .pclk(pclk), .vsync(vsync), .href(href), .d(d),
        .scene_mode(1), .scene_x0(scene_x0), .scene_y0(scene_y0), .scene_code(8'hA5),
        .frames_done(frames_done), .write_count(write_count), .error_count(error_count));

    // pan the scene once per camera frame
    always @(posedge vsync) if (dut.cfg_done) scene_x0 <= scene_x0 + pan;

    int fails = 0, problems, first_cfg_frame = -1, mon_frames_at_cfg = -1;
    initial begin
        if ($value$plusargs("frames=%d", n_frames)) ;
        if ($value$plusargs("pan=%d", pan)) ;
        `ifdef VERILATOR
        if ($test$plusargs("wave")) begin $dumpfile("waveform.fst"); $dumpvars(0, dut.cfg_u); $dumpvars(0, dut.cap_u); $dumpvars(0, dut.disp_u); end
        `else
        $dumpfile("waveform.vcd"); $dumpvars(0, dut.cap_u);
        `endif
        #200ns KEY[0] = 0; #30us KEY[0] = 1;         // press KEY0 for longer than one SCCB clock (10 us)
        fork
            wait (dut.cfg_done);
            begin #60ms; $display("FAIL: the camera was not configured within 60 ms"); $display("FAILED: 1 problem"); $finish; end
        join_any
        disable fork;
        $display("[tb @%0t] camera configured; LEDR = %b", $time, LEDR);
        problems = cam.check_course_config(1, 640, 480);
        if (problems != 0) begin fails++; $display("FAIL: the model found %0d problem(s) with the configuration", problems); end
        // wait for the first camera frame that starts after configuration, then for it to be written
        @(posedge vsync); first_cfg_frame = frames_done; @(posedge vsync);
        mon_frames_at_cfg = dut.vga_u.frames_done;
        fork
            wait (dut.vga_u.frames_done >= mon_frames_at_cfg + n_frames);
            begin #300ms; $display("FAIL: only %0d monitor frames in 300 ms", dut.vga_u.frames_done - mon_frames_at_cfg); $display("FAILED: 1 problem"); $finish; end
        join_any
        disable fork;
        #1us;
        $display("[tb @%0t] %0d camera frames, %0d monitor frames, VGA protocol errors %0d, SCCB errors %0d", $time, frames_done, dut.vga_u.frames_done, dut.vga_u.errors, error_count);
        if (dut.vga_u.errors != 0) begin fails++; $display("FAIL: %0d Avalon-ST protocol errors at the VGA Controller", dut.vga_u.errors); end
        if (error_count != 0) begin fails++; $display("FAIL: %0d SCCB protocol errors", error_count); end
        if (!LEDR[0] || LEDR[1]) begin fails++; $display("FAIL: LEDR0 (configured) = %0d, LEDR1 (error) = %0d", LEDR[0], LEDR[1]); end
        cam.print_summary();
        if (fails == 0) $display("PASS: camera -> capture -> frame buffer -> display -> monitor: %0d frames drawn after configuration, no errors; see frame_*.png / camera.gif", n_frames);
        else $display("FAILED: %0d problem(s)", fails);
        $finish;
    end
endmodule
