// ECHO-7 Phase 1.5 | Owner: MTRX3700 ECHO-7 team; human review pending.
// AI-assisted implementation: OpenAI Codex. See OWNERS.md and AI_STATEMENT.md.
module colourMeanHsv (
    input logic clk, reset, start,
    input echo7_diag_pkg::region_acc_t red_stats, blue_stats,
    input logic [1:0] in_mode,
    input logic [15:0] in_frame_id,
    output logic busy, done,
    output logic [1:0] out_mode,
    output logic [15:0] out_frame_id,
    output echo7_diag_pkg::region_result_t red_result, blue_result
);
    import echo7_diag_pkg::*;
    typedef enum logic [2:0] {IDLE, LOAD, REQUEST, WAIT_DIV, PUBLISH} state_t;
    state_t state;
    region_acc_t current, saved_blue;
    region_result_t calculated;
    logic colour;
    logic [2:0] operation;
    logic [1:0] saved_mode;
    logic [15:0] saved_id;
    logic div_busy, div_done, div_zero;
    logic [26:0] numerator, denominator, quotient;
    logic [7:0] maximum, minimum, delta;
    logic signed [18:0] hue_numerator;
    assign busy=(state!=IDLE);
    unsignedDivider #(.WIDTH(27)) divider_u(.clk,.reset,
        .start(state==REQUEST),.numerator,.denominator,
        .busy(div_busy),.done(div_done),.divide_by_zero(div_zero),.quotient);

    always_comb begin
        maximum=calculated.r;
        if(calculated.g>maximum) maximum=calculated.g;
        if(calculated.b>maximum) maximum=calculated.b;
        minimum=calculated.r;
        if(calculated.g<minimum) minimum=calculated.g;
        if(calculated.b<minimum) minimum=calculated.b;
        delta=maximum-minimum;
        // Exact sector numerator in degrees, normalized to [0,360*delta).
        if(maximum==calculated.r) begin
            hue_numerator=19'sd60*($signed({1'b0,calculated.g})-$signed({1'b0,calculated.b}));
            if(calculated.g<calculated.b) hue_numerator=hue_numerator+19'sd360*$signed({1'b0,delta});
        end else if(maximum==calculated.g)
            hue_numerator=19'sd120*$signed({1'b0,delta})+
                          19'sd60*($signed({1'b0,calculated.b})-$signed({1'b0,calculated.r}));
        else hue_numerator=19'sd240*$signed({1'b0,delta})+
                          19'sd60*($signed({1'b0,calculated.r})-$signed({1'b0,calculated.g}));
        numerator=0; denominator=1;
        case(operation)
            0: begin numerator=current.sum_r+27'(current.area>>1); denominator=27'(current.area); end
            1: begin numerator=current.sum_g+27'(current.area>>1); denominator=27'(current.area); end
            2: begin numerator=current.sum_b+27'(current.area>>1); denominator=27'(current.area); end
            3: if(delta!=0) begin
                numerator=27'($unsigned(hue_numerator))+27'(delta>>1); denominator=27'(delta);
            end
            4: if(maximum!=0) begin
                numerator=27'd255*27'(delta)+27'(maximum>>1); denominator=27'(maximum);
            end
            default: begin end
        endcase
    end

    always_ff @(posedge clk) begin
        if(reset) begin
            state<=IDLE; done<=0; red_result<='0; blue_result<='0;
            current<='0; saved_blue<='0; calculated<='0; colour<=0; operation<=0;
            saved_mode<=0; saved_id<=0; out_mode<=0; out_frame_id<=0;
        end else begin
            done<=0;
            case(state)
                IDLE: if(start) begin
                    current<=red_stats; saved_blue<=blue_stats;
                    saved_mode<=in_mode; saved_id<=in_frame_id;
                    colour<=0; state<=LOAD;
                end
                LOAD: begin
                    calculated<='0; operation<=0;
                    if(current.valid && !current.overflow && current.area!=0) begin
                        calculated.valid<=1;
                        calculated.xmin<=current.xmin; calculated.xmax<=current.xmax;
                        calculated.ymin<=current.ymin; calculated.ymax<=current.ymax;
                        calculated.area<=current.area;
                        state<=REQUEST;
                    end else state<=PUBLISH;
                end
                REQUEST: if(!div_busy) state<=WAIT_DIV;
                WAIT_DIV: if(div_done) begin
                    if(div_zero) calculated.valid<=0;
                    case(operation)
                        0: calculated.r <= quotient>255 ? 8'd255 : quotient[7:0];
                        1: calculated.g <= quotient>255 ? 8'd255 : quotient[7:0];
                        2: calculated.b <= quotient>255 ? 8'd255 : quotient[7:0];
                        3: begin calculated.h <= quotient>=360 ? 9'd0 : quotient[8:0]; calculated.v<=maximum; end
                        4: calculated.s <= quotient>255 ? 8'd255 : quotient[7:0];
                        default: begin end
                    endcase
                    if(operation==4) state<=PUBLISH;
                    else begin operation<=operation+3'd1; state<=REQUEST; end
                end
                PUBLISH: begin
                    if(!colour) begin
                        red_result<=calculated;
                        red_result.rgb_digits<={decimal3({1'b0,calculated.r}),decimal3({1'b0,calculated.g}),decimal3({1'b0,calculated.b})};
                        red_result.hsv_digits<={decimal3(calculated.h),decimal3({1'b0,calculated.s}),decimal3({1'b0,calculated.v})};
                        current<=saved_blue; colour<=1; state<=LOAD;
                    end else begin
                        blue_result<=calculated;
                        blue_result.rgb_digits<={decimal3({1'b0,calculated.r}),decimal3({1'b0,calculated.g}),decimal3({1'b0,calculated.b})};
                        blue_result.hsv_digits<={decimal3(calculated.h),decimal3({1'b0,calculated.s}),decimal3({1'b0,calculated.v})};
                        out_mode<=saved_mode; out_frame_id<=saved_id;
                        done<=1; state<=IDLE;
                    end
                end
                default: state<=IDLE;
            endcase
        end
    end
endmodule
