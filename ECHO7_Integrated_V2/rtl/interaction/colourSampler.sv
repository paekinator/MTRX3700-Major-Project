// Raw RGB samples from paired red-card/blue-strip regions, frozen at SOF.
// Colour masks never filter these samples. The reader must subsequently verify
// the same frame's card geometry before accepting completed statistics.
module colourSampler (
    input logic clk,reset,sof,pixelValid,eop,collectEnable,roiValid,
    input logic [8:0] x,
    input logic [7:0] y,
    input logic [23:0] rgb,
    input logic useProjective,
    input vision_pkg::samplePolygon_t redPolygon,bluePolygon,
    input logic [1:0] orientation,
    input candidate_pkg::candidate_t redBox,blueBox,
    output logic frameSampleGood,
    output logic [7:0] redMinimum,blueMinimum,
    output logic [16:0] redSamples,blueSamples,
    output candidate_pkg::candidate_t sampledRedBox,sampledBlueBox,
    output vision_pkg::samplePolygon_t sampledRedPolygon,sampledBluePolygon,
    output logic sampledUseProjective
);
    import candidate_pkg::*;
    import vision_pkg::*;
    candidate_t heldRed,heldBlue;
    samplePolygon_t heldRedPolygon,heldBluePolygon,evaluationRed,evaluationBlue;
    logic heldUseProjective;
    logic collecting;
    logic [1:0] heldOrientation;
    logic [16:0] redCount,blueCount;
    logic [7:0] redLow,redHigh,blueLow,blueHigh,redOther,blueOther;
    logic [9:0] w,h,u,v;
    logic redHit,blueHit;
    logic [7:0] r,g,b;
    logic redPolygonValid,bluePolygonValid,redConvex,blueConvex;
    logic redProjectiveHit,blueProjectiveHit,samplePixel;
    // Q4 coordinates are unsigned 13-bit. Subtraction needs signed 14-bit,
    // including malformed input vertices up to8191. Each product is signed
    // 28-bit; its subtraction is explicitly extended to29-bit before use.
    logic signed [13:0] redDx[0:3],redDy[0:3],redPointDx[0:3],redPointDy[0:3];
    logic signed [13:0] blueDx[0:3],blueDy[0:3],bluePointDx[0:3],bluePointDy[0:3];
    logic signed [27:0] redForward[0:3],redReverse[0:3],blueForward[0:3],blueReverse[0:3];
    logic signed [28:0] redCross[0:3],blueCross[0:3];
    logic [16:0] nextRedCount,nextBlueCount,completedRedCount,completedBlueCount;
    logic [7:0] nextRedLow,nextRedHigh,nextBlueLow,nextBlueHigh,nextRedOther,nextBlueOther;
    logic [7:0] completedRedLow,completedRedHigh,completedBlueLow,completedBlueHigh;
    logic [7:0] completedRedOther,completedBlueOther;

    always_comb begin
        // The same sixteen 14x14 multipliers serve both purposes: on SOP an
        // edge is tested against the following vertex (strict convexity);
        // otherwise it is tested against the native integer pixel centre.
        // SOP is a separate stream-control cycle; no colour-mask predicate is
        // involved in either polygon membership or the raw RGB statistics.
        evaluationRed=sof?redPolygon:heldRedPolygon;
        evaluationBlue=sof?bluePolygon:heldBluePolygon;
        redPolygonValid=evaluationRed.valid;bluePolygonValid=evaluationBlue.valid;
        redConvex=1;blueConvex=1;redProjectiveHit=1;blueProjectiveHit=1;
        for(int edgeIndex=0;edgeIndex<4;edgeIndex++)begin
            if(evaluationRed.x[edgeIndex]>=13'd5120||evaluationRed.y[edgeIndex]>=13'd3840)redPolygonValid=0;
            if(evaluationBlue.x[edgeIndex]>=13'd5120||evaluationBlue.y[edgeIndex]>=13'd3840)bluePolygonValid=0;
            redDx[edgeIndex]=$signed({1'b0,evaluationRed.x[(edgeIndex+1)%4]})-$signed({1'b0,evaluationRed.x[edgeIndex]});
            redDy[edgeIndex]=$signed({1'b0,evaluationRed.y[(edgeIndex+1)%4]})-$signed({1'b0,evaluationRed.y[edgeIndex]});
            blueDx[edgeIndex]=$signed({1'b0,evaluationBlue.x[(edgeIndex+1)%4]})-$signed({1'b0,evaluationBlue.x[edgeIndex]});
            blueDy[edgeIndex]=$signed({1'b0,evaluationBlue.y[(edgeIndex+1)%4]})-$signed({1'b0,evaluationBlue.y[edgeIndex]});
            redPointDx[edgeIndex]=(sof?$signed({1'b0,evaluationRed.x[(edgeIndex+2)%4]}):$signed({1'b0,x,4'b0}))-
                $signed({1'b0,evaluationRed.x[edgeIndex]});
            redPointDy[edgeIndex]=(sof?$signed({1'b0,evaluationRed.y[(edgeIndex+2)%4]}):$signed({2'b0,y,4'b0}))-
                $signed({1'b0,evaluationRed.y[edgeIndex]});
            bluePointDx[edgeIndex]=(sof?$signed({1'b0,evaluationBlue.x[(edgeIndex+2)%4]}):$signed({1'b0,x,4'b0}))-
                $signed({1'b0,evaluationBlue.x[edgeIndex]});
            bluePointDy[edgeIndex]=(sof?$signed({1'b0,evaluationBlue.y[(edgeIndex+2)%4]}):$signed({2'b0,y,4'b0}))-
                $signed({1'b0,evaluationBlue.y[edgeIndex]});
            redForward[edgeIndex]=redDx[edgeIndex]*redPointDy[edgeIndex];redReverse[edgeIndex]=redDy[edgeIndex]*redPointDx[edgeIndex];
            blueForward[edgeIndex]=blueDx[edgeIndex]*bluePointDy[edgeIndex];blueReverse[edgeIndex]=blueDy[edgeIndex]*bluePointDx[edgeIndex];
            redCross[edgeIndex]=$signed({redForward[edgeIndex][27],redForward[edgeIndex]})-$signed({redReverse[edgeIndex][27],redReverse[edgeIndex]});
            blueCross[edgeIndex]=$signed({blueForward[edgeIndex][27],blueForward[edgeIndex]})-$signed({blueReverse[edgeIndex][27],blueReverse[edgeIndex]});
            if(redCross[edgeIndex]<=29'sd0)redConvex=0;
            if(blueCross[edgeIndex]<=29'sd0)blueConvex=0;
            if(redCross[edgeIndex]<29'sd0)redProjectiveHit=0;
            if(blueCross[edgeIndex]<29'sd0)blueProjectiveHit=0;
        end
    end
    always_comb begin
        r=rgb[23:16];g=rgb[15:8];b=rgb[7:0];
        w=heldOrientation[0]?10'(heldRed.ymax-heldRed.ymin+1):10'(heldRed.xmax-heldRed.xmin+1);
        h=heldOrientation[0]?10'(heldRed.xmax-heldRed.xmin+1):10'(heldRed.ymax-heldRed.ymin+1);
        case(heldOrientation)
            0:begin u=10'(x)-10'(heldRed.xmin);v=10'(y)-10'(heldRed.ymin);end
            1:begin u=10'(y)-10'(heldRed.ymin);v=10'(heldRed.xmax)-10'(x);end
            2:begin u=10'(heldRed.xmax)-10'(x);v=10'(heldRed.ymax)-10'(y);end
            default:begin u=10'(heldRed.ymax)-10'(y);v=10'(x)-10'(heldRed.xmin);end
        endcase
        redHit=x>=heldRed.xmin&&x<=heldRed.xmax&&y>=heldRed.ymin&&y<=heldRed.ymax&&
            u*100>=w*8&&u*100<w*18&&v*10>=h*3&&v*10<h*7;
        blueHit=x>=heldBlue.xmin&&x<=heldBlue.xmax&&y>=heldBlue.ymin&&y<=heldBlue.ymax&&
            (10'(x)-10'(heldBlue.xmin))*5>=10'(heldBlue.xmax-heldBlue.xmin+1)&&
            (10'(x)-10'(heldBlue.xmin))*5<10'(heldBlue.xmax-heldBlue.xmin+1)*4&&
            (10'(y)-10'(heldBlue.ymin))*5>=10'(heldBlue.ymax-heldBlue.ymin+1)&&
            (10'(y)-10'(heldBlue.ymin))*5<10'(heldBlue.ymax-heldBlue.ymin+1)*4;
        if(heldUseProjective)begin redHit=redProjectiveHit;blueHit=blueProjectiveHit;end
    end
    always_comb begin
        nextRedCount=redCount;nextBlueCount=blueCount;
        nextRedLow=redLow;nextRedHigh=redHigh;nextRedOther=redOther;
        nextBlueLow=blueLow;nextBlueHigh=blueHigh;nextBlueOther=blueOther;
        // A new projective frame cannot consume an old held polygon on its SOP.
        // The legacy path retains its original separate-SOP protocol semantics.
        samplePixel=pixelValid&&collecting&&!(sof&&(heldUseProjective||useProjective));
        if(samplePixel)begin
            if(redHit)begin
                nextRedCount=redCount+17'd1;
                if(r<redLow)nextRedLow=r;if(r>redHigh)nextRedHigh=r;
                if(g>redOther||b>redOther)nextRedOther=g>b?g:b;
            end
            if(blueHit)begin
                nextBlueCount=blueCount+17'd1;
                if(b<blueLow)nextBlueLow=b;if(b>blueHigh)nextBlueHigh=b;
                if(g>blueOther||r>blueOther)nextBlueOther=g>r?g:r;
            end
        end
        // Unlike the inset legacy boxes, a valid projective ROI can contain
        // (319,239). Include an EOP pixel in that branch's completed statistics.
        completedRedCount=heldUseProjective?nextRedCount:redCount;
        completedBlueCount=heldUseProjective?nextBlueCount:blueCount;
        completedRedLow=heldUseProjective?nextRedLow:redLow;
        completedRedHigh=heldUseProjective?nextRedHigh:redHigh;
        completedRedOther=heldUseProjective?nextRedOther:redOther;
        completedBlueLow=heldUseProjective?nextBlueLow:blueLow;
        completedBlueHigh=heldUseProjective?nextBlueHigh:blueHigh;
        completedBlueOther=heldUseProjective?nextBlueOther:blueOther;
    end
    always_ff @(posedge clk) begin
        if(reset) begin
            heldRed<='0;heldBlue<='0;collecting<=0;heldOrientation<=0;heldUseProjective<=0;
            heldRedPolygon<='0;heldBluePolygon<='0;
            redCount<=0;blueCount<=0;redLow<=255;blueLow<=255;redHigh<=0;blueHigh<=0;
            redOther<=0;blueOther<=0;frameSampleGood<=0;redMinimum<=64;blueMinimum<=32;
            redSamples<=0;blueSamples<=0;sampledRedBox<='0;sampledBlueBox<='0;
            sampledRedPolygon<='0;sampledBluePolygon<='0;sampledUseProjective<=0;
        end else begin
            if(sof) begin
                collecting<=collectEnable&&roiValid&&(!useProjective||
                    (redPolygonValid&&bluePolygonValid&&redConvex&&blueConvex));
                heldRed<=redBox;heldBlue<=blueBox;heldOrientation<=orientation;
                heldUseProjective<=useProjective;heldRedPolygon<=redPolygon;heldBluePolygon<=bluePolygon;
                redCount<=0;blueCount<=0;redLow<=255;blueLow<=255;redHigh<=0;blueHigh<=0;
                redOther<=0;blueOther<=0;
            end
            if(samplePixel) begin
                redCount<=nextRedCount;blueCount<=nextBlueCount;
                redLow<=nextRedLow;redHigh<=nextRedHigh;redOther<=nextRedOther;
                blueLow<=nextBlueLow;blueHigh<=nextBlueHigh;blueOther<=nextBlueOther;
            end
            // Legacy references are inset. Projective statistics additionally
            // include a valid simultaneous EOP pixel, with outputs available
            // after this edge together with the exact held frame geometry.
            if(eop) begin
                frameSampleGood<=collecting&&!(heldUseProjective&&sof)&&
                    completedRedCount>=16&&completedBlueCount>=16&&
                    completedRedLow>=32&&completedBlueLow>=24&&
                    {1'b0,completedRedLow}>{1'b0,completedRedOther}+9'd8&&
                    {1'b0,completedBlueLow}>{1'b0,completedBlueOther}+9'd8&&
                    completedRedHigh-completedRedLow<=80&&completedBlueHigh-completedBlueLow<=80&&
                    completedRedHigh<248&&completedBlueHigh<248&&completedRedOther<224&&completedBlueOther<224;
                // Use half the darkest validated raw reference sample. The
                // former midrange/2 floor rejected the darker, oblique bays
                // even though the card's own reference was valid (frame31285:
                // blue reference V=41..49, bay border V=16..24). No old colour
                // mask filters samples; failed/unstable windows never commit.
                // This changes V only, not hue, saturation or white thresholds.
                redMinimum<=completedRedLow>>1;
                blueMinimum<=completedBlueLow>>1;
                redSamples<=completedRedCount;blueSamples<=completedBlueCount;
                sampledRedBox<=heldRed;sampledBlueBox<=heldBlue;
                sampledRedPolygon<=heldRedPolygon;sampledBluePolygon<=heldBluePolygon;
                sampledUseProjective<=heldUseProjective;
                // Output minima remain diagnostic proposals on failed frames;
                // only frameSampleGood authorises the existing commit consumer.
                if(heldUseProjective)collecting<=0;
            end
        end
    end
endmodule
