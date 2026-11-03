// Unsigned RGB888 to H degrees [0,359], S/V [0,255]. One shared 16-step
// restoring divider is reused for hue and saturation; no parallel divider or
// frame storage. Hue uses integer truncation toward zero for its signed sector
// fraction; saturation is floor(255*delta/max). Grey/black has H=S=0.
// start is accepted only while ready. rgb is then independent of its producer.
// valid is one cycle; a non-grey conversion completes 33 clocks after acceptance.
module memberBVgaHsv(
    input logic clk,reset,start,
    input logic [23:0] rgb,
    output logic ready,valid,
    output logic [8:0] hue,
    output logic [7:0] saturation,value
);
    typedef enum logic [1:0] {IDLE,DIV_H,PREP_S,DIV_S} state_t;
    state_t state;
    logic [7:0] maximum,minimum,delta,heldMaximum,heldDelta,divisor;
    logic signed [9:0] difference;
    logic signed [15:0] hueNumerator;
    logic [8:0] baseHue,heldBaseHue;
    logic negativeHue;
    logic [15:0] dividend,quotient,nextQuotient;
    logic [8:0] remainder,trialRemainder,nextRemainder;
    logic [4:0] bitIndex;
    logic signed [10:0] signedHue;
    assign ready=state==IDLE;
    always_comb begin
        maximum=rgb[23:16];minimum=rgb[23:16];
        if(rgb[15:8]>maximum)maximum=rgb[15:8];
        if(rgb[7:0]>maximum)maximum=rgb[7:0];
        if(rgb[15:8]<minimum)minimum=rgb[15:8];
        if(rgb[7:0]<minimum)minimum=rgb[7:0];
        delta=maximum-minimum;difference=0;baseHue=0;
        if(maximum==rgb[23:16])difference=$signed({2'b0,rgb[15:8]})-$signed({2'b0,rgb[7:0]});
        else if(maximum==rgb[15:8])begin baseHue=9'd120;difference=$signed({2'b0,rgb[7:0]})-$signed({2'b0,rgb[23:16]});end
        else begin baseHue=9'd240;difference=$signed({2'b0,rgb[23:16]})-$signed({2'b0,rgb[15:8]});end
        hueNumerator=16'(difference)*16'sd60;
        trialRemainder={remainder[7:0],dividend[15]};
        nextRemainder=trialRemainder;
        nextQuotient={quotient[14:0],1'b0};
        if(trialRemainder>={1'b0,divisor})begin
            nextRemainder=trialRemainder-{1'b0,divisor};nextQuotient[0]=1;
        end
        signedHue=$signed({2'b0,heldBaseHue});
        if(negativeHue)signedHue=signedHue-$signed({2'b0,nextQuotient[8:0]});
        else signedHue=signedHue+$signed({2'b0,nextQuotient[8:0]});
        if(signedHue<0)signedHue=signedHue+11'sd360;
        if(signedHue>=360)signedHue=signedHue-11'sd360;
    end
    always_ff @(posedge clk)begin
        if(reset)begin
            state<=IDLE;valid<=0;hue<=0;saturation<=0;value<=0;
            heldMaximum<=0;heldDelta<=0;heldBaseHue<=0;negativeHue<=0;
            divisor<=0;dividend<=0;quotient<=0;remainder<=0;bitIndex<=0;
        end else begin
            valid<=0;
            case(state)
                IDLE:if(start)begin
                    heldMaximum<=maximum;heldDelta<=delta;heldBaseHue<=baseHue;
                    value<=maximum;negativeHue<=hueNumerator<0;
                    if(delta==0)begin hue<=0;saturation<=0;valid<=1;end
                    else begin
                        dividend<=hueNumerator<0?16'(-hueNumerator):16'(hueNumerator);
                        divisor<=delta;quotient<=0;remainder<=0;bitIndex<=0;state<=DIV_H;
                    end
                end
                DIV_H:begin
                    dividend<={dividend[14:0],1'b0};quotient<=nextQuotient;remainder<=nextRemainder;
                    if(bitIndex==15)begin hue<=signedHue[8:0];state<=PREP_S;end
                    else bitIndex<=bitIndex+5'd1;
                end
                PREP_S:begin
                    dividend<=({heldDelta,8'b0}-{8'b0,heldDelta});divisor<=heldMaximum;
                    quotient<=0;remainder<=0;bitIndex<=0;state<=DIV_S;
                end
                DIV_S:begin
                    dividend<={dividend[14:0],1'b0};quotient<=nextQuotient;remainder<=nextRemainder;
                    if(bitIndex==15)begin saturation<=nextQuotient[7:0];valid<=1;state<=IDLE;end
                    else bitIndex<=bitIndex+5'd1;
                end
                default:state<=IDLE;
            endcase
        end
    end
endmodule
