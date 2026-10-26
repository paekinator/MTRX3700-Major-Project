`timescale 1ns/1ps
/*
 *  nano_probe.sv -- an echo test of the Arduino Nano's UART link, both directions at once.
 *
 *  Every PERIOD_CLKS (100 ms on the board) one printable byte goes to the Nano ('A', 'B', ...
 *  'Z', 'A', ...). The Nano runs nano/hwtest_nano.ino, which sends every byte straight back (and
 *  mirrors it to its USB serial port, so a serial monitor on a laptop shows the same letters).
 *  `echo_ok` says whether the PREVIOUS probe came back unchanged; it is updated at every probe,
 *  so the LED it drives is a steady light when the link works in both directions and off when
 *  the Nano is absent, unpowered, held in reset, wired the wrong way round, or running
 *  something else. `rx_valid` pulses for every well-formed byte from the Nano, whatever it is.
 *
 *  Wiring (both the 2025 DE1-Adaptor and the 2026 breakout): the FPGA transmits on GPIO_1[5],
 *  which is the Nano's RX (D0), and receives on GPIO_1[3], the Nano's TX (D1). The 2025 Hardware
 *  Return Test had these the other way round and drove an output into the Nano's TX pin.
 */
module nano_probe #(
    parameter int CLKS_PER_BIT = 434,           // 50 MHz / 115200
    parameter int PERIOD_CLKS  = 5_000_000      // 100 ms at 50 MHz
) (
    input  logic       clk,
    input  logic       reset,
    input  logic       rx,          // from the Nano's TX
    output logic       tx,          // to the Nano's RX
    output logic       echo_ok,     // the last probe was echoed correctly
    output logic       rx_valid,    // a byte arrived from the Nano (one clock)
    output logic [7:0] rx_byte
);
    localparam int PW = $clog2(PERIOD_CLKS);
    logic [PW-1:0] timer = '0;
    logic tick;
    always_ff @(posedge clk)
        if (reset) timer <= '0;
        else       timer <= (timer == PW'(PERIOD_CLKS - 1)) ? '0 : timer + 1'b1;
    assign tick = (timer == PW'(PERIOD_CLKS - 1));

    logic [7:0] letter = "A", sent = "A";
    logic       tx_valid = 1'b0, tx_ready, matched = 1'b0, framing_error;

    uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT), .BITS_N(8)) tx_u (
        .clk(clk), .rst(reset), .data_tx(letter), .valid(tx_valid), .uart_out(tx), .ready(tx_ready));
    uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT), .BITS_N(8), .PARITY_TYPE(0)) rx_u (
        .clk(clk), .rst(reset), .rx(rx), .data_rx(rx_byte), .valid(rx_valid), .ready(1'b1),
        .parity_error(), .framing_error(framing_error));

    always_ff @(posedge clk) begin
        if (reset) begin
            tx_valid <= 1'b0; letter <= "A"; sent <= "A"; matched <= 1'b0; echo_ok <= 1'b0;
        end else begin
            if (tick) begin                                   // a new probe: report the last one
                echo_ok  <= matched;
                matched  <= 1'b0;
                sent     <= letter;
                tx_valid <= 1'b1;
            end
            if (tx_valid && tx_ready) begin                   // handshake: the byte is on its way
                tx_valid <= 1'b0;
                letter   <= (letter == "Z") ? 8'("A") : letter + 1'b1;
            end
            if (rx_valid && !framing_error && rx_byte == sent) matched <= 1'b1;
        end
    end
endmodule
