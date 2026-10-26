`timescale 1ns/1ps
/*
 *  top_level.sv -- drive the UGV02 from the DE1-SoC's switches, through chassis_drive.sv.
 *
 *      SW0          go: down, every command is a stop
 *      SW9..SW2     the PWM, 0 to 255 (SW9 is the top bit); shown in decimal on HEX3..HEX0
 *      SW1          backwards
 *      KEY3 held    spin left on the spot (left wheels backwards, right wheels forwards)
 *      KEY2 held    spin right on the spot
 *      KEY0         reset
 *      LEDR0 go, LEDR1 a command is going out (it flickers ten times a second), LEDR2 backwards,
 *      LEDR3 spinning left, LEDR4 spinning right
 *
 *  Pins (the DE1-SoC's own names): the Robot Adaptor Board's J5 on GPIO_1[31] (the FPGA's TX, to the
 *  chassis's RX) and GPIO_1[33] (the chassis's TX, not used here).
 *
 *  Start with the robot on its stand, wheels in the air, and a small PWM.
 */
module top_level (
    input  wire        CLOCK_50,
    input  wire [3:0]  KEY,
    input  wire [9:0]  SW,
    output wire [9:0]  LEDR,
    output wire [6:0]  HEX0, HEX1, HEX2, HEX3, HEX4, HEX5,
    inout  wire [35:0] GPIO_1
);
    // 1. KEY0 resets; the switches and keys go through two flip-flops (they change at any time).
    logic [1:0] rs = 2'b11;
    always_ff @(posedge CLOCK_50) rs <= {rs[0], ~KEY[0]};
    wire reset = rs[1];
    logic [9:0] sw_meta = '0, sw = '0;
    logic [3:0] key_meta = '1, key = '1;
    always_ff @(posedge CLOCK_50) begin
        sw_meta  <= SW;  sw  <= sw_meta;
        key_meta <= KEY; key <= key_meta;
    end

    // 2. The two PWMs from the switches and keys.
    wire               go         = sw[0];
    wire               backwards  = sw[1];
    wire               spin_left  = ~key[3];
    wire               spin_right = ~key[2] & key[3];
    wire signed [9:0]  pwm        = {2'b00, sw[9:2]};        // 0 .. 255
    logic signed [9:0] left, right;
    always_comb begin
        if (spin_left)       begin left = -pwm; right =  pwm; end
        else if (spin_right) begin left =  pwm; right = -pwm; end
        else if (backwards)  begin left = -pwm; right = -pwm; end
        else                 begin left =  pwm; right =  pwm; end
    end

    // 3. Send them to the chassis ten times a second.
    wire busy;
    chassis_drive drive_u (.clk(CLOCK_50), .reset(reset), .enable(go), .left(left), .right(right),
                           .tx(GPIO_1[31]), .busy(busy));

    // 4. The PWM on the displays, and what the switches ask for on the LEDs.
    display #(.VALUE_WIDTH(8), .DIGITS(4)) display_u (.clk(CLOCK_50), .value(sw[9:2]),
        .display0(HEX0), .display1(HEX1), .display2(HEX2), .display3(HEX3));
    assign HEX4 = 7'h7F;                                        // blank
    assign HEX5 = 7'h7F;
    assign LEDR = {5'b0, spin_right & go, spin_left & go, backwards & go, busy, go};
endmodule
