`timescale 1ns/1ps
/*
 *  chassis_drive.sv -- drive the UGV02: {"T":11,"L":<left>,"R":<right>} on its UART, every PERIOD_MS.
 *
 *  The UGV02 takes one line of JSON per command on its UART: 115200 baud, 8 data bits, no parity,
 *  one stop bit. T:11 sets the PWM of the left and the right motors, from -255 (full speed
 *  backwards) to 255 (full speed forwards), and the robot keeps driving at those settings until the
 *  next command. It stops by itself 3 s after the last command, so this module sends the command
 *  again every PERIOD_MS whether or not it changed: the robot keeps going while enable is high, and
 *  stops within 3 s if the commands stop (the FPGA is reset, reprogrammed or unplugged).
 *
 *      enable = 0     {"T":11,"L":0,"R":0}               stop
 *      enable = 1     {"T":11,"L":<left>,"R":<right>}    each clamped to -255 .. 255
 *
 *  left and right are taken when a command starts, so one command never mixes two settings. They go
 *  through two registers first (the inputs, then the command's text), so the arithmetic that turns a
 *  number into digits has a clock cycle of its own, whatever logic drives left and right.
 *  Each number goes out as a sign and three digits, right-aligned, with a NUL (byte 0) in every
 *  place it does not use. The sender skips the NULs, so 51 arrives as "51" and -7 as "-7".
 *
 *  Why T:11 and not T:1 (speed in m/s): the lab's robots run two firmwares. On the 0.96 firmware T:1
 *  is a PID speed controller that surges and stalls below about 0.2 m/s; T:11 sets the motor PWM
 *  directly on both, so the command means the same on every robot. To convert a speed: multiply m/s
 *  by 512, round and clamp, which is what T:1 does on the 0.90 firmware. How fast a PWM really drives
 *  a robot depends on the robot and its battery: measure it.
 */
module chassis_drive #(
    parameter int CLK_HZ    = 50_000_000,   // the clock this module runs on
    parameter int BAUD      = 115_200,      // the UGV02's UART
    parameter int PERIOD_MS = 100           // one command every PERIOD_MS (the robot stops 3 s after the last)
) (
    input  logic              clk,
    input  logic              reset,        // synchronous, active high
    input  logic              enable,       // 0: send stops
    input  logic signed [9:0] left,         // PWM of the left motor, -255 .. 255 (beyond that, clamped)
    input  logic signed [9:0] right,        // PWM of the right motor
    output logic              tx,           // to the chassis's RX: GPIO_1[31] on the Robot Adaptor Board
    output logic              busy          // high while a command is going out
);
    localparam int CLKS_PER_BIT = (CLK_HZ + BAUD / 2) / BAUD;     // 434 at 50 MHz
    localparam int PERIOD_CLKS  = CLK_HZ / 1000 * PERIOD_MS;
    localparam int LEN          = 27;                              // bytes in the layout, NULs included

    // 1. A PWM as text: a sign byte ("-" or NUL) and three digit bytes, with NUL for a leading zero.
    function automatic logic [31:0] pwm_text(input logic signed [9:0] v);
        logic [7:0] a, d2, d1, d0;
        if (v > 10'sd255 || v < -10'sd255) a = 8'd255;
        else if (v < 0)                     a = 8'(-v);
        else                                a = 8'(v);
        d2 = a / 8'd100;
        d1 = (a / 8'd10) % 8'd10;
        d0 = a % 8'd10;
        return {(v < 0) ? 8'h2D : 8'h00,                      // "-"
                (d2 != 0)            ? 8'h30 + d2 : 8'h00,   // "0" + digit
                (d2 != 0 || d1 != 0) ? 8'h30 + d1 : 8'h00,
                8'h30 + d0};
    endfunction

    // 2. The whole command in LEN bytes.
    localparam logic [8*12-1:0] P1 = "{\"T\":11,\"L\":";
    localparam logic [8*5-1:0]  P2 = ",\"R\":";
    localparam logic [8*2-1:0]  P3 = "}\n";
    function automatic logic [8*LEN-1:0] command(input logic en, input logic signed [9:0] l, input logic signed [9:0] r);
        return {P1, pwm_text(en ? l : 10'sd0), P2, pwm_text(en ? r : 10'sd0), P3};
    endfunction

    // 3. The inputs, registered, and the command's text a clock later.
    logic              en_q = 1'b0;
    logic signed [9:0] left_q = '0, right_q = '0;
    logic [8*LEN-1:0]  text_q = '0;
    always_ff @(posedge clk) begin
        en_q    <= enable;
        left_q  <= left;
        right_q <= right;
        text_q  <= command(en_q, left_q, right_q);
    end

    // 4. One command every PERIOD_CLKS.
    localparam int TW = $clog2(PERIOD_CLKS);
    logic [TW-1:0] timer = '0;
    logic tick;
    assign tick = (timer == TW'(PERIOD_CLKS - 1));
    always_ff @(posedge clk)
        timer <= (reset || tick) ? '0 : timer + 1'b1;

    // 5. Send it, one byte per uart_tx handshake, skipping the NULs.
    logic [8*LEN-1:0] shreg = '0;
    logic [4:0]       remaining = '0;                             // bytes still in shreg, NULs included
    logic             tx_valid = 1'b0, tx_ready;
    uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT), .BITS_N(8), .PARITY_TYPE(0)) uart_u (
        .clk(clk), .rst(reset), .data_tx(shreg[8*LEN-1 -: 8]), .valid(tx_valid), .uart_out(tx), .ready(tx_ready));

    always_ff @(posedge clk) begin
        if (reset) begin
            remaining <= '0;
            tx_valid  <= 1'b0;
        end else if (remaining == 0) begin
            if (tick) begin                                       // start a command
                shreg     <= text_q;
                remaining <= 5'(LEN);
            end
        end else if (!tx_valid) begin
            if (shreg[8*LEN-1 -: 8] == 8'h00) begin               // a NUL: not sent
                shreg     <= shreg << 8;
                remaining <= remaining - 1'b1;
            end else if (tx_ready)
                tx_valid <= 1'b1;
        end else if (tx_ready) begin                              // handshake: uart_tx has taken this byte
            tx_valid  <= 1'b0;
            shreg     <= shreg << 8;
            remaining <= remaining - 1'b1;
        end
    end
    assign busy = (remaining != 0);
endmodule
