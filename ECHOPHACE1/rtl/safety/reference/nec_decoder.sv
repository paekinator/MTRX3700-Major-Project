`timescale 1ns/1ps
/*
 *  nec_decoder.sv -- a minimal NEC decoder: the same job as Terasic's IR_RECEIVE in one always_ff.
 *
 *  The trick: in NEC every symbol *starts* with the same 562.5 us burst, so the information is in
 *  the time from one falling edge of IRDA_RXD to the next:
 *
 *      13.5 ms   lead (9 ms burst + 4.5 ms space)     -> a frame begins, bit counter to 0
 *      11.25 ms  repeat (9 ms burst + 2.25 ms space)  -> the key is still held (no data follows)
 *      1.125 ms  a 0 bit                               \  32 of these, least significant bit first,
 *      2.25 ms   a 1 bit                               /  then the stop burst's edge completes bit 31
 *      anything else -> not NEC, abandon the frame
 *
 *  A frame is reported (valid pulses, code holds the 32 bits) when the inverted key byte checks:
 *  code[31:24] == ~code[23:16]. code[15:0] is the custom code, code[23:16] the key.
 *  The falling edge is detected on a synchronised copy of the pin (two flops: it is asynchronous).
 */
module nec_decoder #(
    parameter int CLK_HZ = 50_000_000
) (
    input  logic        clk,
    input  logic        rst,
    input  logic        ir,             // IRDA_RXD: idle high, low during a burst
    output logic        valid,          // one-clock pulse: code is a new, checked frame
    output logic [31:0] code,
    output logic        repeat_code     // one-clock pulse: a repeat code was seen
);
    localparam int US = CLK_HZ / 1_000_000;                                  // clocks per microsecond
    localparam logic [23:0] LEAD_MIN = 24'(12_000 * US), LEAD_MAX = 24'(15_000 * US);   // 13.5 ms
    localparam logic [23:0] RPT_MIN  = 24'(10_000 * US), RPT_MAX  = 24'(12_500 * US);   // 11.25 ms
    localparam logic [23:0] ONE_MIN  = 24'( 1_800 * US), ONE_MAX  = 24'( 2_700 * US);   // 2.25 ms
    localparam logic [23:0] ZERO_MIN = 24'(   800 * US), ZERO_MAX = 24'( 1_400 * US);   // 1.125 ms

    logic [2:0]  s;                     // synchroniser + edge detector
    logic        fall;
    logic [23:0] gap;                   // clocks since the last falling edge (saturates)
    logic        in_frame;
    logic [5:0]  n;                     // bits received in this frame
    logic [31:0] sr;
    logic [31:0] word;
    logic        is_one, is_zero;

    always_ff @(posedge clk) s <= {s[1:0], ir};
    assign fall    = s[2] & ~s[1];
    assign is_one  = (gap >= ONE_MIN)  && (gap <= ONE_MAX);
    assign is_zero = (gap >= ZERO_MIN) && (gap <= ZERO_MAX);
    assign word    = {is_one, sr[31:1]};                 // the shift register after this bit goes in

    always_ff @(posedge clk) begin
        valid       <= 1'b0;
        repeat_code <= 1'b0;
        gap         <= (&gap) ? gap : gap + 1'b1;
        if (rst) begin
            in_frame <= 1'b0; n <= '0;
        end else if (fall) begin
            gap <= '0;
            if (gap >= LEAD_MIN && gap <= LEAD_MAX) begin
                in_frame <= 1'b1; n <= '0;
            end else if (gap >= RPT_MIN && gap <= RPT_MAX) begin
                repeat_code <= 1'b1; in_frame <= 1'b0;
            end else if (in_frame && (is_one || is_zero)) begin
                sr <= word;
                n  <= n + 1'b1;
                if (n == 6'd31) begin
                    in_frame <= 1'b0;
                    if (word[31:24] == ~word[23:16]) begin code <= word; valid <= 1'b1; end
                end
            end else begin
                in_frame <= 1'b0;                        // the first burst after idle, or a gap that is not NEC
            end
        end
    end
endmodule
