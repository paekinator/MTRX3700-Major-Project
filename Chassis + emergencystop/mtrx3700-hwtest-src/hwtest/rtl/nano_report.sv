`timescale 1ns/1ps
/*
 *  nano_report.sv -- pick the Nano's once-a-second report line out of its byte stream.
 *
 *  nano/hwtest_nano.ino sends   #<|rssi| dBm>,<3V3 rail minimum, mV>,<mode>\n   once a second, in
 *  between the echoed letters. This parser waits for '#', reads two decimal fields, keeps the mode
 *  character, and commits all three at the newline (`seen` pulses). Anything else on the line is
 *  ignored, including the echoes. Numbers are read as digit-by-digit decimal into binary
 *  (acc = acc x 10 + digit), which is the reverse of what display.sv does on the way out.
 */
module nano_report (
    input  logic       clk,
    input  logic       reset,
    input  logic       rx_valid,      // one clock per byte from the Nano
    input  logic [7:0] rx_byte,
    output logic [6:0] rssi,          // 0..99: -dBm of the WiFi link (0 in access-point mode)
    output logic [11:0] mv,           // 0..4095: the Nano's 3.3 V rail, the minimum over the last second
    output logic [7:0] mode,          // 'A' AP up, 'C' client on the AP, 'S' joined, 'N' not connected, 'X' no module
    output logic       seen           // one clock: a report line has just been completed
);
    enum logic [1:0] {IDLE, F0, F1, F2} state = IDLE;
    logic [6:0]  acc0 = '0;
    logic [11:0] acc1 = '0;
    logic [7:0]  m    = "?";
    logic        digit;
    logic [3:0]  d;
    assign digit = (rx_byte >= "0") && (rx_byte <= "9");
    assign d     = rx_byte[3:0];

    always_ff @(posedge clk) begin
        seen <= 1'b0;
        if (reset) begin
            state <= IDLE; rssi <= '0; mv <= '0; mode <= "?";
        end else if (rx_valid) begin
            case (state)
                IDLE: if (rx_byte == "#") begin state <= F0; acc0 <= '0; acc1 <= '0; m <= "?"; end
                F0:   if (digit)              acc0 <= 7'(acc0 * 7'd10 + 7'(d));
                      else if (rx_byte == ",") state <= F1;
                      else                     state <= IDLE;
                F1:   if (digit)              acc1 <= 12'(acc1 * 12'd10 + 12'(d));
                      else if (rx_byte == ",") state <= F2;
                      else if (rx_byte == 8'h0A) begin rssi <= acc0; mv <= acc1; mode <= m; seen <= 1'b1; state <= IDLE; end
                      else                     state <= IDLE;
                F2:   if (rx_byte == 8'h0A)  begin rssi <= acc0; mv <= acc1; mode <= m; seen <= 1'b1; state <= IDLE; end
                      else                     m <= rx_byte;
                default: state <= IDLE;
            endcase
        end
    end
endmodule
