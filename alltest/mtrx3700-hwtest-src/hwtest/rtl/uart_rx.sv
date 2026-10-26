/*
 *  uart_rx.sv -- a synthesisable UART receiver, the other half of uart_tx.sv.
 *
 *  Frame: idle high, one start bit (0), BITS_N data bits LSB first, an optional
 *  parity bit, one stop bit (1). Every bit lasts CLKS_PER_BIT clocks.
 *
 *  The receiver has no clock in common with the transmitter (that is what
 *  "asynchronous" means), so the only timing reference it gets is the falling
 *  edge of the start bit. From that edge it waits half a bit period to land in
 *  the MIDDLE of the start bit, checks the line is still low (otherwise the
 *  edge was a glitch), then samples every CLKS_PER_BIT clocks after that: the
 *  middle of each data bit, the parity bit and the stop bit. Sampling mid-bit
 *  is what makes a UART tolerant of a few percent of baud-rate mismatch.
 *
 *  FSM (same shape as the transmitter's):
 *
 *      IDLE --rx low--> START_BIT --half bit, rx still low--> DATA_BITS --BITS_N bits--> PARITY_BIT --> STOP_BIT --> DONE --handshake--> IDLE
 *                          \--half bit, rx high (glitch)--> IDLE            (skipped if PARITY_TYPE == 0)
 *
 *  Outputs: data_rx / valid / ready form the same valid-ready handshake as the
 *  transmitter: valid stays high in DONE until the consumer asserts ready.
 *  parity_error and framing_error (stop bit was 0) are valid together with
 *  valid, so the consumer can discard a corrupted byte.
 *
 *  The two flip-flops on rx are a SYNCHRONISER: the line comes from another
 *  clock domain (or a cable), so it can change at any instant relative to our
 *  clock. Passing it through two registers before using it keeps a metastable
 *  first flop from spreading into the FSM. Never use rx directly.
 */
module uart_rx #(
    parameter CLKS_PER_BIT = (50_000_000/115_200), // E.g. 115200 baud with a 50 MHz clk
    parameter BITS_N       = 8,                    // Number of data bits per frame
    parameter PARITY_TYPE  = 0                     // 0 for none, 1 for odd parity, 2 for even (same as uart_tx)
) (
    input  logic              clk,
    input  logic              rst,
    input  logic              rx,             // the UART line
    output logic [BITS_N-1:0] data_rx,
    output logic              valid,          // handshake: a received byte is on data_rx
    input  logic              ready,          // handshake: the consumer has taken it
    output logic              parity_error,   // with valid: the parity bit did not match the data
    output logic              framing_error   // with valid: the stop bit was not 1
);

    // ---- synchroniser --------------------------------------------------------
    logic rx_meta, rx_sync;
    always_ff @(posedge clk) begin
        rx_meta <= rx;
        rx_sync <= rx_meta;
    end

    // ---- FSM ------------------------------------------------------------------
    typedef enum logic [2:0] {IDLE, START_BIT, DATA_BITS, PARITY_BIT, STOP_BIT, DONE} state_t;
    state_t current_state, next_state;

    logic [$clog2(CLKS_PER_BIT)-1:0] cycle_counter;
    logic [$clog2(BITS_N)-1:0]       bit_n;          // 0 .. BITS_N-1
    logic sample_now;   // the middle of the current bit: time to look at rx_sync
    logic parity_bit;

    // In START_BIT we only wait half a bit (to reach the middle); afterwards a full bit.
    assign sample_now = (current_state == START_BIT) ? (int'(cycle_counter) == CLKS_PER_BIT/2 - 1)
                                                     : (int'(cycle_counter) == CLKS_PER_BIT - 1);

    always_comb begin : fsm_next_state
        next_state = current_state;
        case (current_state)
            IDLE:       next_state = (rx_sync == 1'b0) ? START_BIT : IDLE;           // falling edge of the start bit
            START_BIT:  if (sample_now) next_state = (rx_sync == 1'b0) ? DATA_BITS : IDLE; // still low mid-bit? real start bit
            DATA_BITS:  if (sample_now && int'(bit_n) == BITS_N - 1)
                            next_state = (PARITY_TYPE != 0) ? PARITY_BIT : STOP_BIT;
            PARITY_BIT: if (sample_now) next_state = STOP_BIT;
            STOP_BIT:   if (sample_now) next_state = DONE;
            DONE:       next_state = ready ? IDLE : DONE;                            // handshake
            default:    next_state = IDLE;
        endcase
    end

    always_ff @(posedge clk) begin : fsm_ff
        if (rst) begin
            current_state <= IDLE;
            cycle_counter <= '0;
            bit_n         <= '0;
            data_rx       <= '0;
            parity_bit    <= 1'b0;
            framing_error <= 1'b0;
        end else begin
            current_state <= next_state;
            // The counter restarts at every sample point and whenever we (re)start a frame.
            cycle_counter <= (sample_now || current_state == IDLE || current_state == DONE) ? '0 : cycle_counter + 1'b1;
            case (current_state)
                IDLE: begin
                    bit_n <= '0;
                end
                DATA_BITS: if (sample_now) begin
                    data_rx[bit_n] <= rx_sync;                // LSB first
                    bit_n          <= bit_n + 1'b1;
                end
                PARITY_BIT: if (sample_now) parity_bit <= rx_sync;
                STOP_BIT:   if (sample_now) framing_error <= (rx_sync != 1'b1);
                default: ;
            endcase
        end
    end

    // ---- outputs ---------------------------------------------------------------
    assign valid = (current_state == DONE);
    // Even parity: data ^ parity must have an even number of ones. Odd: an odd number.
    assign parity_error = (PARITY_TYPE == 0) ? 1'b0 :
                          (PARITY_TYPE == 2) ? ((^data_rx) != parity_bit) : ((~^data_rx) != parity_bit);

endmodule
