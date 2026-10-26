`timescale 1ns/1ps
/*
 *  top_level.sv -- the Major Project hardware test (2026): every peripheral at once, one design.
 *
 *  Camera to VGA, two ultrasonic sensors, the chassis UART both ways, the Arduino Nano UART both ways
 *  with its WiFi and supply report, and the IR remote driving the chassis, all running together so that
 *  the breakout board's rails carry everything at the same time. Stock DE1-SoC pin names; the breakout's
 *  mapping (identical on the 2025 DE1-Adaptor and the 2026 breakout) lives in this file and nowhere else.
 *
 *      GPIO_1[0]      Nano RESET (low = reset; follows KEY0)        GPIO_1[27] / [29]  ultrasonic 1 TRIG / ECHO (J3 on both boards)
 *      GPIO_1[3]      Nano TX  -> FPGA (we receive)                 GPIO_1[30] / [32]  ultrasonic 2 TRIG / ECHO (the 2025 adaptor's SPARE header J4)
 *      GPIO_1[5]      FPGA -> Nano RX (we transmit)                 GPIO_1[35] / [34]  ultrasonic 3 TRIG / ECHO (2026 board port 2; HWTEST_EXTRAS only)
 *      GPIO_1[10..25] OV7670 (PWDN, RESET#, D0..D7, XCLK, PCLK,     GPIO_1[31]         FPGA -> chassis RX (we transmit)
 *                     HREF, VSYNC, SIO_D, SIO_C)                    GPIO_1[33]         chassis TX -> FPGA (we receive)
 *                                                                   everything else    left as an input
 *
 *  The UI. KEY1 cycles what the displays show; HEX1..0 names the selection:
 *      Ar   HEX5..4  the Nano's 3.3 V rail in volts to one decimal (33 = 3.3 V; the displays have no point), the
 *                    minimum over the last second           HEX3..2  the WiFi RSSI in -dBm (00 = access-point mode / not joined)
 *      U1   HEX5..2  ultrasonic 1 (J3) in mm (4000 = nothing in range; 0000 = never measured: no sensor, or ECHO stuck high)
 *      U2   HEX5..2  ultrasonic 2 (the SPARE header) in mm
 *  LEDs, every one lit means PASS:
 *      LEDR0  camera configured (all SCCB writes acknowledged)     LEDR4  chassis talking to us (bytes arriving)
 *      LEDR1  camera frames arriving (toggles per frame)           LEDR5  Nano echo OK (steady = the link works both ways)
 *      LEDR2  ultrasonic 1 took a reading (blink per reading)      LEDR6  Nano WiFi up (joined, or its access point running)
 *      LEDR3  ultrasonic 2 took a reading                          LEDR7  Nano 3.3 V rail healthy (>= 3150 mV all last second)
 *  The remote drives the chassis, only while a key is held: CH+ fwd, CH- back, VOL- spin L, VOL+ spin R; 1..4 set the
 *  speed (0.1 / 0.2 / 0.3 / 0.5 m/s); any other key stops. With nothing held a stop is sent every 200 ms.
 *  KEY0 resets everything (re-runs the camera configuration, resets the Nano). The switches are unused.
 *
 *  HWTEST_EXTRAS (a Verilog macro: `-DHWTEST_EXTRAS` for Verilator, VERILOG_MACRO in the .qsf) brings back what is not
 *  being tested this year: ultrasonic 3 (LEDR8, selection U3), the last IR key code in hex (selection Ir, for checking
 *  the remote's key table), and the microphone (LEDR9 = the gate hears you, selection db = the level in dB).
 *
 *  Clocks: CLOCK_50 (UARTs, IR, the displays); video_pll 25 MHz (display, and /250 = the SCCB clock) and 10 MHz (camera XCLK: x4 inside the camera = 40 MHz PCLK);
 *  the camera's own PCLK (capture, frame buffer write port); sonar_pll 43.904 MHz (the sensors and their display);
 *  with the extras, adc_pll 18.432 MHz (codec MCLK) and AUD_BCLK 3.072 MHz from the codec. Each domain has its own
 *  reset synchroniser.
 */
module top_level #(
    parameter int HEARTBEAT_CLKS  = 10_000_000,  // chassis command period, CLOCK_50 clocks (200 ms)
    parameter int PROBE_CLKS      = 5_000_000,   // Nano echo probe period (100 ms)
    parameter int SONAR_PACE_CLKS = 4_390_400,   // ultrasonic period, 43.904 MHz clocks (100 ms; datasheet: > 60 ms)
    parameter int BLINK_CLKS      = 2_500_000,   // how long a reading LED stays lit (50 ms)
    parameter int KEY_LOCK_CLKS   = 1_000_000,   // KEY1 is ignored for 20 ms after a press
    parameter int DB_HOLD_SH      = 13,          // extras: the mic dB reading updates every 2^13 samples (0.17 s)
    parameter int IR_HOLD_CLKS    = 15_000_000,  // a remote key counts as held for 300 ms after its last frame or repeat code
    parameter int NANO_FRESH_CLKS = 150_000_000, // the Nano's report is trusted for 3 s (it comes once a second)
    parameter int H_RES           = 640,         // a testbench shrinks the screen to simulate quickly
    parameter int V_RES           = 480
) (
    input  wire        CLOCK_50,
    input  wire [3:0]  KEY,
    input  wire [9:0]  SW,
    output wire [9:0]  LEDR,
    output logic [6:0] HEX0, HEX1, HEX2, HEX3, HEX4, HEX5,
    inout  wire [35:0] GPIO_1,
    input  wire        IRDA_RXD,
    output wire        FPGA_I2C_SCLK,
    inout  wire        FPGA_I2C_SDAT,
    input  wire        AUD_ADCDAT,
    input  wire        AUD_BCLK,
    input  wire        AUD_ADCLRCK,
    output wire        AUD_XCK,
    output wire        VGA_CLK, VGA_HS, VGA_VS, VGA_BLANK_N, VGA_SYNC_N,
    output wire [7:0]  VGA_R, VGA_G, VGA_B
);
    // =============================================================== clocks
    wire clk_25, video_locked;
    wire clk_10;
    video_pll video_pll_u (.refclk(CLOCK_50), .rst(1'b0), .outclk_0(clk_25), .outclk_1(clk_10), .locked(video_locked));
    wire sccb_clk;
    clock_divider #(.DIVISOR(250)) sccb_clk_u (.clk_in(clk_25), .clk_out(sccb_clk));       // 100 kHz, the camera's SCCB
    wire clk_sonar, sonar_locked;
    sonar_pll sonar_pll_u (.refclk(CLOCK_50), .rst(1'b0), .outclk_0(clk_sonar), .locked(sonar_locked));

    // =============================================================== resets: KEY0 into every domain
    logic [1:0] rs50 = '0, rs25 = '0, rs_sccb = '0, rs_son = '0;
    always_ff @(posedge CLOCK_50)  rs50    <= {rs50[0],    ~KEY[0]};
    always_ff @(posedge clk_25)    rs25    <= {rs25[0],    ~KEY[0] | ~video_locked};
    always_ff @(posedge sccb_clk)  rs_sccb <= {rs_sccb[0], ~KEY[0]};
    always_ff @(posedge clk_sonar) rs_son  <= {rs_son[0],  ~KEY[0] | ~sonar_locked};
    wire reset50 = rs50[1], reset25 = rs25[1], reset_sccb = rs_sccb[1], reset_sonar = rs_son[1];

    // =============================================================== camera -> VGA  (mp/camera, unchanged modules)
    wire       cam_pclk  = GPIO_1[21];
    wire       cam_href  = GPIO_1[22];
    wire       cam_vsync = GPIO_1[23];
    wire [7:0] cam_d     = GPIO_1[19:12];
    wire       cam_reset_n, cam_pwdn, sioc;
    assign GPIO_1[20] = clk_10;          // XCLK 10 MHz; the sensor's PLL makes the 40 MHz PCLK from it (ov7670_config.sv: DBLV)
    assign GPIO_1[11] = cam_reset_n;     // RESET#
    assign GPIO_1[10] = cam_pwdn;        // PWDN
    assign GPIO_1[25] = sioc;            // SIO_C
    // GPIO_1[24] is SIO_D, driven open-drain from inside ov7670_config (pull-up on the module / the 2026 board)

    wire cfg_done, cfg_error;
    ov7670_config cfg_u (
        .clk(sccb_clk), .reset(reset_sccb), .sioc(sioc), .siod(GPIO_1[24]),
        .cam_reset_n(cam_reset_n), .cam_pwdn(cam_pwdn), .done(cfg_done), .error(cfg_error));

    wire        frame_start, px_valid;
    wire [15:0] px;
    wire [9:0]  px_x;
    wire [8:0]  px_y;
    ov7670_capture #(.INPUT_STAGE(1)) cap_u (   // pins registered once in the I/O cells (FAST_INPUT_REGISTER in the .qsf): 40 MHz margin
        .pclk(cam_pclk), .vsync(cam_vsync), .href(cam_href), .d(cam_d),
        .frame_start(frame_start), .valid(px_valid), .pixel(px), .x(px_x), .y(px_y));

    wire [8:0]  rd_x;
    wire [7:0]  rd_y;
    wire [15:0] rd_pixel;
    frame_buffer #(.W(320), .H(240), .DW(16), .DECIMATE(2), .BUFFERS(1), .PACKED(0)) fb_u (   // one 16-bit picture, as the student code ships it
        .wr_clk(cam_pclk), .wr_frame_start(frame_start), .wr_valid(px_valid), .wr_x(px_x), .wr_y(px_y), .wr_pixel(px),
        .rd_clk(clk_25), .rd_x(rd_x), .rd_y(rd_y), .rd_pixel(rd_pixel));

    wire [29:0] st_data;
    wire        st_sop, st_eop, st_valid, st_ready;
    camera_display #(.H_RES(H_RES), .V_RES(V_RES), .W(320), .H(240)) disp_u (
        .clk(clk_25), .reset(reset25), .hold_enable(1'b1), .rd_x(rd_x), .rd_y(rd_y), .rd_pixel(rd_pixel),
        .data(st_data), .startofpacket(st_sop), .endofpacket(st_eop), .valid(st_valid), .ready(st_ready));

    vga_sink vga_u (
        .clk_clk(clk_25), .reset_reset_n(~reset25),
        .video_in_data(st_data), .video_in_startofpacket(st_sop), .video_in_endofpacket(st_eop),
        .video_in_valid(st_valid), .video_in_ready(st_ready),
        .vga_CLK(VGA_CLK), .vga_HS(VGA_HS), .vga_VS(VGA_VS), .vga_BLANK(VGA_BLANK_N), .vga_SYNC(VGA_SYNC_N),
        .vga_R(VGA_R), .vga_G(VGA_G), .vga_B(VGA_B));

    logic frame_toggle = 1'b0;
    always_ff @(posedge cam_pclk) if (frame_start) frame_toggle <= ~frame_toggle;

    // =============================================================== ultrasonic sensors  (mp/sonar, unchanged modules)
    // Fired a third of the period apart (the driver listens for 23.3 ms after each trigger, so none hears
    // another's chirp). A port with nothing plugged in never measures: its ECHO floats high on the FPGA's
    // weak pull-up and the driver waits for a low ECHO before it triggers.
    logic trig1, trig2;
    assign GPIO_1[27] = trig1;  wire echo1 = GPIO_1[29];       // 1: J3 on the 2025 adaptor and the 2026 board
    assign GPIO_1[30] = trig2;  wire echo2 = GPIO_1[32];       // 2: the 2025 adaptor's SPARE header J4 (3V3, SPARE0 = TRIG, SPARE1 = ECHO, GND)

    localparam int PW = $clog2(SONAR_PACE_CLKS);
    logic [PW-1:0] pace = '0;
    logic start1 = 1'b0, start2 = 1'b0, start3 = 1'b0;
    always_ff @(posedge clk_sonar) begin
        pace   <= (pace == PW'(SONAR_PACE_CLKS - 1)) ? '0 : pace + 1'b1;
        start1 <= (pace < PW'(16));
        start2 <= (pace >= PW'(SONAR_PACE_CLKS / 3))     && (pace < PW'(SONAR_PACE_CLKS / 3 + 16));
        start3 <= (pace >= PW'(2 * SONAR_PACE_CLKS / 3)) && (pace < PW'(2 * SONAR_PACE_CLKS / 3 + 16));
    end
    logic [11:0] dist1, dist2, d1 = '0, d2 = '0;
    logic valid1, valid2;
    sonar_range u_sonar1 (.clk(clk_sonar), .start_measure(start1), .rst(reset_sonar), .echo(echo1), .trig(trig1), .distance(dist1), .ready(), .valid(valid1));
    sonar_range u_sonar2 (.clk(clk_sonar), .start_measure(start2), .rst(reset_sonar), .echo(echo2), .trig(trig2), .distance(dist2), .ready(), .valid(valid2));
    always_ff @(posedge clk_sonar) begin
        if (valid1) d1 <= dist1;
        if (valid2) d2 <= dist2;
    end
    wire sonar_blink1, sonar_blink2;                 // a 1-clock pulse in another domain: 43.9 MHz vs 50 MHz, 22.8 ns wide, always seen
    pulse_stretch #(.CLKS(BLINK_CLKS)) u_sonar_blink1 (.clk(CLOCK_50), .trigger(valid1), .q(sonar_blink1));
    pulse_stretch #(.CLKS(BLINK_CLKS)) u_sonar_blink2 (.clk(CLOCK_50), .trigger(valid2), .q(sonar_blink2));
`ifdef HWTEST_EXTRAS
    logic trig3;
    assign GPIO_1[35] = trig3;  wire echo3 = GPIO_1[34];       // 3: the 2026 board's second port J4
    logic [11:0] dist3, d3 = '0;
    logic valid3;
    sonar_range u_sonar3 (.clk(clk_sonar), .start_measure(start3), .rst(reset_sonar), .echo(echo3), .trig(trig3), .distance(dist3), .ready(), .valid(valid3));
    always_ff @(posedge clk_sonar) if (valid3) d3 <= dist3;
    wire sonar_blink3;
    pulse_stretch #(.CLKS(BLINK_CLKS)) u_sonar_blink3 (.clk(CLOCK_50), .trigger(valid3), .q(sonar_blink3));
`endif

    // =============================================================== chassis UART
    // The IR remote drives, while a motion key is held (ir_drive.sv); with nothing held every heartbeat is a stop.
    wire       ir_active;
    wire [1:0] ir_motion, ir_speed;
    wire       chassis_tx, chassis_busy;
    chassis_command #(.CLKS_PER_BIT(434), .PERIOD_CLKS(HEARTBEAT_CLKS)) chassis_u (
        .clk(CLOCK_50), .reset(reset50),
        .armed(ir_active), .motion(ir_motion), .speed(ir_speed), .feedback(1'b0),        // the UGV02 streams telemetry unasked; the request is not needed
        .tx(chassis_tx), .busy(chassis_busy));
    assign GPIO_1[31] = chassis_tx;
    logic [7:0] chassis_rx_byte;
    logic       chassis_rx_valid, chassis_rx_fe;
    uart_rx #(.CLKS_PER_BIT(434), .BITS_N(8), .PARITY_TYPE(0)) chassis_rx_u (
        .clk(CLOCK_50), .rst(reset50), .rx(GPIO_1[33]), .data_rx(chassis_rx_byte), .valid(chassis_rx_valid), .ready(1'b1),
        .parity_error(), .framing_error(chassis_rx_fe));
    wire chassis_rx_act;
    pulse_stretch #(.CLKS(BLINK_CLKS)) u_crx_act (.clk(CLOCK_50), .trigger(chassis_rx_valid & ~chassis_rx_fe), .q(chassis_rx_act));

    // =============================================================== Arduino Nano UART: the echo, and the WiFi / supply report
    wire nano_tx, nano_echo_ok, nano_rx_valid;
    wire [7:0] nano_rx_byte;
    nano_probe #(.CLKS_PER_BIT(434), .PERIOD_CLKS(PROBE_CLKS)) nano_u (
        .clk(CLOCK_50), .reset(reset50), .rx(GPIO_1[3]), .tx(nano_tx),
        .echo_ok(nano_echo_ok), .rx_valid(nano_rx_valid), .rx_byte(nano_rx_byte));
    assign GPIO_1[5] = nano_tx;
    assign GPIO_1[0] = ~reset50;                 // the Nano's RESET: held low while KEY0 is pressed. Two presses within 0.5 s are
                                                 // the SAMD bootloader's double-tap: the Nano then waits in bootloader mode
                                                 // (LEDR5..7 off) until the next single press
    wire [6:0]  nano_rssi;
    wire [11:0] nano_mv;
    wire [7:0]  nano_mode;
    wire        nano_seen;
    nano_report u_report (.clk(CLOCK_50), .reset(reset50), .rx_valid(nano_rx_valid), .rx_byte(nano_rx_byte),
        .rssi(nano_rssi), .mv(nano_mv), .mode(nano_mode), .seen(nano_seen));
    localparam int FW = $clog2(NANO_FRESH_CLKS + 1);
    logic [FW-1:0] fresh = '0;                                   // counts down from the last report
    always_ff @(posedge CLOCK_50) if (nano_seen) fresh <= FW'(NANO_FRESH_CLKS); else if (fresh != 0) fresh <= fresh - 1'b1;
    wire nano_fresh   = (fresh != 0);
    wire nano_wifi_up = nano_fresh && (nano_mode == "S" || nano_mode == "A" || nano_mode == "C");
    wire nano_rail_ok = nano_fresh && (nano_mv >= 12'd3150);

    // =============================================================== IR remote: the course's NEC decoder into the dead-man control
    wire        nec_valid, nec_repeat;
    wire [31:0] nec_code;
    nec_decoder #(.CLK_HZ(50_000_000)) u_nec (.clk(CLOCK_50), .rst(reset50), .ir(IRDA_RXD), .valid(nec_valid), .code(nec_code), .repeat_code(nec_repeat));
    ir_drive #(.HOLD_CLKS(IR_HOLD_CLKS)) u_ir_drive (.clk(CLOCK_50), .reset(reset50), .valid(nec_valid), .repeat_code(nec_repeat), .code(nec_code),
        .active(ir_active), .motion(ir_motion), .speed(ir_speed));
`ifdef HWTEST_EXTRAS
    wire        ir_ready;                        // Terasic's decoder too, for the key-code view (selection Ir)
    wire [31:0] ir_code;
    IR_RECEIVE u_ir (.iCLK(CLOCK_50), .iRST_n(~reset50), .iIRDA(IRDA_RXD), .oDATA_READY(ir_ready), .oDATA(ir_code));
    logic ir_seen = 1'b0;
    always_ff @(posedge CLOCK_50) if (reset50) ir_seen <= 1'b0; else if (ir_ready) ir_seen <= 1'b1;
    wire [6:0] ir_seg0, ir_seg1;
    hex_digit h0 (.d(ir_code[19:16]), .blank(~ir_seen), .seg(ir_seg0));
    hex_digit h1 (.d(ir_code[23:20]), .blank(~ir_seen), .seg(ir_seg1));
`endif

    // =============================================================== microphone  (extras: Lesson 3 modules + the A2 gate)
`ifdef HWTEST_EXTRAS
    wire adc_clk;
    adc_pll adc_pll_u (.refclk(CLOCK_50), .rst(1'b0), .outclk_0(adc_clk), .locked());
    assign AUD_XCK = adc_clk;                                                              // 18.432 MHz to the codec
    wire i2c_clk;
    clock_divider #(.DIVISOR(500)) i2c_clk_u (.clk_in(CLOCK_50), .clk_out(i2c_clk));       // 100 kHz, the codec's I2C
    logic [1:0] rs_aud = '0;
    always_ff @(posedge AUD_BCLK) rs_aud <= {rs_aud[0], ~KEY[0]};
    wire reset_aud = rs_aud[1];
    set_audio_encoder set_codec_u (.i2c_clk(i2c_clk), .I2C_SCLK(FPGA_I2C_SCLK), .I2C_SDAT(FPGA_I2C_SDAT));
    logic [15:0] sample;
    logic        sample_valid;
    mic_load #(.N(16)) mic_load_u (.bclk(AUD_BCLK), .adclrc(AUD_ADCLRCK), .adcdat(AUD_ADCDAT), .valid(sample_valid), .sample_data(sample));
    logic [7:0] level;
    logic [6:0] snr_db, level_db;
    logic       voice_active;
    gate #(.W(16), .DB_HOLD_SH(DB_HOLD_SH)) u_gate (.clk(AUD_BCLK), .reset(reset_aud), .sample_valid(sample_valid), .sample(sample),
        .level(level), .snr_db(snr_db), .level_db(level_db), .voice_active(voice_active));
    wire [6:0] db_seg0, db_seg1;
    display #(.VALUE_WIDTH(7), .DIGITS(4)) u_db_display (.clk(AUD_BCLK), .value(level_db),
        .display0(db_seg0), .display1(db_seg1), .display2(), .display3());
    logic [1:0] va_sync = '0;
    always_ff @(posedge CLOCK_50) va_sync <= {va_sync[0], voice_active};
`else
    assign AUD_XCK       = 1'b0;                 // the codec sleeps: no clock, its I2C idle
    assign FPGA_I2C_SCLK = 1'b1;
    assign FPGA_I2C_SDAT = 1'bz;
`endif

    // =============================================================== the UI: KEY1 cycles the selection
`ifdef HWTEST_EXTRAS
    localparam int N_SEL = 6;                    // Ar, U1, U2, U3, Ir, db
`else
    localparam int N_SEL = 3;                    // Ar, U1, U2
`endif
    localparam int LW = $clog2(KEY_LOCK_CLKS + 1);
    logic [2:0]    k1 = 3'b111;                  // KEY1 synchronised; it is active low
    logic [LW-1:0] key_lock = '0;
    logic [2:0]    sel = 3'd0;
    always_ff @(posedge CLOCK_50) begin
        k1 <= {k1[1:0], KEY[1]};
        if (reset50) begin sel <= 3'd0; key_lock <= '0; end
        else if (k1[2] & ~k1[1] & (key_lock == 0)) begin
            sel      <= (sel == 3'(N_SEL - 1)) ? 3'd0 : sel + 1'b1;
            key_lock <= LW'(KEY_LOCK_CLKS);
        end else if (key_lock != 0) key_lock <= key_lock - 1'b1;
    end

    // the ultrasonic reading for the selection, in the sonar clock (the selection changes rarely; a 2-flop copy is enough)
    logic [2:0] sel_s0 = '0, sel_s = '0;
    always_ff @(posedge clk_sonar) begin sel_s0 <= sel; sel_s <= sel_s0; end
    logic [11:0] shown;
    always_comb begin
        shown = d1;
        if (sel_s == 3'd2) shown = d2;
`ifdef HWTEST_EXTRAS
        if (sel_s == 3'd3) shown = d3;
`endif
    end
    wire [6:0] s_seg0, s_seg1, s_seg2, s_seg3, v_seg0, v_seg1, v_seg2, v_seg3, r_seg0, r_seg1;
    display #(.VALUE_WIDTH(12), .DIGITS(4)) u_sonar_display (.clk(clk_sonar), .value(shown),
        .display0(s_seg0), .display1(s_seg1), .display2(s_seg2), .display3(s_seg3));
    display #(.VALUE_WIDTH(13), .DIGITS(4)) u_volt_display (.clk(CLOCK_50), .value(13'(nano_mv) + 13'd50),   // + 50 mV: rounded, not truncated,
        .display0(v_seg0), .display1(v_seg1), .display2(v_seg2), .display3(v_seg3));                        //  to one decimal in digits 3 and 2
    display #(.VALUE_WIDTH(7), .DIGITS(4)) u_rssi_display (.clk(CLOCK_50), .value(nano_rssi),
        .display0(r_seg0), .display1(r_seg1), .display2(), .display3());

    // letters on a seven-segment display (segments g f e d c b a, active low)
    localparam logic [6:0] SEG_A = 7'b0001000, SEG_R = 7'b0101111, SEG_U = 7'b1000001, SEG_1 = 7'b1111001, SEG_2 = 7'b0100100,
                           SEG_3 = 7'b0110000, SEG_I = 7'b1111001, SEG_D = 7'b0100001, SEG_B = 7'b0000011, SEG_OFF = 7'b1111111;
    always_comb begin
        {HEX5, HEX4, HEX3, HEX2} = {s_seg3, s_seg2, s_seg1, s_seg0};
        {HEX1, HEX0} = {SEG_U, SEG_1};
        case (sel)
            3'd0: begin {HEX5, HEX4, HEX3, HEX2} = {v_seg3, v_seg2, r_seg1, r_seg0}; {HEX1, HEX0} = {SEG_A, SEG_R}; end   // Ar: 3.3 V and -45 dBm as "33 45"
            3'd1: {HEX1, HEX0} = {SEG_U, SEG_1};
            3'd2: {HEX1, HEX0} = {SEG_U, SEG_2};
`ifdef HWTEST_EXTRAS
            3'd3: {HEX1, HEX0} = {SEG_U, SEG_3};
            3'd4: begin {HEX5, HEX4, HEX3, HEX2} = {SEG_OFF, SEG_OFF, ir_seg1, ir_seg0}; {HEX1, HEX0} = {SEG_I, SEG_R}; end   // Ir: the last key code
            3'd5: begin {HEX5, HEX4, HEX3, HEX2} = {SEG_OFF, SEG_OFF, db_seg1, db_seg0}; {HEX1, HEX0} = {SEG_D, SEG_B}; end   // db: the mic level
`endif
            default: ;
        endcase
    end

`ifdef HWTEST_EXTRAS
    assign LEDR = {va_sync[1], sonar_blink3, nano_rail_ok, nano_wifi_up, nano_echo_ok, chassis_rx_act,
                   sonar_blink2, sonar_blink1, frame_toggle, cfg_done};
`else
    assign LEDR = {2'b00, nano_rail_ok, nano_wifi_up, nano_echo_ok, chassis_rx_act,
                   sonar_blink2, sonar_blink1, frame_toggle, cfg_done};
`endif
endmodule
