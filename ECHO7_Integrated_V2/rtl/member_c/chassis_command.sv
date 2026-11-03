`timescale 1ns/1ps
/*
 *  chassis_command.sv -- the UGV02 heartbeat: one JSON motion command every PERIOD_CLKS.
 *
 *  The Waveshare UGV02 listens on its 40-pin header UART at 115200 8N1 for one JSON object per
 *  line. Speed control is {"T":1,"L":<m/s>,"R":<m/s>} with L and R in -0.5 .. 0.5 (wiki: "JSON
 *  command set"), and the chassis stops by itself when no motion command has arrived for 3 s
 *  (its heartbeat). So this module sends a command every PERIOD_CLKS (200 ms on the board):
 *
 *      armed = 0            {"T":1,"L":0.00,"R":0.00}      a stop, every period: the wheels never move
 *      armed = 1            L and R from `motion` and `speed`:
 *          motion 00 forward   L = +s  R = +s          speed 00 s = SPEED0_CM_S / 100 m/s
 *                 01 backward  L = -s  R = -s                01     disabled
 *                 10 spin left L = -s  R = +s                10     disabled
 *                 11 spin right L = +s R = -s                11     disabled
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
    parameter int PERIOD_CLKS  = 10_000_000,    // 200 ms at 50 MHz
    parameter bit USE_WHEEL_REQUESTS = 0,
    parameter int SPEED0_CM_S  = 10             // slot 00; supplied by Top-Level
) (
    input  logic       clk,
    input  logic       reset,
    input  logic       armed,       // 0: every message is a stop
    input  logic [1:0] motion,      // 00 forward, 01 backward, 10 spin left, 11 spin right
    input  logic [1:0] speed,       // 00 parameter speed; other slots disabled in this safety test
    input logic signed [6:0] left_cm_s, right_cm_s,
    input  logic       feedback,    // 1: also ask for telemetry ({"T":130}) every period
    output logic       tx,          // to the chassis RX
    output logic       busy         // a message is going out
);
    localparam int MAXLEN = 28;
    // Constant-folded ASCII conversion: no runtime divider or DSP needed.
    // Out-of-range settings produce zero rather than a malformed speed.
    localparam int SAFE_SPEED0 = (SPEED0_CM_S >= 3 && SPEED0_CM_S <= 15) ? SPEED0_CM_S : 0;
    localparam logic [7:0] SPEED0_TENS = 8'd48 + 8'(SAFE_SPEED0 / 10);
    localparam logic [7:0] SPEED0_ONES = 8'd48 + 8'(SAFE_SPEED0 % 10);
    localparam logic [8*11-1:0] P1 = "{\"T\":1,\"L\":";
    localparam logic [8*5-1:0]  P2 = ",\"R\":";
    localparam logic [8*2-1:0]  P3 = "}\n";
    localparam logic [8*10-1:0] FB = "{\"T\":130}\n";

    // {length, text left-aligned in MAXLEN bytes}
    function automatic logic [MAXLEN*8+7:0] motion_msg(input logic armed_i, input logic [1:0] motion_i, input logic [1:0] speed_i);
        logic [15:0] d; // Two decimal places, including the leading zero in 0.05.
        logic ln, rn;
        logic [MAXLEN*8-1:0] t;
        case (speed_i)
            2'd0:    d = {SPEED0_TENS, SPEED0_ONES};
            2'd1:    d = "00";
            2'd2:    d = "00";
            default: d = "00";
        endcase
        ln = 1'b0; rn = 1'b0;
        if (!armed_i) d = "00";
        else case (motion_i)
            2'd1:    begin ln = 1'b1; rn = 1'b1; end
            2'd2:    begin ln = 1'b1; rn = 1'b0; end
            2'd3:    begin ln = 1'b0; rn = 1'b1; end
            default: ;
        endcase
        t = '0;
        case ({ln, rn})
            2'b00:   begin t[MAXLEN*8-1 -: 26*8] = {P1, "0.",  d, P2, "0.",  d, P3}; return {8'd26, t}; end
            2'b11:   begin t[MAXLEN*8-1 -: 28*8] = {P1, "-0.", d, P2, "-0.", d, P3}; return {8'd28, t}; end
            2'b10:   begin t[MAXLEN*8-1 -: 27*8] = {P1, "-0.", d, P2, "0.",  d, P3}; return {8'd27, t}; end
            default: begin t[MAXLEN*8-1 -: 27*8] = {P1, "0.",  d, P2, "-0.", d, P3}; return {8'd27, t}; end
        endcase
    endfunction

    // Independent signed cm/s requests; bounded before ASCII conversion.
    function automatic logic [MAXLEN*8+7:0] wheel_msg(input logic enable,
      input logic signed [6:0] l, r);
      logic [6:0] lm,rm;
      logic [15:0] ld,rd;
      logic ln,rn;
      logic [MAXLEN*8-1:0] t;
      begin
        lm=l<0 ? 7'(-l):7'(l);rm=r<0 ? 7'(-r):7'(r);
        if(!enable || lm>15 || rm>15) begin lm=0;rm=0;end
        ln=l<0 && lm!=0;rn=r<0 && rm!=0;
        ld={8'(48+(lm>=10)),8'(48+(lm>=10 ? lm-10:lm))};
        rd={8'(48+(rm>=10)),8'(48+(rm>=10 ? rm-10:rm))};
        t='0;
        case({ln,rn})
          2'b00:begin t[MAXLEN*8-1 -: 26*8]={P1,"0.",ld,P2,"0.",rd,P3};return {8'd26,t};end
          2'b11:begin t[MAXLEN*8-1 -: 28*8]={P1,"-0.",ld,P2,"-0.",rd,P3};return {8'd28,t};end
          2'b10:begin t[MAXLEN*8-1 -: 27*8]={P1,"-0.",ld,P2,"0.",rd,P3};return {8'd27,t};end
          default:begin t[MAXLEN*8-1 -: 27*8]={P1,"0.",ld,P2,"-0.",rd,P3};return {8'd27,t};end
        endcase
      end
    endfunction
    logic signed [6:0] sentL=0,sentR=0;
    wire signed [6:0] desiredL=armed?left_cm_s:7'sd0;
    wire signed [6:0] desiredR=armed?right_cm_s:7'sd0;
    wire wheelsChanged=USE_WHEEL_REQUESTS && (desiredL!=sentL || desiredR!=sentR);

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
    logic last_armed = 0, stop_pending = 1;
    wire stop_edge = last_armed && !armed;
    enum logic [1:0] {IDLE, SEND, LOAD_FB} state = IDLE;

    uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT), .BITS_N(8)) tx_u (
        .clk(clk), .rst(reset), .data_tx(shreg[MAXLEN*8-1 -: 8]), .valid(tx_valid), .uart_out(tx), .ready(tx_ready));

    always_ff @(posedge clk) begin
        last_armed <= armed;
        if (stop_edge) stop_pending <= 1;
        if (reset) begin
            last_armed <= 0; stop_pending <= 1; sentL<=0;sentR<=0;
            state <= IDLE; tx_valid <= 1'b0; remaining <= '0; fb_pending <= 1'b0;
        end else case (state)
            IDLE: if (stop_pending || stop_edge || tick || wheelsChanged || (armed && !last_armed)) begin
                if(USE_WHEEL_REQUESTS)
                    {remaining,shreg}<=wheel_msg(armed && !stop_pending && !stop_edge,left_cm_s,right_cm_s);
                else {remaining, shreg} <= motion_msg(armed && !stop_pending && !stop_edge, motion, speed);
                sentL<=armed && !stop_pending && !stop_edge ? left_cm_s:7'sd0;
                sentR<=armed && !stop_pending && !stop_edge ? right_cm_s:7'sd0;
                stop_pending <= 0;
                fb_pending <= feedback && !stop_pending && !stop_edge;
                state <= SEND;
            end
            SEND: begin
                if (!tx_valid) begin
                    if (remaining == 0 && tx_ready) state <= (fb_pending && !stop_pending && !stop_edge) ? LOAD_FB : IDLE;
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
