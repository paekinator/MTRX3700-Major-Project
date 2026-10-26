`timescale 1ns/1ps
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off PINCONNECTEMPTY */
/*
 *  chassis_drive_tb -- chassis_drive.sv and top_level.sv against the UGV02 chassis model (ugv02_model.sv).
 *
 *  Part 1: chassis_drive on its own, sending a command every 5 ms. Each setting must reach the chassis
 *          model as exactly the text in the table below, and the model must accept it without a complaint
 *          (no framing error, no baud-rate warning, no line it cannot parse).
 *  Part 2: the top level, as on the board, sending a command every 100 ms. SW0 down sends stops; SW0 up
 *          with SW9..SW2 = 102 drives forwards; SW1 backwards; KEY3 spins left; KEY2 spins right. The
 *          displays show 102, and the chassis model's robot moves the way each command says.
 *
 *  Run:  ./simulate.sh          ./simulate.sh wave: only the first command of part 1, into waveform.fst
 */
module chassis_drive_tb;
    logic clk = 1'b0;
    always #10 clk = ~clk;                                       // 50 MHz, as CLOCK_50

    // ---- part 1: chassis_drive on its own ------------------------------------------------------------
    logic              reset1 = 1'b1, en1 = 1'b0;
    logic signed [9:0] left1 = '0, right1 = '0;
    wire               tx1, busy1;
    chassis_drive #(.PERIOD_MS(5)) dut1 (.clk(clk), .reset(reset1), .enable(en1), .left(left1), .right(right1),
                                         .tx(tx1), .busy(busy1));
    real x1, y1, h1, vl1, vr1, cl1, cr1;
    int  nc1, np1;
    ugv02_model #(.NAME("UGV02-1")) chassis1 (.rx(tx1), .tx(), .x_m(x1), .y_m(y1), .heading_rad(h1), .v_left(vl1),
        .v_right(vr1), .cmd_left(cl1), .cmd_right(cr1), .commands(nc1), .problems(np1));

    // ---- part 2: the top level, with its switches and keys ------------------------------------------
    logic [3:0] KEY = 4'b1111;
    logic [9:0] SW  = '0;
    wire  [9:0] LEDR;
    wire  [6:0] HEX0, HEX1, HEX2, HEX3, HEX4, HEX5;
    wire  [35:0] GPIO_1;
    logic run2 = 1'b0;                                           // part 2's clock runs only in part 2: a smaller waveform
    wire  clk2 = clk & run2;
    top_level dut2 (.CLOCK_50(clk2), .KEY(KEY), .SW(SW), .LEDR(LEDR), .HEX0(HEX0), .HEX1(HEX1), .HEX2(HEX2),
                    .HEX3(HEX3), .HEX4(HEX4), .HEX5(HEX5), .GPIO_1(GPIO_1));
    real x2, y2, h2, vl2, vr2, cl2, cr2;
    int  nc2, np2;
    ugv02_model #(.NAME("UGV02-2")) chassis2 (.rx(GPIO_1[31]), .tx(GPIO_1[33]), .x_m(x2), .y_m(y2), .heading_rad(h2),
        .v_left(vl2), .v_right(vr2), .cmd_left(cl2), .cmd_right(cr2), .commands(nc2), .problems(np2));

    int fails = 0, checks = 0;
    task automatic check(input bit ok, input string what);
        checks++;
        if (ok) $display("  ok: %s", what);
        else begin fails++; $display("FAIL: %s", what); end
    endtask
    function automatic real absr(input real v);
        return (v < 0.0) ? -v : v;
    endfunction

    // Part 1: set the inputs, wait for two complete lines (the first may have started before the change),
    // then check the second line's text and the speeds the chassis model took from it.
    task automatic expect_text(input logic en, input int l, input int r, input string text, input int pl, input int pr);
        int n0;
        en1 = en; left1 = 10'(l); right1 = 10'(r);
        n0 = chassis1.lines;
        wait (chassis1.lines >= n0 + 2);
        chassis1.update();
        check(chassis1.last_line == text && chassis1.cmd_left == real'(pl) / 512.0 && chassis1.cmd_right == real'(pr) / 512.0,
              $sformatf("enable %0d, left %0d, right %0d: the chassis received %s (expected %s), PWM %0d / %0d",
                        en, l, r, chassis1.last_line, text, $rtoi(chassis1.cmd_left * 512.0), $rtoi(chassis1.cmd_right * 512.0)));
    endtask

    // Part 2: wait for the next two lines from the top level, then check the second.
    task automatic expect_board(input string what, input string text);
        int n0 = chassis2.lines;
        wait (chassis2.lines >= n0 + 2);
        check(chassis2.last_line == text, $sformatf("%s: the chassis received %s (expected %s)", what, chassis2.last_line, text));
    endtask

    // The seven-segment patterns of the DE1-SoC (active low), for the digits shown.
    function automatic logic [6:0] seg(input int d);
        case (d)
            0: return 7'b1000000;  1: return 7'b1111001;  2: return 7'b0100100;
            default: return 7'b1111111;
        endcase
    endfunction

    real x_go, t_go;
    int  n_go;
    initial begin
        if ($test$plusargs("wave")) begin
            $dumpfile("waveform.fst"); $dumpvars(0, dut1);
        end
        $display("=== part 1: chassis_drive on its own, a command every 5 ms ===");
        repeat (5) @(posedge clk);
        reset1 = 1'b0;
        if ($test$plusargs("wave")) begin
            en1 = 1'b1; left1 = 10'sd102; right1 = -10'sd51;
            wait (chassis1.lines >= 1);
            $display("wave mode: the first command, %s, is in waveform.fst. Run ./simulate.sh without 'wave' for every check.", chassis1.last_line);
            $finish;
        end
        expect_text(1'b0,   0,    0, "{\"T\":11,\"L\":0,\"R\":0}",       0,    0);
        expect_text(1'b1,   7,   -7, "{\"T\":11,\"L\":7,\"R\":-7}",      7,   -7);
        expect_text(1'b1,  51,  -51, "{\"T\":11,\"L\":51,\"R\":-51}",   51,  -51);
        expect_text(1'b1, 100,   99, "{\"T\":11,\"L\":100,\"R\":99}",  100,   99);
        expect_text(1'b1, 255, -255, "{\"T\":11,\"L\":255,\"R\":-255}", 255, -255);
        expect_text(1'b1, 300, -400, "{\"T\":11,\"L\":255,\"R\":-255}", 255, -255);
        expect_text(1'b1,  -1,    0, "{\"T\":11,\"L\":-1,\"R\":0}",     -1,    0);
        expect_text(1'b0, 200,  200, "{\"T\":11,\"L\":0,\"R\":0}",       0,    0);
        check(chassis1.problems == 0, $sformatf("the chassis model had no complaint about the UART or the text (%0d)", chassis1.problems));

        $display("=== part 2: the top level, a command every 100 ms ===");
        @(negedge clk) run2 = 1'b1;
        SW = 10'b0;                                                    // SW0 down: stops
        expect_board("SW0 down", "{\"T\":11,\"L\":0,\"R\":0}");
        chassis2.update();
        check(chassis2.x_m == 0.0 && chassis2.y_m == 0.0, "SW0 down: the robot has not moved");

        SW = {8'd102, 1'b0, 1'b1};                                     // SW9..SW2 = 102, SW1 down, SW0 up
        expect_board("SW0 up, SW9..SW2 = 102", "{\"T\":11,\"L\":102,\"R\":102}");
        check(HEX3 == seg(0) && HEX2 == seg(1) && HEX1 == seg(0) && HEX0 == seg(2) && LEDR[0],
              "the displays show 0102 and LEDR0 (go) is lit");
        chassis2.update();
        x_go = chassis2.x_m; t_go = $realtime; n_go = chassis2.lines;   // taken as a line has just arrived
        wait (chassis2.lines == n_go + 10);
        chassis2.update();
        check(absr(($realtime - t_go) / 1.0e9 - 1.0) < 0.001,
              $sformatf("10 commands in %0.3f s (one every 100 ms)", ($realtime - t_go) / 1.0e9));
        check(chassis2.x_m - x_go > 0.15 && absr(chassis2.heading_rad) < 1.0e-9 && absr(chassis2.y_m) < 1.0e-9,
              $sformatf("in that second the robot drove %0.3f m straight ahead (PWM 102 is %0.3f m/s in the model)",
                        chassis2.x_m - x_go, 102.0 / 512.0));

        SW[1] = 1'b1;
        expect_board("SW1 up (backwards)", "{\"T\":11,\"L\":-102,\"R\":-102}");
        SW[1] = 1'b0;
        KEY[3] = 1'b0;
        expect_board("KEY3 held (spin left)", "{\"T\":11,\"L\":-102,\"R\":102}");
        check(LEDR[3], "LEDR3 shows the spin left");
        KEY[3] = 1'b1; KEY[2] = 1'b0;
        expect_board("KEY2 held (spin right)", "{\"T\":11,\"L\":102,\"R\":-102}");
        KEY[2] = 1'b1;
        SW[0] = 1'b0;
        expect_board("SW0 down again", "{\"T\":11,\"L\":0,\"R\":0}");
        check(chassis2.problems == 0, $sformatf("the chassis model had no complaint about the top level's commands (%0d)", chassis2.problems));

        chassis1.print_summary();
        chassis2.print_summary();
        if (fails == 0) $display("PASS: chassis_drive sends every PWM as the chassis expects it (signs, one to three digits, clamping, stops), and the top level drives forwards, backwards and both spins from the switches and keys, a command every 100 ms (%0d checks)", checks);
        else            $display("FAILED: %0d of %0d checks", fails, checks);
        $finish;
    end
endmodule
