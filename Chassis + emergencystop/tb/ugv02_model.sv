`timescale 1ns/1ps
/* verilator lint_off PROCASSINIT */
/* verilator lint_off IMPLICITSTATIC */
/* verilator lint_off WIDTHTRUNC */
/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNUSEDPARAM */
/* verilator lint_off BLKSEQ */
/* verilator lint_off REALCVT */
/* verilator lint_off MULTIDRIVEN */
// (This file is a simulation model. It is never synthesised, so the lint rules
//  that matter for synthesisable code are relaxed to keep your terminal clean.)
/*
 * ============================================================================
 *  ugv02_model.sv  --  Behavioural simulation model of the Waveshare UGV02
 *                      chassis: JSON commands in on the UART, a moving robot out
 * ============================================================================
 *
 *  WHAT IS THIS?
 *  -------------
 *  The UGV02 is the chassis your FPGA drives. An ESP32 inside it listens on the
 *  40-pin header's UART for one line of JSON per command, and turns
 *  {"T":11,"L":<pwm>,"R":<pwm>} into a drive for the left and the right wheels.
 *  On the bench the chassis is missing, so this model stands in for it:
 *
 *      your design --TX--> [ UART receiver -> lines -> JSON parser ] -> [ wheels + kinematics ] -> pose
 *
 *    - every byte is received the way a UART does it (start edge, mid-bit
 *      samples), and the sender's baud rate is measured from the edges;
 *    - bytes are assembled into lines, each line is parsed as JSON, and the
 *      model says in words what it understood ("PWM left +102, right +77 =
 *      ... forward at 0.175 m/s while turning right at 0.24 rad/s") or why it
 *      ignored the line;
 *    - then the robot moves: each wheel's speed follows its command through a
 *      first-order lag, differential-drive kinematics turn the two wheel speeds
 *      into a forward speed and a turning rate, and the pose (x, y, heading)
 *      is integrated. The testbench, and the world model (robot_world.sv) that
 *      draws what the camera sees, read the pose from here.
 *
 *  Coordinates: x and y in metres on the floor, heading in radians measured
 *  anticlockwise from the +x axis (seen from above). Heading 0 means the robot
 *  faces +x, and +y is on its left. The heading is NOT wrapped: two full turns
 *  read 4 pi, which is what you want when you check a spin.
 *
 *  WHERE THE NUMBERS COME FROM
 *  ---------------------------
 *    - UART: 115200 baud, 8N1, one JSON object per line ending in "\n"
 *      (Waveshare wiki, UGV02).
 *    - {"T":11,"L":p,"R":q}: the PWM of the left and the right motors, whole
 *      numbers from -255 to +255, open loop (Waveshare wiki "JSON command set";
 *      the lab's technical staff, October 2026: T:11 drives the same way on
 *      both of the lab's firmwares, 0.90 and 0.96). This is the command to use.
 *    - {"T":1,"L":x,"R":y}: wheel speeds in m/s, each in -0.5 .. +0.5. On the
 *      0.96 firmware a PID drives each wheel to the speed using its encoder,
 *      and it surges and stalls below about 0.2 m/s; on the 0.90 firmware it
 *      sets PWM = 512 x speed. This model drives T:1 smoothly at the
 *      speed asked for, and says once that T:11 is the command to use.
 *    - The chassis stops by itself 3 s after the last drive command, T:1 or
 *      T:11 (its heartbeat).
 *    - ASSUMED, because nobody has measured them yet. Each is a parameter;
 *      measure them on a robot and change the numbers here:
 *        V_PER_PWM 1/512 m/s per PWM step: the speed a wheel settles at for a
 *                          given T:11 PWM. 1/512 is the conversion the 0.90
 *                          firmware itself uses for T:1 (PWM = 512 x m/s), so
 *                          PWM 102 is 0.2 m/s. Waveshare now lists the UGV02
 *                          at up to 1.3 m/s (older listings: 0.41 m/s), so a
 *                          newer robot may well be faster per PWM step.
 *        PWM_DEADBAND 0    a PWM smaller than this does not turn the motor
 *                          (Waveshare's wiki warns that a small PWM may not
 *                          turn the motor). Below it, the model notes the
 *                          command but does not count it as a problem.
 *        TAU_S     0.15 s  each wheel's speed follows its command through a
 *                          first-order lag with this time constant
 *        TRACK_M   0.20 m  EFFECTIVE track width. The UGV02 skid-steers: its
 *                          wheels slip sideways in a turn, so it turns more
 *                          slowly than the tape-measure distance between the
 *                          wheels predicts. Measure it: command a spin, time a
 *                          full turn, and with the wheel speeds L and R in m/s,
 *                          TRACK_M = (R - L) x time / (2 pi).
 *        LATENCY_S 0 s     from the end of a line to the motors acting on it
 *    - ASSUMED behaviour where the documents are silent: a PWM outside -255 ..
 *      +255 or a speed outside -0.5 .. +0.5 is clamped (and reported); a PWM
 *      that is not a whole number is rounded (and reported), as the 0.96
 *      firmware does; a line that does not parse is ignored and the wheels
 *      keep the last command; only a valid T:1 or T:11 command restarts the
 *      3 s heartbeat; a byte with a framing error spoils its line.
 *    - The real chassis is more forgiving than this model's parser: its JSON
 *      library accepts single quotes, unquoted keys and numbers such as +5 or
 *      .5, and the 0.96 firmware reads a line with no "T" as T:0 (its
 *      emergency stop) and a missing "L" or "R" as 0. This model reports every
 *      such line as a problem instead, so that a design never depends on them.
 *
 *  FIDELITY (what is and is not modelled)
 *  ---------------------------------------
 *  Modelled:      UART receive with mid-bit sampling; framing errors; the
 *                 sender's baud rate measured from every byte's edges and
 *                 reported when it is more than BAUD_TOL_PCT off; line assembly
 *                 ("\r" ignored, over-long lines dropped); a strict parser for
 *                 one flat JSON object per line (keys in any order, spaces
 *                 where JSON allows them, numbers exactly as JSON writes them);
 *                 T:11 PWM and T:1 speed control, with clamping; a PWM
 *                 deadband (if you set one); the wheels' lag;
 *                 differential-drive kinematics; the 3 s heartbeat stop.
 *  NOT modelled:  everything the chassis sends back (its TX line stays idle
 *                 high: no telemetry stream, no answer to {"T":130}); every
 *                 command other than T:1 and T:11; T:1's surging below
 *                 0.2 m/s on the 0.96 firmware; the battery's charge (a
 *                 flatter battery is slower at the same PWM);
 *                 acceleration and current limits beyond the first-order lag;
 *                 wheel slip other than through TRACK_M; bumps and
 *                 collisions (the robot drives straight through objects; the
 *                 world model says so); the IMU; the ESP32's own timing jitter.
 *  The integration is exact for any stretch in which the two wheels keep a
 *  fixed ratio (a straight line, a spin, a circular arc), so the pose matches
 *  the textbook formulae to a micrometre.
 *  Like every model, it is only as right as its author's reading of the
 *  documents above, and nothing here has met a real UGV02 yet. When the robot
 *  and the model disagree, the robot is right: change the model.
 *
 *  HOW TO USE
 *  ----------
 *    real x, y, h, vl, vr, cl, cr; int n_cmd, n_prob;
 *    ugv02_model chassis (
 *        .rx(GPIO_1[31]),          // the FPGA's TX to the chassis
 *        .tx(GPIO_1[33]),          // the chassis's TX (idle high here)
 *        .x_m(x), .y_m(y), .heading_rad(h), .v_left(vl), .v_right(vr),
 *        .cmd_left(cl), .cmd_right(cr), .commands(n_cmd), .problems(n_prob));
 *    initial chassis.set_pose(0.0, 0.0, 30.0);   // x m, y m, heading in DEGREES; at rest
 *  The outputs are refreshed every DT_S; call chassis.update() first if you
 *  need them exact at this instant. chassis.print_summary() at the end.
 * ============================================================================
 */
module ugv02_model #(
    parameter real   BAUD         = 115200.0,  // 8N1 (Waveshare wiki)
    parameter real   V_MAX        = 0.5,       // m/s: the T:1 limit on |L| and |R| (wiki JSON command set)
    parameter int    PWM_MAX      = 255,       // the T:11 limit on |L| and |R| (wiki JSON command set)
    parameter real   V_PER_PWM    = 1.0 / 512.0, // ASSUMED: m/s a wheel settles at per T:11 PWM step (0.90's T:1 conversion)
    parameter int    PWM_DEADBAND = 0,         // ASSUMED: a |PWM| below this does not turn the motor
    parameter real   TAU_S        = 0.15,      // ASSUMED: first-order lag of each wheel's speed
    parameter real   TRACK_M      = 0.20,      // ASSUMED: effective track width (skid steering)
    parameter real   TIMEOUT_S    = 3.0,       // heartbeat: stop when no motion command for this long (Waveshare wiki)
    parameter real   LATENCY_S    = 0.0,       // ASSUMED: end of the line to the motors acting on it
    parameter real   DT_S         = 0.001,     // integration step and output refresh (numerics, not physics)
    parameter real   BAUD_TOL_PCT = 2.0,       // report a sender whose baud rate is further off than this
    parameter int    MAX_LINE     = 256,       // longer lines are dropped
    parameter int    MAX_SAID     = 1000,      // accepted commands narrated before the model goes quiet
    parameter int    MAX_WARN     = 10,        // warnings of each kind printed before only counting them
    parameter bit    VERBOSE      = 1,
    parameter string NAME         = "UGV02"
) (
    input  logic rx,             // the chassis's RX: your design's TX
    output logic tx,             // the chassis's TX: idle high (telemetry not modelled)
    output real  x_m,            // pose: position on the floor
    output real  y_m,
    output real  heading_rad,    //   anticlockwise from +x, not wrapped
    output real  v_left,         // each wheel's speed now, m/s
    output real  v_right,
    output real  cmd_left,       // the speeds the wheels are following (after clamping; 0 after a heartbeat stop)
    output real  cmd_right,
    output int   commands,       // drive commands accepted (T:1 and T:11)
    output int   problems        // everything reported as a problem (see print_summary)
);
    localparam real PI    = 3.14159265358979;
    localparam real T_BIT = 1.0e9 / BAUD;          // one bit, in ns (8680.6 ns at 115200)

    // ---- the state ------------------------------------------------------------
    real x = 0.0, y = 0.0, th = 0.0;               // pose
    real vl = 0.0, vr = 0.0;                       // wheel speeds now
    real tl = 0.0, tr = 0.0;                       // wheel speeds commanded
    real t_int = 0.0;                              // the pose is integrated up to this time (s)
    real t_last_cmd = -1.0;                        // when the last drive command was accepted (s); -1 = never
    real t_cmd_s = -1.0;                           // when the last drive command took effect (s), for benches
    real t_timeout_s = -1.0;                       // when the last heartbeat stop happened (s), for benches
    bit  timed_out = 0;
    real odometer_m = 0.0, turned_rad = 0.0;       // distance driven, rotation turned (both counted positive)
    int  lines = 0, n_malformed = 0, n_unknown = 0, n_clamped = 0, n_framing = 0, n_baud = 0,
         n_glitch = 0, n_overflow = 0, n_timeouts = 0, n_said = 0, n_t1 = 0, n_t11 = 0, n_fraction = 0, n_deadband = 0;
    real last_l = 1.0e9, last_r = 1.0e9;           // the previous accepted command, to narrate changes only
    string last_line = "";                         // the last complete line received, for benches

    initial begin
        tx = 1'b1;
        commands = 0; problems = 0;
        publish();
    end

    function automatic real now_s();
        return $realtime / 1.0e9;                  // timescale 1ns
    endfunction
    function automatic string stamp();
        return $sformatf("[%s @%0.6f s]", NAME, now_s());
    endfunction
    function automatic real absr(input real v);
        return (v < 0.0) ? -v : v;
    endfunction
    // A conditional between two string literals of different lengths is a padded vector, not a
    // string; choosing through a function keeps them strings (the camera model's pick() does the same).
    function automatic string sel(input bit c, input string a, input string b);
        return c ? a : b;
    endfunction
    function automatic string signed3(input real v);   // "+0.250" / "-0.250"
        return $sformatf("%s%0.3f", (v < 0.0) ? "-" : "+", absr(v));
    endfunction

    // A warning of one kind, printed up to MAX_WARN times, then only counted.
    function automatic void warn(input int count_after, input string kind, input string msg);
        problems++;
        if (count_after <= MAX_WARN)
            $display("%s %s: %s%s", stamp(), kind, msg,
                     (count_after == MAX_WARN) ? $sformatf(" (further %s reports are counted, not printed)", kind) : "");
    endfunction

    // ---- the robot moves ------------------------------------------------------
    // One step of h seconds with the commands fixed. Exact: the wheel speeds are
    // exponentials, the distance each wheel covers is their integral, and the
    // centre moves along the arc that the two distances describe.
    function automatic void step(input real h);
        real a, sl, sr, ds, dth, chord;
        a  = $exp(-h / TAU_S);                     // TAU_S = 0 gives a = 0: no lag
        sl = tl * h + (vl - tl) * TAU_S * (1.0 - a);
        sr = tr * h + (vr - tr) * TAU_S * (1.0 - a);
        vl = tl + (vl - tl) * a;
        vr = tr + (vr - tr) * a;
        ds  = (sl + sr) / 2.0;                     // the centre moves the mean of the two wheels
        dth = (sr - sl) / TRACK_M;                 // and turns by their difference over the track
        chord = (absr(dth) < 1.0e-12) ? ds : 2.0 * (ds / dth) * $sin(dth / 2.0);
        x  += chord * $cos(th + dth / 2.0);
        y  += chord * $sin(th + dth / 2.0);
        th += dth;
        odometer_m += absr(ds);
        turned_rad += absr(dth);
    endfunction

    function automatic void integrate(input real t);
        real h;
        while (t - t_int > 1.0e-12) begin
            h = (t - t_int < DT_S) ? (t - t_int) : DT_S;
            step(h);
            t_int += h;
        end
    endfunction

    function automatic void publish();
        x_m = x; y_m = y; heading_rad = th; v_left = vl; v_right = vr; cmd_left = tl; cmd_right = tr;
    endfunction

    // Integrate up to time t, applying the heartbeat stop on the way if it falls due.
    function automatic void advance_to(input real t);
        real t_stop;
        if (!timed_out && t_last_cmd >= 0.0 && (tl != 0.0 || tr != 0.0) && t_last_cmd + TIMEOUT_S <= t) begin
            t_stop = t_last_cmd + TIMEOUT_S;
            integrate(t_stop);
            timed_out = 1; tl = 0.0; tr = 0.0; n_timeouts++; t_timeout_s = t_stop;
            $display("[%s @%0.6f s] no motion command for %0.1f s: the chassis's heartbeat stops the wheels (they slow down through the %0.2f s lag). Send a command more often than every %0.1f s.",
                     NAME, t_stop, TIMEOUT_S, TAU_S, TIMEOUT_S);
        end
        integrate(t);
        publish();
    endfunction

    // Bring the outputs up to this instant (benches call this before reading the pose).
    function automatic void update();
        advance_to(now_s());
    endfunction

    // The starting pose: the robot is lifted, put down at (x, y) facing heading_deg, at rest.
    function automatic void set_pose(input real x0, input real y0, input real heading_deg);
        advance_to(now_s());
        x = x0; y = y0; th = heading_deg * PI / 180.0;
        vl = 0.0; vr = 0.0; tl = 0.0; tr = 0.0; t_last_cmd = -1.0; timed_out = 0;
        publish();
        if (VERBOSE) $display("%s put down at x = %0.3f m, y = %0.3f m, heading %0.1f deg, at rest", stamp(), x0, y0, heading_deg);
    endfunction

    always begin : clock_of_the_model           // refresh the outputs and check the heartbeat
        #(DT_S * 1.0e9);
        advance_to(now_s());
    end

    // ---- a command takes effect ---------------------------------------------------
    function automatic void apply(input real l, input real r);
        advance_to(now_s());
        tl = l; tr = r; timed_out = 0; t_cmd_s = now_s();
        publish();
    endfunction

    task automatic schedule(input real l, input real r);
        if (LATENCY_S <= 0.0) apply(l, r);
        else fork
            begin #(LATENCY_S * 1.0e9); apply(l, r); end
        join_none
    endtask

    // What a pair of wheel speeds means, in words.
    function automatic string meaning(input real l, input real r);
        real v = (l + r) / 2.0, w = (r - l) / TRACK_M;
        if (l == 0.0 && r == 0.0) return "stop";
        if (l == r) return $sformatf("straight %s at %0.3f m/s", sel(v > 0.0, "ahead", "back"), absr(v));
        if (l == -r) return $sformatf("spin on the spot, %s at %0.2f rad/s (%0.0f deg/s)",
                                      sel(w > 0.0, "anticlockwise (left)", "clockwise (right)"), absr(w), absr(w) * 180.0 / PI);
        return $sformatf("%s at %0.3f m/s while turning %s at %0.2f rad/s (%0.0f deg/s, radius %0.2f m)",
                         sel(v >= 0.0, "forward", "backward"), absr(v), sel(w > 0.0, "left", "right"),
                         absr(w), absr(w) * 180.0 / PI, absr(v / w));
    endfunction

    // ---- the parser: one flat JSON object ---------------------------------------
    // Fills the values of T, L and R if present. Returns "" when the line is valid JSON,
    // otherwise the reason in words.
    string p_s; int p_i;
    function automatic void p_ws();
        while (p_i < p_s.len() && (p_s[p_i] == " " || p_s[p_i] == "\t")) p_i++;
    endfunction
    function automatic bit is_digit(input byte c);
        return c >= "0" && c <= "9";
    endfunction
    // A JSON number starting at p_i: -?(0|[1-9][0-9]*)(.[0-9]+)?([eE][+-]?[0-9]+)?
    function automatic string p_number(input string key, output real v);
        int s = p_i;
        string tok;
        v = 0.0;
        if (p_i < p_s.len() && p_s[p_i] == "+") return $sformatf("the value of \"%s\" starts with '+': JSON numbers have no plus sign", key);
        if (p_i < p_s.len() && p_s[p_i] == "-") p_i++;
        if (p_i < p_s.len() && p_s[p_i] == ".") return $sformatf("the value of \"%s\" starts with '.': JSON needs a digit before the point (0.25, not .25)", key);
        if (p_i >= p_s.len() || !is_digit(p_s[p_i])) return $sformatf("the value of \"%s\" is not a number", key);
        if (p_s[p_i] == "0" && p_i + 1 < p_s.len() && is_digit(p_s[p_i + 1])) return $sformatf("the value of \"%s\" has a leading zero (JSON allows 0.5 but not 00.5 or 05)", key);
        while (p_i < p_s.len() && is_digit(p_s[p_i])) p_i++;
        if (p_i < p_s.len() && p_s[p_i] == ".") begin
            p_i++;
            if (p_i >= p_s.len() || !is_digit(p_s[p_i])) return $sformatf("the value of \"%s\" has no digit after the point (0.5, not 0.)", key);
            while (p_i < p_s.len() && is_digit(p_s[p_i])) p_i++;
        end
        if (p_i < p_s.len() && (p_s[p_i] == "e" || p_s[p_i] == "E")) begin
            p_i++;
            if (p_i < p_s.len() && (p_s[p_i] == "+" || p_s[p_i] == "-")) p_i++;
            if (p_i >= p_s.len() || !is_digit(p_s[p_i])) return $sformatf("the value of \"%s\" has an exponent with no digits", key);
            while (p_i < p_s.len() && is_digit(p_s[p_i])) p_i++;
        end
        tok = p_s.substr(s, p_i - 1);
        v = tok.atoreal();
        return "";
    endfunction

    function automatic string parse(input string s, output bit has_t, output real t_val,
                                    output bit has_l, output real l_val, output bit has_r, output real r_val,
                                    output string extra_keys);
        string key, why;
        real v;
        bit is_num;
        has_t = 0; has_l = 0; has_r = 0; t_val = 0.0; l_val = 0.0; r_val = 0.0; extra_keys = "";
        p_s = s; p_i = 0;
        p_ws();
        if (p_i >= p_s.len()) return "the line is empty";
        if (p_s[p_i] != "{") return $sformatf("it does not start with '{' (it starts with '%s')", printable(p_s.substr(p_i, p_i)));
        p_i++; p_ws();
        if (p_i < p_s.len() && p_s[p_i] == "}") return "the object is empty: {}";
        forever begin
            // "key"
            p_ws();
            if (p_i >= p_s.len()) return "the line ends inside the object (no closing '}')";
            if (p_s[p_i] == "'") return "keys need double quotes (\"T\"), not single quotes";
            if (p_s[p_i] != "\"") return $sformatf("expected a quoted key at character %0d, found '%s'", p_i + 1, printable(p_s.substr(p_i, p_i)));
            p_i++; key = "";
            while (p_i < p_s.len() && p_s[p_i] != "\"") begin key = {key, p_s.substr(p_i, p_i)}; p_i++; end
            if (p_i >= p_s.len()) return $sformatf("the key \"%s has no closing quote", key);
            p_i++; p_ws();
            if (p_i >= p_s.len() || p_s[p_i] != ":") return $sformatf("expected ':' after the key \"%s\"", key);
            p_i++; p_ws();
            if (p_i >= p_s.len()) return $sformatf("the key \"%s\" has no value", key);
            // the value: a string, true/false/null, or a number
            is_num = 0;
            if (p_s[p_i] == "\"") begin
                p_i++;
                while (p_i < p_s.len() && p_s[p_i] != "\"") p_i++;
                if (p_i >= p_s.len()) return $sformatf("the string value of \"%s\" has no closing quote", key);
                p_i++;
            end else if (p_s.substr(p_i, p_i + 3) == "true" || p_s.substr(p_i, p_i + 3) == "null") p_i += 4;
            else if (p_s.substr(p_i, p_i + 4) == "false") p_i += 5;
            else begin
                why = p_number(key, v);
                if (why != "") return why;
                is_num = 1;
            end
            if (key == "T" || key == "L" || key == "R") begin
                if (!is_num) return $sformatf("the value of \"%s\" must be a number", key);
                if (key == "T") begin has_t = 1; t_val = v; end
                if (key == "L") begin has_l = 1; l_val = v; end
                if (key == "R") begin has_r = 1; r_val = v; end
            end else extra_keys = {extra_keys, sel(extra_keys == "", "", ", "), "\"", key, "\""};
            // , or }
            p_ws();
            if (p_i >= p_s.len()) return "the line ends inside the object (no closing '}')";
            if (p_s[p_i] == "}") begin
                p_i++; p_ws();
                if (p_i < p_s.len()) return $sformatf("there is text after the closing '}': \"%s\"", printable(p_s.substr(p_i, p_s.len() - 1)));
                return "";
            end
            if (p_s[p_i] != ",") return $sformatf("expected ',' or '}' after the value of \"%s\", found '%s'", key, printable(p_s.substr(p_i, p_i)));
            p_i++;
        end
    endfunction

    // A line for printing: control characters as \xNN.
    function automatic string printable(input string s);
        string o = "";
        for (int i = 0; i < s.len(); i++)
            o = {o, (s[i] >= 8'h20 && s[i] < 8'h7F) ? s.substr(i, i) : $sformatf("\\x%02x", s[i])};
        return o;
    endfunction

    // A T:11 value as the PWM the motor gets: a whole number (rounded), within -PWM_MAX .. +PWM_MAX,
    // and 0 if it is inside the deadband.
    function automatic int pwm_of(input string which, input real v);
        real w = (v < 0.0) ? -$floor(-v + 0.5) : $floor(v + 0.5);
        int  p;
        if (w != v) begin
            n_fraction++;
            warn(n_fraction, "PWM NOT WHOLE", $sformatf("%s = %0.3f: a PWM is a whole number; rounded to %0d, as the 0.96 firmware does", which, v, $rtoi(w)));
        end
        if (w > real'(PWM_MAX) || w < -real'(PWM_MAX)) begin
            n_clamped++;
            warn(n_clamped, "PWM CLAMPED", $sformatf("%s = %0d is outside the chassis's -%0d .. +%0d: using %s%0d", which, $rtoi(w), PWM_MAX, PWM_MAX, (w < 0.0) ? "-" : "+", PWM_MAX));
            w = (w < 0.0) ? -real'(PWM_MAX) : real'(PWM_MAX);
        end
        p = $rtoi(w);
        if (p != 0 && p > -PWM_DEADBAND && p < PWM_DEADBAND) begin
            n_deadband++;                              // a note, not a problem: a design closing in on a target sends small PWMs
            if (n_deadband <= MAX_WARN)
                $display("%s note: %s = %0d is below the motor's deadband (%0d): the wheel does not turn%s", stamp(), which, p, PWM_DEADBAND,
                         (n_deadband == MAX_WARN) ? " (further notes like this are counted, not printed)" : "");
            p = 0;
        end
        return p;
    endfunction

    function automatic real clamp(input string which, input real v);
        if (v > V_MAX || v < -V_MAX) begin
            n_clamped++;
            warn(n_clamped, "SPEED CLAMPED", $sformatf("%s = %0.3f m/s is outside the chassis's -%0.1f .. +%0.1f m/s: using %s%0.1f m/s", which, v, V_MAX, V_MAX, (v < 0.0) ? "-" : "+", V_MAX));
            return (v < 0.0) ? -V_MAX : V_MAX;
        end
        return v;
    endfunction

    // ---- what the chassis does with a line ------------------------------------------
    task automatic process_line(input string s);
        bit has_t, has_l, has_r;
        real t_val, l_val, r_val, l, r;
        int  pl, pr;
        string why, extra, how;
        lines++;
        last_line = s;
        why = parse(s, has_t, t_val, has_l, l_val, has_r, r_val, extra);
        if (why == "" && !has_t) why = "it has no \"T\" (the command number)";
        if (why == "" && t_val != $floor(t_val)) why = $sformatf("\"T\" must be a whole number, not %0.3f", t_val);
        if (why == "" && (t_val == 1.0 || t_val == 11.0) && !(has_l && has_r))
            why = $sformatf("a T:%0d command needs both \"L\" and \"R\" (this one has %s)", int'(t_val), sel(has_l, "only L", sel(has_r, "only R", "neither")));
        if (why != "") begin
            n_malformed++;
            warn(n_malformed, "LINE IGNORED", $sformatf("\"%s\": %s. The wheels keep the last command.", printable(s), why));
            return;
        end
        if (t_val != 1.0 && t_val != 11.0) begin
            n_unknown++;
            warn(n_unknown, "COMMAND NOT MODELLED", $sformatf("\"%s\": T:%0d %s; ignored, the wheels keep the last command",
                 printable(s), int'(t_val), sel(t_val == 130.0, "asks for one line of telemetry, which this model does not send",
                                                                 "is not a command this model knows (it models T:11, PWM, and T:1, speed)")));
            return;
        end
        if (t_val == 11.0) begin
            pl = pwm_of("L", l_val);
            pr = pwm_of("R", r_val);
            l = real'(pl) * V_PER_PWM;
            r = real'(pr) * V_PER_PWM;
            n_t11++;
            how = $sformatf("PWM left %s%0d, right %s%0d = ", (pl < 0) ? "-" : "+", (pl < 0) ? -pl : pl, (pr < 0) ? "-" : "+", (pr < 0) ? -pr : pr);
        end else begin
            l = clamp("L", l_val);
            r = clamp("R", r_val);
            n_t1++;
            how = "";
            if (n_t1 == 1)
                $display("%s note: T:1 is speed control. On the robots with the 0.96 firmware it surges and stalls below about 0.2 m/s; T:11 (PWM, -255 to 255) sets the motor PWM directly on both firmwares. This model drives T:1 smoothly.", stamp());
        end
        commands++;
        t_last_cmd = now_s();
        if (VERBOSE && (l != last_l || r != last_r)) begin
            n_said++;
            if (n_said <= MAX_SAID)
                $display("%s <- %s  %sleft %s m/s, right %s m/s: %s%s%s", stamp(), printable(s), how, signed3(l), signed3(r), meaning(l, r),
                         (extra != "") ? $sformatf(" (keys %s ignored)", extra) : "",
                         sel(n_said == MAX_SAID, " (further commands are counted, not printed)", ""));
        end
        last_l = l; last_r = r;
        schedule(l, r);
    endtask

    // ---- line assembly -------------------------------------------------------------
    string line = "";
    bit overflow = 0;
    int bad_bytes = 0;                               // bytes with framing errors in the current line
    task automatic take_byte(input logic [7:0] b);
        if (b == 8'h0A) begin
            if (bad_bytes != 0) begin
                n_malformed++;
                warn(n_malformed, "LINE IGNORED", $sformatf("\"%s\": %0d of its bytes arrived with framing errors, so the line cannot be trusted", printable(line), bad_bytes));
            end else if (overflow) begin
                // already reported
            end else process_line(line);
            line = ""; overflow = 0; bad_bytes = 0;
        end else if (b == 8'h0D) begin
            // "\r" before the "\n" is ignored
        end else if (overflow) begin
        end else if (line.len() >= MAX_LINE) begin
            overflow = 1; n_overflow++;
            warn(n_overflow, "LINE TOO LONG", $sformatf("more than %0d bytes without a newline (\"%s...\"); dropped up to the next \"\\n\". Does every command end in \"\\n\"?", MAX_LINE, printable(line.substr(0, 39))));
        end else line = {line, $sformatf("%c", b)};
    endtask

    // ---- the UART receiver ------------------------------------------------------------
    // Edges inside a frame are timed from the start edge; the last one gives the sender's bit time.
    logic in_frame = 1'b0;
    realtime t_start = 0, t_edge_last = 0, t_edge_prev = 0;
    realtime shortest = 0;                           // shortest pulse on the line since the last framing report
    always @(rx) begin
        if (t_edge_prev != 0 && ($realtime - t_edge_prev) > 1.0 && (shortest == 0 || ($realtime - t_edge_prev) < shortest))
            shortest = $realtime - t_edge_prev;
        t_edge_prev = $realtime;
        if (in_frame) t_edge_last = $realtime;
    end

    logic [7:0] rb;
    logic       stop_bit;
    int         k_last;
    real        bit_ns, baud_est;
    always begin : receiver
        @(negedge rx);
        t_start = $realtime; t_edge_last = 0; in_frame = 1'b1;
        #(T_BIT / 2.0);
        if (rx !== 1'b0) begin
            in_frame = 1'b0; n_glitch++;
            warn(n_glitch, "GLITCH", $sformatf("the line went low but was high again half a bit (%0.2f us) later: not a start bit, ignored", T_BIT / 2000.0));
        end else begin
            for (int i = 0; i < 8; i++) begin #(T_BIT); rb[i] = rx; end
            #(T_BIT); stop_bit = rx;
            in_frame = 1'b0;
            // The sender's bit time, from the last edge inside the frame and the bit boundary it should be on.
            if (t_edge_last > t_start) begin
                k_last = $rtoi((t_edge_last - t_start) / T_BIT + 0.5);   // nearest bit boundary ($rtoi truncates)
                if (k_last >= 1) begin
                    bit_ns = (t_edge_last - t_start) / real'(k_last);
                    baud_est = 1.0e9 / bit_ns;
                    if (absr(bit_ns / T_BIT - 1.0) * 100.0 > BAUD_TOL_PCT && stop_bit === 1'b1) begin
                        n_baud++;
                        warn(n_baud, "BAUD RATE", $sformatf("byte 0x%02x arrived at about %0.0f baud, %0.1f %% %s than %0.0f. A UART tolerates about 4 %% in all, so this works only just, if at all: check CLKS_PER_BIT (clock / baud, rounded)",
                             rb, baud_est, absr(bit_ns / T_BIT - 1.0) * 100.0, sel(bit_ns > T_BIT, "slower", "faster"), BAUD));
                    end
                end
            end
            if (stop_bit !== 1'b1) begin
                n_framing++; bad_bytes++;
                warn(n_framing, "FRAMING ERROR", $sformatf("the stop bit after byte 0x%02x was 0. %s",
                     rb, (shortest > 1.5 * T_BIT) ? $sformatf("The shortest pulse on the line so far is %0.2f us, but a bit at %0.0f baud lasts %0.2f us: the sender looks like it runs at about %0.0f baud.",
                                                              shortest / 1000.0, BAUD, T_BIT / 1000.0, 1.0e9 / shortest)
                                                 : "Wrong baud rate, a missing stop bit, or the line held low (does your TX idle high?)."));
                shortest = 0;
            end else take_byte(rb);
        end
    end

    // ---- the end -------------------------------------------------------------------------
    task automatic print_summary();
        update();
        $display("---------------------------------------------------------------");
        $display("%s chassis model at %0.3f s: %0d line(s) received, %0d drive command(s) accepted (%0d T:11, %0d T:1), %0d problem(s).", NAME, now_s(), lines, commands, n_t11, n_t1, problems);
        $display("  ignored lines %0d, commands not modelled %0d, clamped values %0d, PWMs not whole %0d, below the deadband %0d, framing errors %0d, baud warnings %0d, glitches %0d, over-long lines %0d, heartbeat stops %0d",
                 n_malformed, n_unknown, n_clamped, n_fraction, n_deadband, n_framing, n_baud, n_glitch, n_overflow, n_timeouts);
        $display("  pose: x = %0.3f m, y = %0.3f m, heading %0.1f deg; wheels L %s R %s m/s, commanded L %s R %s m/s",
                 x, y, th * 180.0 / PI, signed3(vl), signed3(vr), signed3(tl), signed3(tr));
        $display("  driven %0.3f m, turned %0.1f deg in all. ASSUMED: %0.5f m/s per PWM step (PWM 255 = %0.2f m/s), deadband %0d, lag %0.2f s, effective track %0.2f m, latency %0.3f s (calibrate on a robot).",
                 odometer_m, turned_rad * 180.0 / PI, V_PER_PWM, 255.0 * V_PER_PWM, PWM_DEADBAND, TAU_S, TRACK_M, LATENCY_S);
        $display("---------------------------------------------------------------");
    endtask
endmodule
