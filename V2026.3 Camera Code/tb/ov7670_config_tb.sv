`timescale 1ns/1ps
/*
 *  ov7670_config_tb -- the configuration sequence against the camera model.
 *
 *  ov7670_config drives RESET#, waits, and sends its register list over the SCCB at 100 kHz;
 *  the camera model on the other end decodes every transaction, drops anything that arrives
 *  inside the 1 ms settling time after a reset, and at the end says what state it is in.
 *  PASS needs: every write acknowledged and accepted (none dropped, no protocol errors), `done`
 *  high, and risen only once the last write had been acknowledged, and the model's
 *  check_course_config() finding nothing wrong (RGB565, 640x480). The video port is running
 *  throughout; the bench only watches the frame counter.
 *
 *  Part 2, once part 1 is over: a second ov7670_config and camera model (dut2, cam2), with the
 *  model refusing three writes once each (cam2.ctrl.refuse): the software reset, COM15 and the
 *  last entry. Each must be sent again before anything else: cam2 must accept the same writes in
 *  the same order as cam did in part 1, and done2 must wait for the last one. The waveform holds
 *  part 1 only: Verilator traces the whole design whatever $dumpvars names, and ignores $dumpoff,
 *  so the second pair is left untraced and the first camera's XCLK stops when part 1 is over.
 *
 *  Run:  ./simulate.sh config
 *  At 25 frames a second (ov7670_config's FPS, top_level.sv's CAMERA_FPS):  FPS=25 ./simulate.sh config
 *  The bench then expects a 20 MHz PCLK, 25 fps and the banding filter's values for a 78.4 us line.
 */
module ov7670_config_tb;
    // The frame rate the camera code is built for. FPS=25 ./simulate.sh config defines CAMERA_FPS as 25, and the bench
    // gives ov7670_config FPS = 25 and expects its clock; without it, ov7670_config keeps its default, 50.
`ifdef CAMERA_FPS
    localparam int FPS = `CAMERA_FPS;
    `define CONFIG_FPS #(.FPS(`CAMERA_FPS))
`else
    localparam int FPS = 50;
    `define CONFIG_FPS
`endif

    // 25 MHz (for the SCCB divider, as on the board), the 10 MHz camera clock (XCLK: x4 inside the camera = 40 MHz PCLK) and the 100 kHz SCCB bit clock
    logic clk_25 = 0;   always #20 clk_25 = ~clk_25;
    logic clk_10 = 0;   always #50 clk_10 = ~clk_10;
    logic sccb_clk;
    clock_divider #(.DIVISOR(250)) div_u (.clk_in(clk_25), .clk_out(sccb_clk));

    logic reset = 1;
    wire  sioc, siod;   pullup(siod);
    wire  cam_reset_n, cam_pwdn, done, error;
    ov7670_config `CONFIG_FPS dut (.clk(sccb_clk), .reset(reset), .sioc(sioc), .siod(siod),
                                  .cam_reset_n(cam_reset_n), .cam_pwdn(cam_pwdn), .done(done), .error(error));

    wire pclk, vsync, href; wire [7:0] d;
    int frames_done, write_count, error_count;
    logic xclk_on = 1;
    ov7670_model #(.VERBOSE(1)) cam (
        .sio_c(sioc), .sio_d(siod), .xclk(clk_10 & xclk_on), .reset_n(cam_reset_n), .pwdn(cam_pwdn),
        .pclk(pclk), .vsync(vsync), .href(href), .d(d),
        .scene_mode(1), .scene_x0(0), .scene_y0(0), .scene_code(8'hA5),
        .frames_done(frames_done), .write_count(write_count), .error_count(error_count));

    // part 2's pair, held in reset until part 1 is over, and left out of the waveform
    /*verilator tracing_off*/
    logic reset2 = 1;
    wire  sioc2, siod2;   pullup(siod2);
    wire  cam_reset_n2, cam_pwdn2, done2, error2;
    ov7670_config `CONFIG_FPS dut2 (.clk(sccb_clk), .reset(reset2), .sioc(sioc2), .siod(siod2),
                                   .cam_reset_n(cam_reset_n2), .cam_pwdn(cam_pwdn2), .done(done2), .error(error2));
    wire pclk2, vsync2, href2; wire [7:0] d2;
    int frames_done2, write_count2, error_count2;
    ov7670_model #(.VERBOSE(1)) cam2 (
        .sio_c(sioc2), .sio_d(siod2), .xclk(clk_10), .reset_n(cam_reset_n2), .pwdn(cam_pwdn2),
        .pclk(pclk2), .vsync(vsync2), .href(href2), .d(d2),
        .scene_mode(1), .scene_x0(0), .scene_y0(0), .scene_code(8'hA5),
        .frames_done(frames_done2), .write_count(write_count2), .error_count(error_count2));
    /*verilator tracing_on*/

    // `done` means every write has been acknowledged: when it rises, the model must already have all of them
    int writes_at_done = -1, writes_at_done2 = -1; realtime t_done = 0, t_done2 = 0;
    always @(posedge done)  begin writes_at_done  = write_count;  t_done  = $realtime; end
    always @(posedge done2) begin writes_at_done2 = write_count2; t_done2 = $realtime; end

    int fails = 0, problems, frames1;
    realtime t1, t_rel1, t_rel2; real pclk1;
    initial begin
        `ifdef VERILATOR
        $dumpfile("waveform.fst"); $dumpvars(0, dut); $dumpvars(0, cam.ctrl);
        `else
        $dumpfile("waveform.vcd"); $dumpvars(0, dut); $dumpvars(0, cam.ctrl);
        `endif
        repeat (3) @(posedge sccb_clk); reset = 0; t_rel1 = $realtime;
        // the whole sequence: 1 ms reset + 2 ms settle + the reset write + 2 ms + 77 writes x 0.32 ms, about 30 ms
        fork
            begin wait (done); end
            begin #40ms; $display("FAIL: configuration not finished after 40 ms (state %s, index %0d)", dut.state.name(), dut.index); fails++; end
        join_any
        disable fork;
        #1ms;
        $display("");
        cam.print_summary();
        problems = cam.check_course_config(1, 640, 480);
        if (problems != 0)              begin fails++; $display("FAIL: the model found %0d problem(s) with the configuration", problems); end
        if (!done)                      begin fails++; $display("FAIL: done is not high"); end
        if (error)                      begin fails++; $display("FAIL: error is high (the last write was not acknowledged)"); end
        if (cam.ctrl.dropped_count != 0) begin fails++; $display("FAIL: %0d write(s) arrived inside the settle time after a reset and were dropped", cam.ctrl.dropped_count); end
        if (error_count != 0)           begin fails++; $display("FAIL: the model counted %0d protocol error(s)", error_count); end
        if (write_count != dut.N)       begin fails++; $display("FAIL: the model accepted %0d writes, the ROM has %0d", write_count, dut.N); end
        if (writes_at_done != dut.N)    begin fails++; $display("FAIL: done rose when the model had accepted %0d of the %0d writes: it must wait for the last one", writes_at_done, dut.N); end
        else $display("  ok: done rose at %0.2f ms, after the last write had been acknowledged", t_done / 1ms);
        if (cam.ctrl.reset_count != 2)  begin fails++; $display("FAIL: expected a hardware reset (RESET# released) and a software reset (COM7[7]); the model saw %0d", cam.ctrl.reset_count); end
        t1 = $realtime; frames1 = frames_done; pclk1 = cam.video.pclk_hz;
        if (FPS == 25) begin            // the prescaler at /2: half the clock, and the banding filter's lines halved with it
            if (pclk1 < 19.9e6 || pclk1 > 20.1e6) begin fails++; $display("FAIL: PCLK is %0.1f MHz, expected 20.0 at FPS 25 (XCLK 10 MHz, the sensor's PLL x4, prescaler /2: CLKRC 0x81)", pclk1 / 1e6); end
            if (cam.video.fps < 24.9 || cam.video.fps > 25.1) begin fails++; $display("FAIL: %0.1f frames a second, expected 25.0 at FPS 25", cam.video.fps); end
            if (cam.regs[8'h9D] != 8'h80 || cam.regs[8'h9E] != 8'h6A) begin fails++; $display("FAIL: BD50ST = 0x%02X, BD60ST = 0x%02X; at FPS 25 a line takes 78.4 us, so 10 ms is 128 lines (0x80) and 8.33 ms 106 (0x6A)", cam.regs[8'h9D], cam.regs[8'h9E]); end
            if (fails == 0) $display("  ok: FPS 25: PCLK %0.1f MHz, %0.1f fps, BD50ST 0x%02X and BD60ST 0x%02X for a 78.4 us line", pclk1 / 1e6, cam.video.fps, cam.regs[8'h9D], cam.regs[8'h9E]);
        end else
            if (pclk1 < 39.9e6 || pclk1 > 40.1e6) begin fails++; $display("FAIL: PCLK is %0.1f MHz, expected 40.0 (XCLK 10 MHz, the sensor's PLL x4, prescaler /1, CLKRC bit 7 set)", pclk1 / 1e6); end
        xclk_on = 0;                    // the first camera is done with: its video port stops, and so does the waveform

        // ---- part 2: the second pair, with three writes refused once each ----
        cam2.ctrl.refuse[8'h12] = 1;    // the next write to COM7: the software reset, the first entry
        cam2.ctrl.refuse[8'h40] = 1;    // COM15, in the middle
        cam2.ctrl.refuse[8'h78] = 1;    // 0x78, the last entry
        @(posedge sccb_clk); reset2 = 0; t_rel2 = $realtime;
        fork
            begin wait (done2); end
            begin #40ms; $display("FAIL: part 2: configuration not finished after 40 ms (state %s, index %0d)", dut2.state.name(), dut2.index); fails++; end
        join_any
        disable fork;
        #1ms;
        if (cam2.ctrl.nack_count != 3)  begin fails++; $display("FAIL: part 2: the model refused %0d write(s), not 3", cam2.ctrl.nack_count); end
        if (write_count2 != dut2.N)     begin fails++; $display("FAIL: part 2: the model accepted %0d writes, the ROM has %0d: a refused write must be sent again", write_count2, dut2.N); end
        else if (write_count == dut.N) begin
            for (int i = 0; i < dut2.N; i++)
                if (cam2.ctrl.log_reg[i] != cam.ctrl.log_reg[i] || cam2.ctrl.log_val[i] != cam.ctrl.log_val[i]) begin
                    fails++;
                    $display("FAIL: part 2: write %0d was 0x%02X <= 0x%02X, in part 1 it was 0x%02X <= 0x%02X: a refused write must be sent again before the next one",
                             i + 1, cam2.ctrl.log_reg[i], cam2.ctrl.log_val[i], cam.ctrl.log_reg[i], cam.ctrl.log_val[i]);
                    break;
                end
        end
        if (cam2.ctrl.reset_count != 2) begin fails++; $display("FAIL: part 2: the model saw %0d reset(s), not 2: a refused software reset must be sent again", cam2.ctrl.reset_count); end
        if (writes_at_done2 != dut2.N)  begin fails++; $display("FAIL: part 2: done rose when the model had accepted %0d of the %0d writes: it must wait for the last one", writes_at_done2, dut2.N); end
        if (!done2 || error2)           begin fails++; $display("FAIL: part 2: done = %0d, error = %0d at the end", done2, error2); end
        if (cam2.ctrl.dropped_count != 0 || error_count2 != 0) begin fails++; $display("FAIL: part 2: %0d dropped write(s), %0d protocol error(s)", cam2.ctrl.dropped_count, error_count2); end
        if (fails == 0) $display("  ok: part 2: COM7 (the software reset), COM15 and 0x78 (the last entry) refused once each and each sent again at once; done %0.2f ms after reset (part 1: %0.2f)",
                                 (t_done2 - t_rel2) / 1ms, (t_done - t_rel1) / 1ms);
        if (fails == 0) $display("PASS: camera configured in %0.1f ms, %0d writes accepted, none dropped, RGB565 640x480 at %0.1f MHz PCLK; %0d frame(s) output meanwhile",
                                 t_done / 1ms, write_count, pclk1 / 1e6, frames1);
        else $display("FAILED: %0d problem(s)", fails);
        $finish;
    end
endmodule
