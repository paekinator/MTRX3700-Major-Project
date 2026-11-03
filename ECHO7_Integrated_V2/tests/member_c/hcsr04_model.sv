`timescale 1ns/1ps
/* verilator lint_off PROCASSINIT */
/* verilator lint_off IMPLICITSTATIC */
/* verilator lint_off WIDTHTRUNC */
/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNUSEDPARAM */
/* verilator lint_off BLKSEQ */
/* verilator lint_off MULTIDRIVEN */
/* verilator lint_off REALCVT */
/* verilator lint_off ZERODLY */
// (This file is a simulation model. It is never synthesised, so the lint rules
//  that matter for synthesisable code are relaxed to keep your terminal clean.)
/*
 * ============================================================================
 *  hcsr04_model.sv  --  Behavioural simulation model of the ultrasonic
 *                       distance sensor (RCWL-1601, HC-SR04 compatible)
 * ============================================================================
 *
 *  WHAT IS THIS?
 *  -------------
 *  The Major Project kit has one or two Adafruit 4007 "RCWL-1601" ultrasonic
 *  sensors on the Robot Adaptor Board (sensor 1 on J3, GPIO_1 27/29; sensor 2
 *  on J4, GPIO_1 30/32). The sensor is a tiny computer with a speaker and a
 *  microphone: your FPGA asks it to measure (TRIG), it chirps at 40 kHz,
 *  listens for the reflection, and reports the round-trip time as the width of
 *  a pulse on ECHO. Your driver's only job is to make the TRIG pulse and time
 *  the ECHO pulse. In simulation the sensor is missing, so this model stands
 *  in for it: you tell it how far away the wall is (`distance_mm`) and it
 *  produces the ECHO pulse the real module would.
 *
 *  Like every model in this course it also *talks*: it says what trigger it
 *  saw, what echo it produced, and which rule your driver broke when it
 *  ignores you (trigger too short, trigger while it is still listening, ...).
 *  A real sensor just stays silent, and you spend an afternoon with a scope.
 *
 *  WHERE THE NUMBERS COME FROM
 *  ---------------------------
 *  The RCWL-1601 product page (the PDF on the Ed slide) only says: 3-5.5 V,
 *  2.2 mA, 2 cm to 450 cm, "HC-SR04 compatible, drop it in and it works the
 *  same". It has no timing diagram. So the protocol here is the HC-SR04 one,
 *  from the HC-SR04 user guide (Elec Freaks / Cytron):
 *    - datasheet:  trigger = a TTL pulse of at least 10 us;
 *                  the module then sends 8 cycles of 40 kHz ultrasound;
 *                  ECHO high time = round-trip time, "distance = high time x
 *                  340 m/s / 2", i.e. 58 us per cm;
 *                  range 2 cm to 400 cm (the RCWL-1601 says 450 cm);
 *                  "we suggest to use over 60 ms measurement cycle, in order
 *                  to prevent trigger signal to the echo signal".
 *    - typical (measured on real modules, NOT in any datasheet):
 *                  ECHO rises about 450 us after the trigger ends (the burst
 *                  takes 200 us and the module's firmware adds the rest);
 *                  when nothing reflects, ECHO stays high for about 38 ms and
 *                  then drops by itself (some clones hold it up to 200 ms).
 *    - physics:    speed of sound 343 m/s at 20 C (331 + 0.6 x T). The HC-SR04
 *                  guide rounds it to 340 m/s; Lesson 3-style fixed point in
 *                  sonar_range.sv uses 343 (see the 43.904 MHz trick there).
 *  Each of those sentences is one `if` or one `#delay` below, and each is a
 *  parameter so you can try what happens on a cold day or with a slow clone.
 *
 *  FIDELITY (what is and is not modelled)
 *  ---------------------------------------
 *  Modelled:      the TRIG pulse-width rule, the burst delay, ECHO width from
 *                 distance, the no-echo timeout, the minimum range, ignoring a
 *                 trigger while a measurement is in progress, the 60 ms cycle
 *                 recommendation (as a note), a distance that changes over
 *                 time (sampled when the chirp is sent).
 *  NOT modelled:  acoustics (beam width, soft or angled surfaces that return
 *                 nothing, a second sensor hearing the first one's chirp),
 *                 temperature drift unless you change the parameter, the
 *                 40 kHz burst itself, electrical levels, supply/current.
 *  Like every model, it is only as right as its author's reading of the
 *  documents above. If the board disagrees, the board is right: measure it
 *  and change the parameter (or the model) to match.
 *
 *  HOW TO USE
 *  ----------
 *    hcsr04_model sensor (
 *        .trig(GPIO_1[27]), .echo(GPIO_1[29]),   // sensor 1's two wires (J3)
 *        .distance_mm(wall),                     // what is in front of it (int, mm)
 *        .object_present(1'b1),                  // 0 = nothing in range -> timeout
 *        .measurements(), .errors(), .notes(), .last_echo_us()
 *    );
 *  Call sensor.print_summary() at the end of the simulation.
 * ============================================================================
 */
module hcsr04_model #(
    parameter real SPEED_OF_SOUND_MM_PER_US = 0.343,  // 343 m/s at 20 C
    parameter real T_TRIG_MIN_US            = 10.0,   // datasheet: "10 us TTL pulse"
    parameter real T_TRIG_MAX_US            = 1000.0, // longer than this is "held", not a pulse: flagged
    parameter real T_BURST_DELAY_US         = 450.0,  // typical: trigger end -> ECHO rise (burst + firmware)
    parameter real T_TIMEOUT_MS             = 38.0,   // typical: ECHO high time when nothing comes back
    parameter real T_CYCLE_MIN_MS           = 60.0,   // datasheet: "over 60 ms measurement cycle"
    parameter int  MAX_RANGE_MM             = 4500,   // RCWL-1601: 2 cm to 450 cm
    parameter int  MIN_RANGE_MM             = 20,
    parameter bit  VERBOSE                  = 1,
    parameter string NAME                   = "HCSR04"
) (
    input  logic trig,
    output logic echo,
    input  int   distance_mm,        // what is in front of the sensor right now
    input  logic object_present,     // 0: nothing within range, the echo never comes back
    output int   measurements,       // echoes produced
    output int   errors,             // rules broken (trigger too short / held / while busy)
    output int   notes,              // things worth knowing that are not errors (cycle < 60 ms, below 2 cm)
    output int   last_echo_us        // width of the last ECHO pulse, microseconds (rounded)
);
    // ---- state -----------------------------------------------------------------
    logic    busy       = 1'b0;      // between an accepted trigger and the end of ECHO
    realtime t_rise     = 0;         // when TRIG last went high
    realtime t_last_trig = -1.0e12;  // when the last accepted trigger ended
    event    start_measurement;

    initial begin
        $timeformat(-6, 1, " us", 10);   // print times in microseconds (the testbench may override this)
        echo = 1'b0;
        measurements = 0; errors = 0; notes = 0; last_echo_us = 0;
    end

    function automatic real us(input realtime t);   // ns -> us
        return t / 1000.0;
    endfunction

    task automatic say(input string msg);
        if (VERBOSE) $display("[%s @%0t] %s", NAME, $time, msg);
    endtask
    task automatic problem(input string msg);
        errors++;
        $display("[%s @%0t] PROBLEM: %s", NAME, $time, msg);
    endtask
    task automatic note(input string msg);
        notes++;
        $display("[%s @%0t] note: %s", NAME, $time, msg);
    endtask

    // ---- the trigger pulse -----------------------------------------------------
    always @(posedge trig) begin
        t_rise = $realtime;
        if (busy)
            problem("TRIG while a measurement is still in progress (ECHO not finished). The module ignores it: wait for ECHO to fall, and leave 60 ms between measurements.");
    end

    real width;                      // (declared here, not in the block: a block-local initialiser would run only once)
    always @(negedge trig) begin
        width = us($realtime - t_rise);
        if (busy) begin
            // already reported at the rising edge
        end else if (width < T_TRIG_MIN_US) begin
            problem($sformatf("TRIG pulse of %0.2f us ignored: the module needs at least %0.0f us high. (At 50 MHz that is %0d clock cycles.)",
                              width, T_TRIG_MIN_US, int'(T_TRIG_MIN_US * 50.0)));
        end else begin
            if (width > T_TRIG_MAX_US)
                problem($sformatf("TRIG held high for %0.1f ms. The datasheet asks for a 10 us pulse; a real module's behaviour with a held trigger is not specified (some fire on the rising edge, some on the falling edge). Measuring anyway, from the falling edge.", width / 1000.0));
            if (($realtime - t_last_trig) < T_CYCLE_MIN_MS * 1.0e6)
                note($sformatf("trigger only %0.1f ms after the previous one (datasheet: over %0.0f ms between measurements). A real module can still be hearing the previous chirp's reflections and return the wrong distance.",
                               ($realtime - t_last_trig) / 1.0e6, T_CYCLE_MIN_MS));
            t_last_trig = $realtime;
            busy = 1'b1;
            -> start_measurement;
            if (VERBOSE) say($sformatf("TRIG pulse %0.1f us: OK, sending the 40 kHz burst", width));
        end
    end

    // ---- the measurement -------------------------------------------------------
    // One chirp at a time. The distance is sampled when the chirp leaves (that is
    // what physically sets the round-trip time), so a testbench can change it at any
    // time and only the next measurement sees the new value.
    real     d_mm;
    real     width_us;
    logic    timed_out;
    always begin
        @(start_measurement);
        #(T_BURST_DELAY_US * 1000.0);
        d_mm = real'(distance_mm);
        timed_out = !object_present || (distance_mm > MAX_RANGE_MM) || (distance_mm < 0);
        if (timed_out) begin
            width_us = T_TIMEOUT_MS * 1000.0;
            say($sformatf("nothing reflects (%s): ECHO will stay high for the %0.0f ms timeout and then drop by itself",
                          !object_present ? "no object" : $sformatf("%0d mm is beyond the %0d mm range", distance_mm, MAX_RANGE_MM), T_TIMEOUT_MS));
        end else begin
            width_us = 2.0 * d_mm / SPEED_OF_SOUND_MM_PER_US;
            if (distance_mm < MIN_RANGE_MM)
                note($sformatf("%0d mm is below the %0d mm minimum range; a real module returns garbage this close (the echo arrives while it is still chirping).", distance_mm, MIN_RANGE_MM));
        end
        echo = 1'b1;
        #(width_us * 1000.0);
        echo = 1'b0;
        measurements++;
        last_echo_us = int'(width_us + 0.5);
        if (timed_out)
            say($sformatf("ECHO timed out after %0.1f ms: no object. A driver that only counts must cap its count somewhere.", width_us / 1000.0));
        else
            say($sformatf("trigger -> echo %0d us = %0d mm (round trip at %0.0f m/s: %0.2f us per mm)",
                          last_echo_us, distance_mm, SPEED_OF_SOUND_MM_PER_US * 1000.0, 2.0 / SPEED_OF_SOUND_MM_PER_US));
        busy = 1'b0;
    end

    // ---- summary -----------------------------------------------------------------
    task automatic print_summary();
        $display("---------------------------------------------------------------");
        $display("%s model at %0t: %0d measurement(s) answered, %0d problem(s), %0d note(s). Last ECHO %0d us.",
                 NAME, $time, measurements, errors, notes, last_echo_us);
        $display("  Rules used: TRIG >= %0.0f us; ECHO starts %0.0f us after TRIG ends; width = 2 x distance / %0.3f mm/us; timeout %0.0f ms; cycle >= %0.0f ms.",
                 T_TRIG_MIN_US, T_BURST_DELAY_US, SPEED_OF_SOUND_MM_PER_US, T_TIMEOUT_MS, T_CYCLE_MIN_MS);
        $display("---------------------------------------------------------------");
    endtask
endmodule
