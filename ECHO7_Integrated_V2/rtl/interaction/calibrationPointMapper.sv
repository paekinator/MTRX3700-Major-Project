// Forward projective mapping for calibration geometry, CLOCK_50 only.
// The four clockwise input corners use signed native half-pixel units. U and V
// use 1/320 of the canonical rectangle and may extend beyond its bottom edge.
// Results are signed native Q4 coordinates: floor(16 * native coordinate).
// requireInImage=1 enforces native bounds for actual ROI vertices. A zero bit
// permits extrapolated guard points outside the image, within signed16 Q4.
// All inputs are latched on start while !busy. No request is accepted while
// busy. done pulses for one clock; valid/reason and results persist until the
// next accepted request or reset. Invalid transactions clear every output.
// No RGB samples or marker identity are inferred here. This is geometry only.
module calibrationPointMapper (
    input logic clk,reset,start,
    input logic signed [3:0][10:0] pointX,pointY,
    input logic [3:0] pointCount,
    input logic signed [11:0][10:0] sampleU,sampleV,
    input logic [11:0] requireInImage,
    output logic busy,done,valid,
    output logic [3:0] reason,
    output logic signed [11:0][15:0] mappedX,mappedY
);
    // Reason priority: count, input range, convexity, singular H, arithmetic
    // overflow, non-positive denominator, then mapped native-image bounds.
    localparam logic [3:0] OK=0,BAD_COUNT=1,BAD_INPUT=2,NON_CONVEX=3,
        SINGULAR=4,BAD_DENOMINATOR=5,OUTSIDE_IMAGE=6,ARITHMETIC_OVERFLOW=7;
    typedef enum logic [3:0] {IDLE,CHECK_INPUT,CROSS_START,CROSS_WAIT,
        HOMO_DELTAS,HOMO_START,HOMO_WAIT,HOMO_SIGN,POINT_BEGIN,
        POINT_START,POINT_WAIT,DIVIDE_PREP,DIVIDE,STORE_POINT,FINISH,FAILED} state_t;
    state_t state;
    logic signed [3:0][10:0] heldX,heldY;
    logic signed [11:0][10:0] heldU,heldV;
    logic [11:0] heldRequireInImage;
    logic [3:0] heldCount,pointIndex,operation;
    logic [1:0] edgeIndex;
    logic crossPhase,inputInRange;
    logic signed [11:0] edgeAx,edgeAy,edgeBx,edgeBy;
    logic signed [11:0] dx1,dx2,dx3,dy1,dy2,dy3;
    logic signed [24:0] determinant,gNumerator,hNumerator,dNorm,gNorm,hNorm;
    logic signed [35:0] ax,bx,cx,ay,by,cy;
    logic signed [47:0] multiplyA;
    logic signed [11:0] multiplyB;
    logic signed [59:0] multiplyResult,firstProduct,numeratorX,numeratorY,denominator;
    logic signed [60:0] productDifference,productSum,pointSum;
    logic multiplyDone,multiplyStart;
    logic [63:0] remainderX,remainderY,divisionDenominator,shiftedDenominator;
    logic [15:0] quotientX,quotientY;
    logic negativeX,negativeY;
    logic [59:0] magnitudeX,magnitudeY;
    logic signed [17:0] roundedX,roundedY;
    logic [3:0] divisionBit;

    // The full signed48 x signed12 product is signed60. The multiplier shifts
    // and adds over twelve clocks; no combinational '*' or '/' is inferred.
    calibrationSerialMultiply multiplier(.clk(clk),.reset(reset),
        .start(multiplyStart),.operandA(multiplyA),.operandB(multiplyB),
        .result(multiplyResult),.done(multiplyDone));

    always_comb begin
        busy=state!=IDLE;
        inputInRange=1;
        for(int corner=0;corner<4;corner++)begin
            // Half-pixel expansion of edge pixels can produce -1 or319.5/239.5.
            if($signed(heldX[corner]) < -11'sd1 || $signed(heldX[corner]) > 11'sd639 ||
               $signed(heldY[corner]) < -11'sd1 || $signed(heldY[corner]) > 11'sd479)
                inputInRange=0;
        end
        edgeAx=12'($signed(heldX[2'(edgeIndex+1)]))-12'($signed(heldX[edgeIndex]));
        edgeAy=12'($signed(heldY[2'(edgeIndex+1)]))-12'($signed(heldY[edgeIndex]));
        edgeBx=12'($signed(heldX[2'(edgeIndex+2)]))-12'($signed(heldX[2'(edgeIndex+1)]));
        edgeBy=12'($signed(heldY[2'(edgeIndex+2)]))-12'($signed(heldY[2'(edgeIndex+1)]));
        multiplyA=0;multiplyB=0;
        multiplyStart=state==CROSS_START || state==HOMO_START || state==POINT_START;
        if(state==CROSS_START || state==CROSS_WAIT)begin
            multiplyA=crossPhase?edgeAy:edgeAx;
            multiplyB=crossPhase?edgeBx:edgeBy;
        end else if(state==POINT_START || state==POINT_WAIT)begin
            case(operation)
                0:begin multiplyA=ax;multiplyB=12'($signed(heldU[pointIndex]));end
                1:begin multiplyA=bx;multiplyB=12'($signed(heldV[pointIndex]));end
                2:begin multiplyA=ay;multiplyB=12'($signed(heldU[pointIndex]));end
                3:begin multiplyA=by;multiplyB=12'($signed(heldV[pointIndex]));end
                4:begin multiplyA=gNorm;multiplyB=12'($signed(heldU[pointIndex]));end
                default:begin multiplyA=hNorm;multiplyB=12'($signed(heldV[pointIndex]));end
            endcase
        end else begin
            // Same exact common-denominator construction as the digit reader.
            case(operation)
                0:begin multiplyA=dx1;multiplyB=dy2;end
                1:begin multiplyA=dx2;multiplyB=dy1;end
                2:begin multiplyA=dx3;multiplyB=dy2;end
                3:begin multiplyA=dx2;multiplyB=dy3;end
                4:begin multiplyA=dx1;multiplyB=dy3;end
                5:begin multiplyA=dx3;multiplyB=dy1;end
                6:begin multiplyA=dNorm;multiplyB=12'($signed(heldX[1]))-12'($signed(heldX[0]));end
                7:begin multiplyA=gNorm;multiplyB=$signed(heldX[1]);end
                8:begin multiplyA=dNorm;multiplyB=12'($signed(heldX[3]))-12'($signed(heldX[0]));end
                9:begin multiplyA=hNorm;multiplyB=$signed(heldX[3]);end
                10:begin multiplyA=dNorm;multiplyB=$signed(heldX[0]);end
                11:begin multiplyA=dNorm;multiplyB=12'($signed(heldY[1]))-12'($signed(heldY[0]));end
                12:begin multiplyA=gNorm;multiplyB=$signed(heldY[1]);end
                13:begin multiplyA=dNorm;multiplyB=12'($signed(heldY[3]))-12'($signed(heldY[0]));end
                14:begin multiplyA=hNorm;multiplyB=$signed(heldY[3]);end
                default:begin multiplyA=dNorm;multiplyB=$signed(heldY[0]);end
            endcase
        end
        productDifference=$signed({firstProduct[59],firstProduct})-$signed({multiplyResult[59],multiplyResult});
        productSum=$signed({firstProduct[59],firstProduct})+$signed({multiplyResult[59],multiplyResult});
        pointSum=$signed({multiplyResult[59],multiplyResult});
        case(operation)
            0,1:pointSum=pointSum+$signed({numeratorX[59],numeratorX});
            2,3:pointSum=pointSum+$signed({numeratorY[59],numeratorY});
            default:pointSum=pointSum+$signed({denominator[59],denominator});
        endcase
        magnitudeX=numeratorX[59]?-numeratorX:numeratorX;
        magnitudeY=numeratorY[59]?-numeratorY:numeratorY;
        // floor(-a/d)=-ceil(a/d). The seventeenth magnitude bit and explicit
        // sign leave room for65535+1 before signed16 range checks.
        roundedX=negativeX?-$signed({2'b0,quotientX})-(remainderX!=0?18'sd1:18'sd0):$signed({2'b0,quotientX});
        roundedY=negativeY?-$signed({2'b0,quotientY})-(remainderY!=0?18'sd1:18'sd0):$signed({2'b0,quotientY});
    end

    always_ff @(posedge clk)begin
        if(reset)begin
            state<=IDLE;done<=0;valid<=0;reason<=OK;mappedX<='0;mappedY<='0;
            heldX<='0;heldY<='0;heldU<='0;heldV<='0;heldRequireInImage<=0;heldCount<=0;pointIndex<=0;
            operation<=0;edgeIndex<=0;crossPhase<=0;firstProduct<=0;
            dx1<=0;dx2<=0;dx3<=0;dy1<=0;dy2<=0;dy3<=0;
            determinant<=0;gNumerator<=0;hNumerator<=0;dNorm<=0;gNorm<=0;hNorm<=0;
            ax<=0;bx<=0;cx<=0;ay<=0;by<=0;cy<=0;
            numeratorX<=0;numeratorY<=0;denominator<=0;
            remainderX<=0;remainderY<=0;divisionDenominator<=0;shiftedDenominator<=0;
            quotientX<=0;quotientY<=0;divisionBit<=0;negativeX<=0;negativeY<=0;
        end else begin
            done<=0;
            case(state)
                IDLE:if(start)begin
                    heldX<=pointX;heldY<=pointY;heldU<=sampleU;heldV<=sampleV;heldRequireInImage<=requireInImage;heldCount<=pointCount;
                    valid<=0;reason<=OK;mappedX<='0;mappedY<='0;state<=CHECK_INPUT;
                end
                CHECK_INPUT:begin
                    if(heldCount<1 || heldCount>12)begin reason<=BAD_COUNT;state<=FAILED;end
                    else if(!inputInRange)begin reason<=BAD_INPUT;state<=FAILED;end
                    else begin edgeIndex<=0;crossPhase<=0;state<=CROSS_START;end
                end
                CROSS_START:state<=CROSS_WAIT;
                CROSS_WAIT:if(multiplyDone)begin
                    if(!crossPhase)begin firstProduct<=multiplyResult;crossPhase<=1;state<=CROSS_START;end
                    else if(productDifference<=0)begin reason<=NON_CONVEX;state<=FAILED;end
                    else if(edgeIndex==3)state<=HOMO_DELTAS;
                    else begin edgeIndex<=edgeIndex+2'd1;crossPhase<=0;state<=CROSS_START;end
                end
                HOMO_DELTAS:begin
                    dx1<=12'($signed(heldX[1]))-12'($signed(heldX[2]));
                    dx2<=12'($signed(heldX[3]))-12'($signed(heldX[2]));
                    dx3<=12'($signed(heldX[0]))-12'($signed(heldX[1]))+12'($signed(heldX[2]))-12'($signed(heldX[3]));
                    dy1<=12'($signed(heldY[1]))-12'($signed(heldY[2]));
                    dy2<=12'($signed(heldY[3]))-12'($signed(heldY[2]));
                    dy3<=12'($signed(heldY[0]))-12'($signed(heldY[1]))+12'($signed(heldY[2]))-12'($signed(heldY[3]));
                    operation<=0;state<=HOMO_START;
                end
                HOMO_START:state<=HOMO_WAIT;
                HOMO_WAIT:if(multiplyDone)begin
                    // Native-bounded input makes determinants fit signed25 and
                    // coefficients fit signed36; check the narrowing explicitly.
                    if((operation==1||operation==3||operation==5) &&
                       productDifference[60:24]!={37{productDifference[24]}})begin
                        reason<=ARITHMETIC_OVERFLOW;state<=FAILED;
                    end else if((operation==7||operation==9||operation==12||operation==14) &&
                                productSum[60:35]!={26{productSum[35]}})begin
                        reason<=ARITHMETIC_OVERFLOW;state<=FAILED;
                    end else if((operation==10||operation==15) &&
                                multiplyResult[59:35]!={25{multiplyResult[35]}})begin
                        reason<=ARITHMETIC_OVERFLOW;state<=FAILED;
                    end else begin
                        case(operation)
                            0,2,4,6,8,11,13:firstProduct<=multiplyResult;
                            1:determinant<=productDifference[24:0];
                            3:gNumerator<=productDifference[24:0];
                            5:hNumerator<=productDifference[24:0];
                            7:ax<=productSum[35:0];
                            9:bx<=productSum[35:0];
                            10:cx<=multiplyResult[35:0];
                            12:ay<=productSum[35:0];
                            14:by<=productSum[35:0];
                            15:cy<=multiplyResult[35:0];
                            default:;
                        endcase
                        if(operation==5)state<=HOMO_SIGN;
                        else if(operation==15)begin pointIndex<=0;state<=POINT_BEGIN;end
                        else begin operation<=operation+4'd1;state<=HOMO_START;end
                    end
                end
                HOMO_SIGN:begin
                    if(determinant==0)begin reason<=SINGULAR;state<=FAILED;end
                    else begin
                        dNorm<=determinant<0?-determinant:determinant;
                        gNorm<=determinant<0?-gNumerator:gNumerator;
                        hNorm<=determinant<0?-hNumerator:hNumerator;
                        operation<=6;state<=HOMO_START;
                    end
                end
                POINT_BEGIN:begin
                    // Multiplication by320 is two constant shifts and an add.
                    numeratorX<=(60'(cx)<<<8)+(60'(cx)<<<6);
                    numeratorY<=(60'(cy)<<<8)+(60'(cy)<<<6);
                    denominator<=(60'(dNorm)<<<8)+(60'(dNorm)<<<6);
                    operation<=0;state<=POINT_START;
                end
                POINT_START:state<=POINT_WAIT;
                POINT_WAIT:if(multiplyDone)begin
                    if(pointSum[60:59]!={2{pointSum[59]}})begin reason<=ARITHMETIC_OVERFLOW;state<=FAILED;end
                    else begin
                        case(operation)
                            0,1:numeratorX<=pointSum[59:0];
                            2,3:numeratorY<=pointSum[59:0];
                            default:denominator<=pointSum[59:0];
                        endcase
                        if(operation==5)state<=DIVIDE_PREP;
                        else begin operation<=operation+4'd1;state<=POINT_START;end
                    end
                end
                DIVIDE_PREP:begin
                    if(denominator<=0)begin reason<=BAD_DENOMINATOR;state<=FAILED;end
                    else if(|magnitudeX[59:57] || |magnitudeY[59:57] || |denominator[59:48])begin
                        reason<=ARITHMETIC_OVERFLOW;state<=FAILED;
                    end else begin
                        // H yields half-pixel coordinates. Multiplication by8
                        // converts that result to native Q4 without rounding.
                        remainderX<={4'b0,magnitudeX}<<3;remainderY<={4'b0,magnitudeY}<<3;
                        negativeX<=numeratorX[59];negativeY<=numeratorY[59];
                        divisionDenominator<={4'b0,denominator};
                        shiftedDenominator<={4'b0,denominator}<<15;
                        quotientX<=0;quotientY<=0;divisionBit<=15;state<=DIVIDE;
                    end
                end
                DIVIDE:begin
                    if(remainderX>=shiftedDenominator)begin remainderX<=remainderX-shiftedDenominator;quotientX[divisionBit]<=1;end
                    if(remainderY>=shiftedDenominator)begin remainderY<=remainderY-shiftedDenominator;quotientY[divisionBit]<=1;end
                    shiftedDenominator<=shiftedDenominator>>1;
                    if(divisionBit==0)state<=STORE_POINT;else divisionBit<=divisionBit-4'd1;
                end
                STORE_POINT:begin
                    if(remainderX>=divisionDenominator || remainderY>=divisionDenominator ||
                       roundedX < -18'sd32768 || roundedX > 18'sd32767 ||
                       roundedY < -18'sd32768 || roundedY > 18'sd32767)begin reason<=ARITHMETIC_OVERFLOW;state<=FAILED;end
                    else if(heldRequireInImage[pointIndex] &&
                           (roundedX<0 || roundedY<0 || roundedX>=18'sd5120 || roundedY>=18'sd3840))begin
                        reason<=OUTSIDE_IMAGE;state<=FAILED;
                    end
                    else begin
                        mappedX[pointIndex]<=roundedX[15:0];mappedY[pointIndex]<=roundedY[15:0];
                        if(pointIndex+4'd1==heldCount)state<=FINISH;
                        else begin pointIndex<=pointIndex+4'd1;state<=POINT_BEGIN;end
                    end
                end
                FINISH:begin valid<=1;done<=1;reason<=OK;state<=IDLE;end
                FAILED:begin valid<=0;done<=1;mappedX<='0;mappedY<='0;state<=IDLE;end
                default:begin reason<=ARITHMETIC_OVERFLOW;state<=FAILED;end
            endcase
        end
    end
endmodule

// Exact signed multiplication, one request per completed twelve-clock shift/add.
// A's sign is extended before shifting; a12-bit magnitude also represents2048
// for B=-2048, so the minimum signed operand does not overflow during abs().
module calibrationSerialMultiply(
    input logic clk,reset,start,
    input logic signed [47:0] operandA,
    input logic signed [11:0] operandB,
    output logic signed [59:0] result,
    output logic done
);
    logic working,negativeB;
    logic [11:0] magnitudeB;
    logic [3:0] bitCount;
    logic signed [59:0] shiftedA,accumulator,nextAccumulator;
    always_comb nextAccumulator=accumulator+(magnitudeB[0]?shiftedA:60'sd0);
    always_ff @(posedge clk)begin
        if(reset)begin
            working<=0;negativeB<=0;magnitudeB<=0;bitCount<=0;
            shiftedA<=0;accumulator<=0;result<=0;done<=0;
        end else begin
            done<=0;
            if(start&&!working)begin
                working<=1;negativeB<=operandB[11];
                magnitudeB<=operandB[11]?-operandB:operandB;
                shiftedA<={{12{operandA[47]}},operandA};accumulator<=0;bitCount<=0;
            end else if(working)begin
                accumulator<=nextAccumulator;shiftedA<=shiftedA<<<1;magnitudeB<=magnitudeB>>1;
                if(bitCount==11)begin
                    result<=negativeB?-nextAccumulator:nextAccumulator;working<=0;done<=1;
                end else bitCount<=bitCount+4'd1;
            end
        end
    end
endmodule
