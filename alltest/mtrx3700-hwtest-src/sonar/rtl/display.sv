module display #(
    parameter int VALUE_WIDTH = 12,  // width of binary input
    parameter int DIGITS      = 4    // number of BCD digits / seven-seg displays
)(
    input  logic                  clk,
    input  logic [VALUE_WIDTH-1:0] value,
    output logic [6:0]  display0,
    output logic [6:0]  display1,
    output logic [6:0]  display2,
    output logic [6:0]  display3
);
    /*** FSM Controller Code ***/
    enum { Initialise, Add3, Shift, Result } next_state, current_state = Initialise;
    
    logic init, add, done;
    logic [$clog2(VALUE_WIDTH):0] count = 0; // enough bits to count VALUE_WIDTH cycles

    /*** FSM Next-State Logic ***/
    always_comb begin
        case (current_state)
            Initialise: next_state = Add3;
            Add3:       next_state = Shift;
            Shift:      next_state = count == VALUE_WIDTH - 1 ? Result : Add3;
            Result:     next_state = Initialise;
            default:    next_state = Initialise;
        endcase
    end

    /*** FSM Sequential Logic ***/
    always_ff @(posedge clk) begin
        current_state <= next_state;
        if (current_state == Shift)
            count <= count == VALUE_WIDTH - 1 ? 0 : count + 1;
    end

    /*** FSM Output Logic ***/
    always_comb begin
        init = 0; add = 0; done = 0;
        case (current_state)
            Initialise: init = 1;
            Add3:       add  = 1;
            Result:     done = 1;
        endcase
    end

    /*** DO NOT MODIFY BELOW (except parameterized signals) ***/
    logic [3:0] digit0, digit1, digit2, digit3;

    // Seven-segment display decoders
    seven_seg u_digit0 (.bcd(digit0), .segments(display0));
    seven_seg u_digit1 (.bcd(digit1), .segments(display1));
    seven_seg u_digit2 (.bcd(digit2), .segments(display2));
    seven_seg u_digit3 (.bcd(digit3), .segments(display3));

    // Shift register and temporary storage
    logic [3:0] bcd [0:DIGITS-1];
    logic [VALUE_WIDTH-1:0] temp_value;

    // Shift register process
    always_ff @(posedge clk) begin
        if (init) begin
            {bcd[3], bcd[2], bcd[1], bcd[0], temp_value} <= {{(DIGITS*4){1'b0}}, value};
        end
        else begin
            if (add) begin
                for (int i = 0; i < DIGITS; i++)
                    bcd[i] <= (bcd[i] > 4) ? bcd[i] + 3 : bcd[i];
            end
            else begin
                {bcd[3], bcd[2], bcd[1], bcd[0], temp_value} <=
                    {bcd[3], bcd[2], bcd[1], bcd[0], temp_value} << 1;
            end
        end
    end

    // Output register
    always_ff @(posedge clk) begin
        if (done) begin
            digit0 <= bcd[0];
            digit1 <= bcd[1];
            digit2 <= bcd[2];
            digit3 <= bcd[3];
        end
    end

endmodule
