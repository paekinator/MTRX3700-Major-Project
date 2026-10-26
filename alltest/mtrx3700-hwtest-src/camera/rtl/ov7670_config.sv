/*
 *  ov7670_config.sv -- put the camera into a known state over the SCCB, then get out of the way.
 *
 *  The OV7670's control bus, SCCB, is I2C with a different name: START, the ID byte 0x42 (7-bit
 *  address 0x21 + write), one register address byte, one data byte, a ninth clock after each byte,
 *  STOP. That is exactly the transaction i2c_master.sv (Lesson 3, Task 2.1) sends to the WM8731,
 *  so the same master is used here unchanged; only the address and the list of writes differ.
 *  (The one real difference: SCCB calls the ninth bit "don't care" rather than ACK. The OV7670
 *  pulls it low anyway, so the master sees an ACK and `error` stays 0.)
 *
 *  Sequence, and why (datasheet Table 4, p.6):
 *    1. hold RESET# low for T_RESET, release it, and wait T_SETTLE: the chip needs up to 1 ms
 *       after any reset before it answers (tS:RESET). Writes sent earlier are lost, and the camera
 *       ends up half configured: that was the "green picture until you press reset" of past years;
 *    2. write COM7 = 0x80, the software reset, and wait T_SETTLE again;
 *    3. write the rest of the ROM, one register per transaction, retrying a write that got no
 *       acknowledge (a wire off, or XCLK not running: the chip needs its clock to answer);
 *    4. `done` goes high and stays high. The video port has been streaming since step 1; it just
 *       streams the *configured* format from here on.
 *
 *  Clocked by the SCCB bit clock (100 kHz from clock_divider.sv), like set_audio_encoder.sv, so
 *  the millisecond waits are counts of a few hundred.
 */
module ov7670_config #(
    parameter int SCCB_CLK_HZ = 100_000,   // the clock this module and the I2C master run on
    parameter bit TUNING      = 1          // 1: also send OmniVision's picture-quality values
) (
    input  logic clk,                      // SCCB bit clock, <= 400 kHz (Table 4)
    input  logic reset,                    // synchronous, active high: starts the sequence again
    output logic sioc,                     // camera SIO_C
    inout  wire  siod,                     // camera SIO_D (open drain; the breakout has the pull-up)
    output logic cam_reset_n,              // camera RESET# (low = reset)
    output logic cam_pwdn,                 // camera PWDN (high = power down)
    output logic done,                     // all writes acknowledged
    output logic error                     // the last write was not acknowledged (it is being retried)
);
    localparam int T_RESET  = SCCB_CLK_HZ / 1000;          // 1 ms with RESET# low
    localparam int T_SETTLE = 2 * SCCB_CLK_HZ / 1000;      // 2 ms: tS:RESET is "up to 1 ms"

    // ---- the register list: {address, value} ------------------------------------------------
    // The first N_CORE entries are what the picture needs. The rest are OmniVision's recommended
    // values for the sensor's analogue and DSP blocks (reserved registers, via the Linux ov7670
    // driver, used by this course since 2023): the camera works without them, the picture is
    // better with them. Every entry is one SCCB write.
    localparam int N_CORE = 17;
    localparam int N_ALL  = 78;
    localparam logic [15:0] ROM [0:N_ALL-1] = '{
        16'h1280,   // COM7   reset all registers (the sequencer waits T_SETTLE after this one)
        16'h3A04,   // TSLB   no negative image, normal UV order, no automatic window
        16'h1100,   // CLKRC  prescaler /1 \  XCLK 10 MHz from the FPGA, x4 in the sensor's PLL = PCLK 40 MHz: a 39.2 us line,
        16'h6B4A,   // DBLV   PLL x4      /  50.0 fps. Chosen so that 10 ms of mains flicker is 255 lines, the most BD50ST's 8 bits
        // hold: any faster and the banding filter cannot work and the exposure beats against the room lights (62 fps would need
        // 319). The 2025 code ran the same x4 from 25 MHz = 100 MHz with no timing margin; 25 MHz with the PLL bypassed (DBLV 0x0A,
        // BD50ST 0x9F, BD60ST 0x85) gives 31 fps, which tears visibly in a single buffer. The prescaler stays at /1: /2 and /5
        // (from 25 MHz) were only tried while the window below was still wrong and looked no better, so they are unproven.
        16'h1204,   // COM7   RGB output, VGA, colour bar off
        16'h40D0,   // COM15  RGB565, output range 00..FF                       (2025 code: 0x10 = RGB565, range 10..F0)
        16'h1714,   // HSTART \  window columns 160..16 (wrapping at 784): 640 wide. The Linux driver's 158 plus two: the 2025
        16'h1802,   // HSTOP   } list's 140..780 started 18 columns too early and showed the sensor's dummy columns as static
        16'h3280,   // HREF   /  coloured bars at the left of the picture; 158 and 159 still had a dark column (board, 2026-09-30)
        16'h1902,   // VSTRT  \
        16'h1A7A,   // VSTOP   } window rows 10..490: 480 high (Linux driver)
        16'h030A,   // VREF   /
        16'h1E37,   // MVFP   mirror + vertical flip: the module hangs upside down on the loom (0x07 = neither)
        // Room lights flicker at 100 Hz (50 Hz mains). Unless the exposure is a whole number of
        // 10 ms periods the picture's brightness beats against it; the banding filter makes it so.
        // The default COM8 (0x8F) has the filter OFF, which is why past years' pictures pulsed.
        16'h13E7,   // COM8   fast AEC/AGC, AEC step limited, BANDING FILTER on, AGC, AWB, AEC
        16'h3B0A,   // COM11  filter for 50 Hz mains (bit 3); exposure may drop below the filter's step in bright light (bit 1)
        16'h9DFF,   // BD50ST 50 Hz filter value = lines per 10 ms: 10 ms / 39.2 us = 255 (the default 0x99 = 153 is for 24 MHz XCLK at 30 fps)
        16'h9ED5,   // BD60ST 60 Hz value, 8.33 ms / 39.2 us = 213, in case COM11 is set to 60 Hz
        // ---- tuning (OmniVision, via the Linux ov7670 driver) ----
        // (The Linux driver's colour matrix, 0x4F..0x54 = 80 80 00 22 5E 80 and MTXS 0x9E, doubles the saturation but gave a
        //  green cast on the board with the chip's own white balance; the chip's default matrix stays. A better-tuned AWB is
        //  the place to look for more colour.)
        16'h1448,   // COM9   AGC ceiling 32x
        16'h3DC0,   // COM13  gamma on, UV saturation auto-adjust
        16'h0E61,   // COM5   reserved
        16'h0F4B,   // COM6   reserved
        16'h1602,   //        reserved
        16'h2291,   // ADCCTR2 reserved
        16'h2907,   //        reserved
        16'h330B,   // CHLF   reserved
        16'h350B,   //        reserved
        16'h371D,   // ADC    reserved
        16'h3871,   // ACOM   reserved
        16'h392A,   // OFON   reserved
        16'h3C78,   // COM12  reserved
        16'h4D40,   //        reserved
        16'h4E20,   //        reserved
        16'h7410,   // REG74  digital gain by VREF[7:6]
        16'h8D4F,   //        reserved
        16'hB084,   //        reserved
        16'hB10C,   // ABLC1  automatic black level calibration on
        16'hB20E,   //        reserved
        16'hB382,   // THL_ST black level target
        16'hB80A,   //        reserved
        // ---- colour: the Linux driver's white-balance tuning, gains and matrix, together. The matrix on its own (tried first)
        //      doubled a green bias the default white balance leaves; with the driver's AWB values it is meant to be neutral. ----
        16'h5988,   // AWB range (reserved; Linux driver)
        16'h5A88,
        16'h5B44,
        16'h5C67,
        16'h5D49,
        16'h5E0E,
        16'h6C0A,   // AWBCTR3 \
        16'h6D55,   // AWBCTR2  } the auto white balance's control values
        16'h6E11,   // AWBCTR1 /
        16'h6F9F,   // AWBCTR0  (0x9E would be the "advanced" AWB)
        16'h6A40,   // GGAIN   green channel gain
        16'h0140,   // BLUE    blue gain, the AWB's starting point
        16'h0260,   // RED     red gain
        16'h4F80,   // MTX1 \
        16'h5080,   // MTX2  |
        16'h5100,   // MTX3  } the colour matrix: about twice the chip's default saturation
        16'h5222,   // MTX4  |
        16'h535E,   // MTX5  |
        16'h5480,   // MTX6 /
        16'h589E,   // MTXS    matrix signs, auto contrast centre
        16'h4118,   // COM16   AWB gain enable, de-noise auto-adjust; NOT the edge-enhancement auto-adjust (0x38): it over-sharpened
        16'h3F00,   // EDGE    edge enhancement 0 (raise a little, 1..4, for some sharpening back)
        16'h7505,
        16'h76E1,   // REG76   white/black pixel correction
        16'h4C00,   // DNSTH   de-noise threshold
        16'h7701,
        16'h4B09,
        16'hC960,   // SATCTR  saturation control
        16'h5640,   // CONTRAS contrast
        16'h3411,
        16'hA488,   // NT_CTRL
        16'h9600,
        16'h9730,
        16'h9820,
        16'h9930,
        16'h9A84,
        16'h9B29,
        16'h9C03,
        16'h7804 
    };
    localparam int N = TUNING ? N_ALL : N_CORE;

    // ---- the I2C master from Lesson 3 --------------------------------------------------------
    logic [15:0] cmd;
    logic        valid, ready, m_error;
    i2c_master u_master (
        .clk(clk), .i2c_scl(sioc), .i2c_sda(siod),
        .slav_addr(7'h21), .read_not_write(1'b0), .reg_addr(cmd[15:8]),
        .write_data(cmd[7:0]), .write_valid(valid), .write_ready(ready),
        .read_data(), .read_valid(), .read_ready(1'b1), .error(m_error));

    // ---- the sequencer ---------------------------------------------------------------------------
    enum logic [2:0] {RESET_LOW, SETTLE, LOAD, WAIT, NEXT, DONE} state = RESET_LOW, next_state;
    logic [$clog2(N_ALL)-1:0] index = '0;   // which ROM entry is being sent
    logic [$clog2(T_SETTLE+1)-1:0] wait_count = '0;
    logic settle_after;                     // the entry just sent was the software reset

    assign settle_after = (ROM[index] == 16'h1280);

    always_comb begin
        next_state = state;
        case (state)
            RESET_LOW: next_state = (wait_count == T_RESET - 1)  ? SETTLE : RESET_LOW;
            SETTLE:    next_state = (wait_count == T_SETTLE - 1) ? LOAD : SETTLE;
            LOAD:      next_state = WAIT;
            WAIT:      next_state = !ready ? WAIT : (m_error ? LOAD : NEXT);   // no acknowledge: send it again
            NEXT:      next_state = (index == N - 1) ? DONE : (settle_after ? SETTLE : LOAD);
            DONE:      next_state = DONE;
        endcase
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            state <= RESET_LOW; index <= '0; wait_count <= '0;
        end else begin
            state <= next_state;
            case (state)
                RESET_LOW, SETTLE: wait_count <= (next_state == state) ? wait_count + 1'b1 : '0;
                LOAD:              cmd <= ROM[index];
                NEXT:              index <= index + 1'b1;
                default: ;
            endcase
        end
    end

    assign valid       = (state == WAIT);
    assign cam_reset_n = (state != RESET_LOW);
    assign cam_pwdn    = 1'b0;
    assign done        = (state == DONE);
    assign error       = m_error;

endmodule
