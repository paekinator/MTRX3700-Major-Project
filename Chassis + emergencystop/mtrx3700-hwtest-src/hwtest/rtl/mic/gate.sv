`timescale 1ns/1ps
/*
 *  gate.sv -- level (in dB for the display), noise floor, and the voice-activity gate (A2 rung 1).
 *
 *      s  <= s  + (|x| - s)  * 2^-ALPHA_SH      fast: follows the voice (2^-8 at 48 kHz ~ 5 ms)
 *      nf follows s downwards quickly (2^-FALL_SH ~ 40 ms) and upwards slowly (2^-BETA_SH ~ 0.7 s), and
 *         upwards 2^HOLD_SH times slower still while the gate is open (2^-21: a held vowel takes ~11 s to lift
 *         the floor to a quarter of the level, where the gate closes; HOLD_SH = 4 gave 2.5 s): a MINIMUM tracker. The
 *         quiet moments between words pull it down; a held note cannot pull it up and close the gate on
 *         itself. At reset nf starts at 1/8 full scale, so the gate is closed until the room has been heard (~70 ms).
 *      gate = s > K * nf                        K = 2^K_SH
 *      snr_db = 6 * (log2 s - log2 nf)          integer dB, from leading-one positions (0.09 error in log2 ~ 0.5 dB)
 *
 *  Runs on the raw 48 kHz samples (one per `sample_valid`), in the codec's bit-clock domain. Each
 *  average is a register, a subtract, a shift and an add. No multiplier, no divider.
 *  The registers keep FRAC extra fraction bits so that a slow average with 2^-15 gain does not
 *  round to a standstill: (|x| - nf) >> 15 would be 0 for any difference under 32768.
 */
module gate #(
    parameter int W        = 16,     // sample width (signed)
    parameter int ALPHA_SH = 8,
    parameter int BETA_SH  = 15,
    parameter int FALL_SH  = 11,     // how fast the floor drops to a quieter level
    parameter int K_SH     = 2,      // K = 4 (12 dB)
    parameter int HOLD_SH  = 6,      // floor learns 2^HOLD_SH times slower while the gate is open (was 4: closed after 2.5 s of a held vowel)
    parameter int FRAC     = 16,     // fraction bits kept in the averages
    parameter int DB_HOLD_SH = 13    // the dB reading updates every 2^13 samples (0.17 s at 48 kHz): readable on a display
) (
    input  logic                clk,
    input  logic                reset,
    input  logic                sample_valid,
    input  logic signed [W-1:0] sample,
    output logic [7:0]          level,        // s, top 8 bits of the magnitude (for the LED bar / display)
    output logic [6:0]          snr_db,       // 0..99 (level over floor; the gate's own view)
    output logic [6:0]          level_db,     // 0..99: 20*log10(s) re 1 LSB, from the leading one + 3 bits (0.75 dB steps)
    output logic                voice_active
);
    localparam int AW = W - 1 + FRAC;                     // magnitude bits + fraction
    logic [W-2:0] mag;
    assign mag = sample[W-1] ? (~sample[W-2:0] + 1'b1) : sample[W-2:0];
    logic signed [AW:0] s  = '0;                          // one extra bit for the signed differences
    logic signed [AW:0] nf = (AW+1)'(1) <<< (AW-3);       // power-up: floor at 1/8 full scale, gate closed until the room is heard (~70 ms)
    logic signed [AW:0] x_f;
    assign x_f = {1'b0, mag, {FRAC{1'b0}}};
    always_ff @(posedge clk) begin
        if (reset) begin s <= '0; nf <= (AW+1)'(1) <<< (AW-3); end        // floor starts high: gate closed
        else if (sample_valid) begin
            s <= s + ((x_f - s) >>> ALPHA_SH);
            if (s < nf)             nf <= nf + ((s - nf) >>> FALL_SH);                  // quieter: drop quickly
            else if (voice_active)  nf <= nf + ((s - nf) >>> (BETA_SH + HOLD_SH));      // voice: barely move
            else                    nf <= nf + ((s - nf) >>> BETA_SH);                  // louder room: learn slowly
        end
    end
    // ---- gate: s > K * nf ----
    assign voice_active = ((s >>> K_SH) > nf);            // s > K*nf, without overflowing nf
    assign level = s[AW-1 -: 8];
    // ---- SNR in dB from leading-one positions (integer log2) ----
    function automatic logic [5:0] lead1(input logic [AW:0] v);
        lead1 = '0;
        for (int i = 0; i <= AW; i++) if (v[i]) lead1 = 6'(i);
    endfunction
    // ---- level in dB: log2 = leading-one position + the next 3 bits as a fraction (a straight line between
    //      powers of two, worst error 0.09); dB = 6.02 * log2, so 8 eighths of a bit = 6 dB -> multiply by 3/4 ----
    logic [5:0] ls, ln;
    logic [2:0] frac_s;
    always_comb begin
        frac_s = '0;
        for (int i = 3; i <= AW; i++) if (s[i] && (s >> (i + 1)) == 0) frac_s = s[i-1 -: 3];   // the 3 bits below the leading one
    end
    logic [9:0] db8;                                             // eighths of a bit above 1 LSB of |x|
    logic [DB_HOLD_SH-1:0] hold_cnt = '0;
    always_ff @(posedge clk) begin
        db8 <= (lead1(s) > FRAC) ? 10'((lead1(s) - FRAC) * 8 + frac_s) : 10'd0;
        if (sample_valid) hold_cnt <= hold_cnt + 1'b1;
        if (sample_valid && hold_cnt == 0) level_db <= ((db8 * 3) >> 2) > 99 ? 7'd99 : 7'((db8 * 3) >> 2);
    end
    always_ff @(posedge clk) begin
        ls <= lead1(s); ln <= lead1(nf);
        if (ls <= ln) snr_db <= '0;
        else if ((ls - ln) * 6 > 99) snr_db <= 7'd99;
        else snr_db <= 7'((ls - ln) * 6);
    end
endmodule
