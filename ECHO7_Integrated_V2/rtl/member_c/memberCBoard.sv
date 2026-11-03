`timescale 1ns/1ps
// ECHO-7 IR/sonar test: POWER once, safety-latched stop, KEY0 rearm.
// POWER starts a perception-driven task, never direct fixed-speed motion.
// Board I/O wrapper reused from validated Member C; only reset ownership changed.
// KEY1 pages: decimal distance (d), NEC high word (H), NEC low word (L).
// On the H page HEX1..0 is the command byte, code[23:16].
module memberCBoard #(
    // Existing chassis forward convention: both UART wheel signs are negative.
    parameter int LEFT_POLARITY = -1, RIGHT_POLARITY = -1,
    // Candidate image-to-turn convention: must be checked with wheels raised.
    parameter int TURN_SIGN = 1,
    // Single safety threshold in mm; stop at distance <= this value.
    parameter int ULTRASONIC_ESTOP_MM = 250, // EB STOP DISTANCE mm
    parameter int HEARTBEAT_CLKS = 10_000_000, // 200 ms at 50 MHz
    parameter int BLINK_CLKS = 2_500_000,      // 50 ms event indication
    parameter int KEY_DEBOUNCE_CLKS = 1_000_000 // 20 ms stable press AND release
) (
    input  wire       CLOCK_50,
    input  wire       reset50, // Shared integrated CLOCK_50 reset.
    input  wire [1:0] KEY,
    input  wire       IRDA_RXD,
    input wire [4:2] SW,
    // Internal public v3 link to perceptionCore, all synchronous to CLOCK_50.
    input logic [31:0] timeUs,
    input perception_pkg::perceptionStatus_t perceptionStatus,
    output perception_pkg::targetRequest_t targetRequest,
    output wire targetRequestValid, input wire targetRequestReady,
    input perception_pkg::targetReport_t targetReport,
    input wire targetReportValid, output wire targetReportReady,
    input  wire       SONAR_ECHO,
    output wire       SONAR_TRIG,
    input  wire       CHASSIS_RX, // former GPIO_1[33], PIN_AD21
    output wire       CHASSIS_TX, // former GPIO_1[31], PIN_AF23
    output wire [9:0] LEDR,
    output wire [6:0] HEX0, HEX1, HEX2, HEX3, HEX4, HEX5
);
    wire nec_valid, nec_repeat;
    wire [31:0] nec_code;
    nec_decoder #(.CLK_HZ(50_000_000)) u_nec (
        .clk(CLOCK_50), .rst(reset50), .ir(IRDA_RXD),
        .valid(nec_valid), .code(nec_code), .repeat_code(nec_repeat));

    logic [31:0] last_code;
    logic code_seen;
    always_ff @(posedge CLOCK_50) begin
        if (reset50) begin
            last_code <= '0;
            code_seen <= 1'b0;
        end else if (nec_valid) begin
            last_code <= nec_code;
            code_seen <= 1'b1;
        end
    end

    // A stable release is required before another debounced page change.
    localparam int KW = (KEY_DEBOUNCE_CLKS > 1) ? $clog2(KEY_DEBOUNCE_CLKS) : 1;
    logic [1:0] key1_sync;
    logic key1_stable;
    logic [1:0] page;
    wire high_page = page==1;
    logic [KW-1:0] key1_count;
    always_ff @(posedge CLOCK_50) begin
        if (reset50) begin
            key1_sync <= 2'b11;
            key1_stable <= 1'b1;
            key1_count <= '0;
            page <= 0;
        end else begin
            key1_sync <= {key1_sync[0], KEY[1]};
            if (key1_sync[1] == key1_stable) key1_count <= '0;
            else if (key1_count == KW'(KEY_DEBOUNCE_CLKS - 1)) begin
                key1_stable <= key1_sync[1];
                key1_count <= '0;
                if (!key1_sync[1]) page <= page==2 ? 0 : page+1'b1;
            end else key1_count <= key1_count + 1'b1;
        end
    end

    wire [11:0] distance_mm;
    wire distance_valid, sample_pulse;
    logic [15:0] decimal_digits;
    integer k;
    always_comb begin
      decimal_digits=0;
      for(k=11;k>=0;k=k-1) begin
        if(decimal_digits[3:0]>=5) decimal_digits[3:0]=decimal_digits[3:0]+4'd3;
        if(decimal_digits[7:4]>=5) decimal_digits[7:4]=decimal_digits[7:4]+4'd3;
        if(decimal_digits[11:8]>=5) decimal_digits[11:8]=decimal_digits[11:8]+4'd3;
        if(decimal_digits[15:12]>=5) decimal_digits[15:12]=decimal_digits[15:12]+4'd3;
        decimal_digits={decimal_digits[14:0],distance_mm[k]};
      end
    end
    wire [15:0] shown = page==0 ? decimal_digits : high_page ? last_code[31:16] : last_code[15:0];
    wire display_blank=page==0 ? !distance_valid : !code_seen;
    hex_digit h0 (.d(shown[3:0]),   .blank(display_blank), .seg(HEX0));
    hex_digit h1 (.d(shown[7:4]),   .blank(display_blank), .seg(HEX1));
    hex_digit h2 (.d(shown[11:8]),  .blank(display_blank), .seg(HEX2));
    hex_digit h3 (.d(shown[15:12]), .blank(display_blank), .seg(HEX3));
    assign HEX5 = page==0 ? 7'b0100001 : high_page ? 7'b0001001 : 7'b1000111; // H / L, active low
    assign HEX4 = 7'b0111111;                         // '-'

    // Stage 1 fixed controls: these are command bytes, not the inverse bytes.
    localparam logic [7:0] POWER_CODE = 8'h12;
    localparam logic [7:0] ESTOP_CODE = 8'h0f;
    wire power_frame = nec_valid && (nec_code[23:16] == POWER_CODE);
    wire estop_frame = nec_valid && (nec_code[23:16] == ESTOP_CODE);
    sonar_guard sonar_u(.clk50(CLOCK_50),.reset(reset50),.echo(SONAR_ECHO),
      .trig(SONAR_TRIG),.distance_mm(distance_mm),.distance_valid(distance_valid),.sample_pulse(sample_pulse));
    wire running, used, estop, sonar_stop;
    wire [2:0] stop_reason;
    (* async_reg = "true" *) logic [2:0] sw_meta, sw_sync;
    always_ff @(posedge CLOCK_50) begin
      if(reset50) begin sw_meta<=0;sw_sync<=0;end
      else begin sw_meta<=SW;sw_sync<=sw_meta;end
    end
    wire [2:0] motionState;
    wire motionTargetValid;
    wire signed [6:0] logicalL,logicalR;
    member_c_control #(.ULTRASONIC_ESTOP_MM(ULTRASONIC_ESTOP_MM),.TURN_SIGN(TURN_SIGN)) control_u(
      .clk(CLOCK_50),.reset(reset50),.power_frame(power_frame),.estop_frame(estop_frame),
      .selection(sw_sync),.timeUs(timeUs),.status(perceptionStatus),
      .targetRequest(targetRequest),.targetRequestValid(targetRequestValid),.targetRequestReady(targetRequestReady),
      .targetReport(targetReport),.targetReportValid(targetReportValid),.targetReportReady(targetReportReady),
      .distance_valid(distance_valid),.distance_mm(distance_mm),.left_cm_s(logicalL),.right_cm_s(logicalR),
      .permit(running),.used(used),.estop(estop),.sonar_stop(sonar_stop),.motionTargetValid(motionTargetValid),
      .motionState(motionState),.stop_reason(stop_reason));
    wire signed [6:0] motorL=LEFT_POLARITY==-1 ? -logicalL : LEFT_POLARITY==1 ? logicalL:7'sd0;
    wire signed [6:0] motorR=RIGHT_POLARITY==-1 ? -logicalR : RIGHT_POLARITY==1 ? logicalR:7'sd0;
    // UART resets only at configuration, so KEY0 cannot truncate a JSON line.
    logic [1:0] uart_por = 2'b11;
    always_ff @(posedge CLOCK_50) uart_por <= {uart_por[0], 1'b0};
    // Legacy ir_drive manual control is NOT instantiated.
    wire chassis_busy;
    chassis_command #(.CLKS_PER_BIT(434), .PERIOD_CLKS(HEARTBEAT_CLKS),
        .USE_WHEEL_REQUESTS(1)) chassis_u (
        .clk(CLOCK_50), .reset(uart_por[1]), .armed(running && !reset50),
        .motion(2'b00), .speed(2'b00), .left_cm_s(motorL), .right_cm_s(motorR), .feedback(1'b0),
        .tx(CHASSIS_TX), .busy(chassis_busy));

    wire [7:0] chassis_rx_byte;
    wire chassis_rx_valid, chassis_rx_fe;
    uart_rx #(.CLKS_PER_BIT(434), .BITS_N(8), .PARITY_TYPE(0)) chassis_rx_u (
        .clk(CLOCK_50), .rst(reset50), .rx(CHASSIS_RX),
        .data_rx(chassis_rx_byte), .valid(chassis_rx_valid), .ready(1'b1),
        .parity_error(), .framing_error(chassis_rx_fe));

    wire valid_led, repeat_led, rx_led;
    pulse_stretch #(.CLKS(BLINK_CLKS)) valid_blink (
        .clk(CLOCK_50), .reset(reset50), .trigger(nec_valid), .q(valid_led));
    pulse_stretch #(.CLKS(BLINK_CLKS)) repeat_blink (
        .clk(CLOCK_50), .reset(reset50), .trigger(nec_repeat), .q(repeat_led));
    pulse_stretch #(.CLKS(BLINK_CLKS)) rx_blink (
        .clk(CLOCK_50), .reset(reset50),
        .trigger(chassis_rx_valid && !chassis_rx_fe), .q(rx_led));

    // LED0 motion permit, 1 IR stop, 2 sonar valid, 3 DOCKED, 4 sonar fault; 8 target valid.
    assign LEDR = {!used && distance_valid && !reset50, motionTargetValid, repeat_led, valid_led,
      chassis_busy, (stop_reason==2), (motionState==4), distance_valid, estop, running};
endmodule
