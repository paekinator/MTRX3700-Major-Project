`timescale 1ns/1ps
/*
 *  chassis_command.sv -- the UGV02 heartbeat: one JSON motion command every PERIOD_CLKS.
 *
 *  The Waveshare UGV02 listens on its 40-pin header UART at 115200 8N1 for one JSON object per
 *  line. Speed control is {"T":1,"L":<m/s>,"R":<m/s>} with L and R in -0.5 .. 0.5 (wiki: "JSON
 *  command set"), and the chassis stops by itself when no motion command has arrived for 3 s
 *  (its heartbeat). So this module sends a command every PERIOD_CLKS (200 ms on the board):
 *
 *      armed = 0            {"T":1,"L":0.0,"R":0.0}      a stop, every period: the wheels never move
 *      armed = 1            L and R from `motion` and `speed`:
 *          motion 00 forward   L = +s  R = +s          speed 00 s = 0.1 m/s
 *                 01 backward  L = -s  R = -s                01     0.2
 *                 10 spin left L = -s  R = +s                10     0.3
 *                 11 spin right L = +s R = -s                11     0.5
 *      feedback = 1         also {"T":130} after each motion command: the chassis answers with
 *                           one line of telemetry, which is how the RX direction gets tested.
 *
 *  The text is assembled from string literals (a string literal is a packed vector of 8-bit
 *  characters in SystemVerilog), left-aligned in a MAXLEN-byte shift register, and shifted out one
 *  byte per uart_tx handshake. Nothing here is specific to the strings: change the ROM pieces and
 *  it sends something else.
 */
module chassis_command #(
    parameter int CLKS_PER_BIT = 434,           // 50 MHz / 115200
    parameter int PERIOD_CLKS  = 10_000_000     // 200 ms at 50 MHz
) (
    input  logic       clk,
    input  logic       reset,
    input  logic       armed,       // 0: every message is a stop
    input  logic [1:0] motion,      // 00 forward, 01 backward, 10 spin left, 11 spin right
    input  logic [1:0] speed,       // 00 0.1, 01 0.2, 10 0.3, 11 0.5 m/s
    input  logic       feedback,    // 1: also ask for telemetry ({"T":130}) every period
    output logic       tx,          // to the chassis RX
    output logic       busy         // a message is going out
);
    localparam int MAXLEN = 28;
    localparam logic [8*11-1:0] P1 = "{\"T\":1,\"L\":";
    localparam logic [8*5-1:0]  P2 = ",\"R\":";
    localparam logic [8*2-1:0]  P3 = "}\n";
    localparam logic [8*10-1:0] FB = "{\"T\":130}\n";

    // {length, text left-aligned in MAXLEN bytes}
    function automatic logic [MAXLEN*8+7:0] motion_msg(input logic armed_i, input logic [1:0] motion_i, input logic [1:0] speed_i);
        logic [7:0] d;
        logic ln, rn;
        logic [MAXLEN*8-1:0] t;
        case (speed_i)
            2'd0:    d = "1";
            2'd1:    d = "2";
            2'd2:    d = "3";
            default: d = "5";
        endcase
        ln = 1'b0; rn = 1'b0;
        if (!armed_i) d = "0";
        else case (motion_i)
            2'd1:    begin ln = 1'b1; rn = 1'b1; end
            2'd2:    begin ln = 1'b1; rn = 1'b0; end
            2'd3:    begin ln = 1'b0; rn = 1'b1; end
            default: ;
        endcase
        t = '0;
        case ({ln, rn})
            2'b00:   begin t[MAXLEN*8-1 -: 24*8] = {P1, "0.",  d, P2, "0.",  d, P3}; return {8'd24, t}; end
            2'b11:   begin t[MAXLEN*8-1 -: 26*8] = {P1, "-0.", d, P2, "-0.", d, P3}; return {8'd26, t}; end
            2'b10:   begin t[MAXLEN*8-1 -: 25*8] = {P1, "-0.", d, P2, "0.",  d, P3}; return {8'd25, t}; end
            default: begin t[MAXLEN*8-1 -: 25*8] = {P1, "0.",  d, P2, "-0.", d, P3}; return {8'd25, t}; end
        endcase
    endfunction

    // ---- the period ----
    localparam int PW = $clog2(PERIOD_CLKS);
    logic [PW-1:0] timer = '0;
    logic tick;
    always_ff @(posedge clk)
        if (reset) timer <= '0;
        else       timer <= (timer == PW'(PERIOD_CLKS - 1)) ? '0 : timer + 1'b1;
    assign tick = (timer == PW'(PERIOD_CLKS - 1));

    // ---- the sender ----
    logic [MAXLEN*8-1:0] shreg = '0;
    logic [7:0]          remaining = '0;
    logic                fb_pending = 1'b0;
    logic                tx_valid = 1'b0, tx_ready;
    enum logic [1:0] {IDLE, SEND, LOAD_FB} state = IDLE;

    uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT), .BITS_N(8)) tx_u (
        .clk(clk), .rst(reset), .data_tx(shreg[MAXLEN*8-1 -: 8]), .valid(tx_valid), .uart_out(tx), .ready(tx_ready));

    always_ff @(posedge clk) begin
        if (reset) begin
            state <= IDLE; tx_valid <= 1'b0; remaining <= '0; fb_pending <= 1'b0;
        end else case (state)
            IDLE: if (tick) begin
                {remaining, shreg} <= motion_msg(armed, motion, speed);
                fb_pending <= feedback;
                state <= SEND;
            end
            SEND: begin
                if (!tx_valid) begin
                    if (remaining == 0)  state <= fb_pending ? LOAD_FB : IDLE;
                    else if (tx_ready)   tx_valid <= 1'b1;
                end else if (tx_ready) begin              // handshake: this byte is taken
                    tx_valid  <= 1'b0;
                    shreg     <= shreg << 8;
                    remaining <= remaining - 1'b1;
                end
            end
            LOAD_FB: begin
                shreg <= {FB, {(MAXLEN - 10) * 8{1'b0}}};
                remaining <= 8'd10;
                fb_pending <= 1'b0;
                state <= SEND;
            end
            default: state <= IDLE;
        endcase
    end
    assign busy = (state != IDLE);
endmodule
