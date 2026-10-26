`timescale 1ns/1ps
/*
 *  ir_drive.sv -- drive the chassis from the IR remote, dead-man style.
 *
 *  An NEC remote sends one data frame when a key goes down and then a repeat code every 108 ms
 *  for as long as it is held (nec_decoder.sv reports both). So "the key is held" is a timer that
 *  the frame starts and every repeat reloads; when it runs out the key has been released. The
 *  chassis moves only while a motion key is held (`active`), and stops within HOLD_CLKS of the
 *  key being let go (plus the 200 ms heartbeat of chassis_command.sv). A robot on the bench
 *  should never depend on someone remembering to press stop.
 *
 *  Keys (the Terasic remote's codes as transcribed in mp/models/ir_remote_model.sv; HEX1..0 on
 *  the test board shows the code of the last key, so a wrong entry is found in seconds):
 *      CH+  0x1A  forward        VOL-  0x1F  spin left       1..4  0x01..0x04  speed 0.1 / 0.2 / 0.3 / 0.5 m/s (latched)
 *      CH-  0x1E  backward       VOL+  0x1B  spin right      anything else                 stop
 *  The custom code (code[15:0]) is not checked: any NEC remote works, which is what a test tool wants.
 */
module ir_drive #(
    parameter int HOLD_CLKS = 15_000_000       // 300 ms at 50 MHz: nearly three repeat periods
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        valid,                 // nec_decoder: a checked data frame is on `code`
    input  logic        repeat_code,           // nec_decoder: a repeat code (the key is still down)
    input  logic [31:0] code,
    output logic        active,                // a motion key is held: drive
    output logic [1:0]  motion,                // 00 forward, 01 backward, 10 spin left, 11 spin right
    output logic [1:0]  speed                  // 00 0.1, 01 0.2, 10 0.3, 11 0.5 m/s
);
    localparam logic [7:0] KEY_CHP = 8'h1A, KEY_CHM = 8'h1E, KEY_VOLM = 8'h1F, KEY_VOLP = 8'h1B;
    localparam int HW = $clog2(HOLD_CLKS + 1);
    logic [HW-1:0] hold = '0;
    logic [7:0]    key;
    assign key = code[23:16];

    always_ff @(posedge clk) begin
        if (reset) begin
            hold <= '0; motion <= 2'd0; speed <= 2'd0;
        end else begin
            if (hold != 0) hold <= hold - 1'b1;
            if (valid) begin
                case (key)
                    KEY_CHP:  begin motion <= 2'd0; hold <= HW'(HOLD_CLKS); end
                    KEY_CHM:  begin motion <= 2'd1; hold <= HW'(HOLD_CLKS); end
                    KEY_VOLM: begin motion <= 2'd2; hold <= HW'(HOLD_CLKS); end
                    KEY_VOLP: begin motion <= 2'd3; hold <= HW'(HOLD_CLKS); end
                    8'h01:    speed <= 2'd0;
                    8'h02:    speed <= 2'd1;
                    8'h03:    speed <= 2'd2;
                    8'h04:    speed <= 2'd3;
                    default:  hold <= '0;                       // any other key: stop
                endcase
            end else if (repeat_code && hold != 0) begin
                hold <= HW'(HOLD_CLKS);                         // still held
            end
        end
    end
    assign active = (hold != 0);
endmodule
