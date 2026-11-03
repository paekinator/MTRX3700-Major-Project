// Pair one measured blue component with one independently recognised red1.
// CLOCK_50 only; the caller owns the completed glyph/candidate bank throughout
// this transaction. No scene coordinates or expected digits enter this module.
// All coordinates below are native Q4 after the serial forward projection.
module calibrationGeometry (
    input logic clk,reset,start,
    input vision_pkg::colourQuad_t redQuad,blueQuad,
    input candidate_pkg::candidate_t redBox,
    input logic blueIsBay,
    output logic busy,done,pairValid,
    output logic [3:0] reason,
    output vision_pkg::samplePolygon_t redPolygon,bluePolygon
);
    import vision_pkg::*;
    import candidate_pkg::*;
    typedef enum logic [4:0] {IDLE,RED_ROI_START,RED_ROI_WAIT,
        RED_REFERENCE_START,RED_REFERENCE_WAIT,TRY_START,CORNER_CHECK,
        GUARD_CHECK,EDGE_ACTUAL,EDGE_EXPECTED,NEXT_CORNER,NEXT_ROTATION,
        BLUE_ROI_START,BLUE_ROI_WAIT,VALIDATE_SHAPE,FINISH,FAILED} state_t;
    state_t state;
    colourQuad_t heldRed,heldBlue;
    logic [1:0] rotation,winningRotation,corner,guardIndex;
    logic [1:0] matchCount;
    logic [1:0] shapeKind;
    logic [12:0] toleranceX,toleranceY;
    logic signed [3:0][15:0] expectedX,expectedY;
    logic signed [7:0][15:0] uLineX,uLineY,vLineX,vLineY;
    logic mapperStart,mapperBusy,mapperDone,mapperValid;
    logic [3:0] mapperReason,mapperCount;
    logic signed [3:0][10:0] mapperQuadX,mapperQuadY;
    logic signed [11:0][10:0] mapperU,mapperV;
    logic [11:0] mapperInside;
    logic signed [11:0][15:0] mappedX,mappedY;
    logic [1:0] actualIndex,nextActualIndex;
    logic [2:0] lineIndex;
    logic signed [15:0] actualX,actualY,nextX,nextY,lineAx,lineAy,lineBx,lineBy;
    logic signed [15:0] shapeX0,shapeY0,shapeX1,shapeY1,shapeX2,shapeY2;
    logic signed [16:0] differenceX,differenceY,factorA0,factorB0,factorA1,factorB1;
    logic signed [33:0] product0,product1;
    logic signed [34:0] crossValue,lengthValue;
    logic [34:0] actualLength;
    logic [37:0] fourActual,nineExpected;
    logic cornerGood,guardGood,expectedInside,uLinesGood,vLinesGood;

    calibrationPointMapper mapper(.clk(clk),.reset(reset),.start(mapperStart),
        .pointX(mapperQuadX),.pointY(mapperQuadY),.pointCount(mapperCount),
        .sampleU(mapperU),.sampleV(mapperV),.requireInImage(mapperInside),
        .busy(mapperBusy),.done(mapperDone),.valid(mapperValid),.reason(mapperReason),
        .mappedX(mappedX),.mappedY(mappedY));

    always_comb begin
        mapperStart=state==RED_ROI_START||state==RED_REFERENCE_START||state==BLUE_ROI_START;
        mapperQuadX=heldRed.x;mapperQuadY=heldRed.y;
        mapperU='0;mapperV='0;mapperInside=12'h00f;mapperCount=12;
        // One canonical unit is320. Inset fractions are quantised once here,
        // not fitted to a measured camera position. The two strip V values are
        // rounded from the artwork's47/45 and56/45; <=1/1440 unit error.
        mapperU[0]=26;mapperV[0]=96;mapperU[1]=58;mapperV[1]=96;
        mapperU[2]=58;mapperV[2]=224;mapperU[3]=26;mapperV[3]=224;
        mapperU[4]=-11'sd32;mapperV[4]=0;mapperU[5]=-11'sd32;mapperV[5]=320;
        mapperU[6]=32;mapperV[6]=0;mapperU[7]=32;mapperV[7]=320;
        mapperU[8]=288;mapperV[8]=0;mapperU[9]=288;mapperV[9]=320;
        mapperU[10]=352;mapperV[10]=0;mapperU[11]=352;mapperV[11]=320;
        if(state==RED_REFERENCE_START||state==RED_REFERENCE_WAIT)begin
            mapperCount=10;mapperInside=0;mapperU='0;mapperV='0;
            mapperU[0]=0;mapperV[0]=334;mapperU[1]=320;mapperV[1]=334;
            mapperU[2]=320;mapperV[2]=398;mapperU[3]=0;mapperV[3]=398;
            mapperU[4]=0;mapperV[4]=360;mapperU[5]=320;mapperV[5]=360;
            mapperU[6]=0;mapperV[6]=352;mapperU[7]=320;mapperV[7]=352;
            mapperU[8]=0;mapperV[8]=456;mapperU[9]=320;mapperV[9]=456;
        end else if(state==BLUE_ROI_START||state==BLUE_ROI_WAIT)begin
            // Keep the blue inset corner order tied to red1's anchor. A
            // component's arbitrary cyclic start must not look like movement
            // when the next frame validates the sampled polygon.
            for(int i=0;i<4;i++)begin
                mapperQuadX[i]=heldBlue.x[2'(i)+winningRotation];
                mapperQuadY[i]=heldBlue.y[2'(i)+winningRotation];
            end
            mapperCount=4;mapperInside=12'h00f;mapperU='0;mapperV='0;
            mapperU[0]=64;mapperV[0]=64;mapperU[1]=256;mapperV[1]=64;
            mapperU[2]=256;mapperV[2]=256;mapperU[3]=64;mapperV[3]=256;
        end

        expectedInside=1;
        uLinesGood=1;vLinesGood=1;
        for(int i=0;i<4;i++)begin
            // Outer edges may occupy the half-pixel field boundary. This is
            // not a claim that a physical card touching the image is complete.
            if($signed(mappedX[i])<-16'sd8||$signed(mappedX[i])>16'sd5112||
               $signed(mappedY[i])<-16'sd8||$signed(mappedY[i])>16'sd3832)expectedInside=0;
        end
        for(int i=0;i<4;i++)begin
            if(mappedX[4+2*i]==mappedX[5+2*i]&&mappedY[4+2*i]==mappedY[5+2*i])uLinesGood=0;
        end
        for(int i=0;i<3;i++)begin
            if(mappedX[4+2*i]==mappedX[5+2*i]&&mappedY[4+2*i]==mappedY[5+2*i])vLinesGood=0;
        end
        actualIndex=corner+rotation;nextActualIndex=actualIndex+2'd1;
        actualX=16'($signed(heldBlue.x[actualIndex]))<<<3;
        actualY=16'($signed(heldBlue.y[actualIndex]))<<<3;
        nextX=16'($signed(heldBlue.x[nextActualIndex]))<<<3;
        nextY=16'($signed(heldBlue.y[nextActualIndex]))<<<3;
        differenceX=17'($signed(actualX))-17'($signed(expectedX[corner]));
        differenceY=17'($signed(actualY))-17'($signed(expectedY[corner]));
        cornerGood=differenceX>=-$signed({4'b0,toleranceX})&&differenceX<=$signed({4'b0,toleranceX})&&
            differenceY>=-$signed({4'b0,toleranceY})&&differenceY<=$signed({4'b0,toleranceY});

        // Each corner is checked against four forward iso-coordinate lines.
        // U lines run towards increasing V; V lines towards increasing U.
        // Positive-area homography and positive denominators preserve signs.
        lineIndex=0;lineAx=0;lineAy=0;lineBx=0;lineBy=0;
        if(guardIndex<2)begin
            lineIndex=((corner==0||corner==3)?3'd0:3'd4)+(guardIndex[0]?3'd2:3'd0);
            lineAx=uLineX[lineIndex];lineAy=uLineY[lineIndex];
            lineBx=uLineX[lineIndex+3'd1];lineBy=uLineY[lineIndex+3'd1];
        end else begin
            lineIndex=(corner<2?3'd0:3'd4)+(guardIndex==3?3'd2:3'd0);
            lineAx=vLineX[lineIndex];lineAy=vLineY[lineIndex];
            lineBx=vLineX[lineIndex+3'd1];lineBy=vLineY[lineIndex+3'd1];
        end
        factorA0=17'($signed(lineBx))-17'($signed(lineAx));
        factorB0=17'($signed(actualY))-17'($signed(lineAy));
        factorA1=17'($signed(lineBy))-17'($signed(lineAy));
        factorB1=17'($signed(actualX))-17'($signed(lineAx));
        shapeX0=expectedX[corner];shapeY0=expectedY[corner];
        shapeX1=expectedX[corner+2'd1];shapeY1=expectedY[corner+2'd1];
        shapeX2=expectedX[corner+2'd2];shapeY2=expectedY[corner+2'd2];
        if(shapeKind==1)begin
            shapeX0=$signed({3'b0,redPolygon.x[corner]});shapeY0=$signed({3'b0,redPolygon.y[corner]});
            shapeX1=$signed({3'b0,redPolygon.x[corner+2'd1]});shapeY1=$signed({3'b0,redPolygon.y[corner+2'd1]});
            shapeX2=$signed({3'b0,redPolygon.x[corner+2'd2]});shapeY2=$signed({3'b0,redPolygon.y[corner+2'd2]});
        end else if(shapeKind==2)begin
            shapeX0=$signed({3'b0,bluePolygon.x[corner]});shapeY0=$signed({3'b0,bluePolygon.y[corner]});
            shapeX1=$signed({3'b0,bluePolygon.x[corner+2'd1]});shapeY1=$signed({3'b0,bluePolygon.y[corner+2'd1]});
            shapeX2=$signed({3'b0,bluePolygon.x[corner+2'd2]});shapeY2=$signed({3'b0,bluePolygon.y[corner+2'd2]});
        end
        // The same two17x17 multipliers handle edge lengths in later cycles.
        // Never unroll four candidates/corners/guards into parallel products.
        if(state==EDGE_ACTUAL)begin
            factorA0=17'($signed(nextX))-17'($signed(actualX));factorB0=factorA0;
            factorA1=17'($signed(nextY))-17'($signed(actualY));factorB1=factorA1;
        end else if(state==EDGE_EXPECTED)begin
            factorA0=17'($signed(expectedX[corner+2'd1]))-17'($signed(expectedX[corner]));factorB0=factorA0;
            factorA1=17'($signed(expectedY[corner+2'd1]))-17'($signed(expectedY[corner]));factorB1=factorA1;
        end else if(state==VALIDATE_SHAPE)begin
            factorA0=17'($signed(shapeX1))-17'($signed(shapeX0));
            factorB0=17'($signed(shapeY2))-17'($signed(shapeY1));
            factorA1=17'($signed(shapeY1))-17'($signed(shapeY0));
            factorB1=17'($signed(shapeX2))-17'($signed(shapeX1));
        end
        product0=factorA0*factorB0;product1=factorA1*factorB1;
        crossValue={product0[33],product0}-{product1[33],product1};
        lengthValue={product0[33],product0}+{product1[33],product1};
        case(guardIndex)
            0:guardGood=crossValue<=0;
            1,2:guardGood=crossValue>=0;
            default:guardGood=crossValue<=0;
        endcase
        fourActual={3'b0,actualLength}<<2;
        nineExpected=({3'b0,$unsigned(lengthValue)}<<3)+{3'b0,$unsigned(lengthValue)};
    end
    assign busy=state!=IDLE;
    always_ff @(posedge clk)begin
        if(reset)begin
            state<=IDLE;done<=0;pairValid<=0;reason<=0;
            redPolygon<='0;bluePolygon<='0;heldRed<='0;heldBlue<='0;
            expectedX<='0;expectedY<='0;uLineX<='0;uLineY<='0;vLineX<='0;vLineY<='0;
            rotation<=0;winningRotation<=0;corner<=0;guardIndex<=0;matchCount<=0;shapeKind<=0;
            toleranceX<=0;toleranceY<=0;actualLength<=0;
        end else begin
            done<=0;
            case(state)
                IDLE:if(start)begin
                    heldRed<=redQuad;heldBlue<=blueQuad;
                    pairValid<=0;reason<=0;redPolygon<='0;bluePolygon<='0;
                    matchCount<=0;rotation<=0;winningRotation<=0;corner<=0;guardIndex<=0;
                    // Thirteen-bit tolerance includes the Q4 scale. Native
                    // card dimensions are<=320; ceil(span/8)<=40 pixels.
                    toleranceX<=13'(((int'(redBox.xmax)-int'(redBox.xmin)+8)/8)*16);
                    toleranceY<=13'(((int'(redBox.ymax)-int'(redBox.ymin)+8)/8)*16);
                    if(!redQuad.valid||!blueQuad.valid||!redBox.valid||blueIsBay||
                       redBox.xmin>redBox.xmax||redBox.ymin>redBox.ymax||
                       redBox.xmax>=320||redBox.ymax>=240)begin reason<=1;state<=FAILED;end
                    else state<=RED_ROI_START;
                end
                RED_ROI_START:state<=RED_ROI_WAIT;
                RED_ROI_WAIT:if(mapperDone)begin
                    if(!mapperValid||!uLinesGood)begin reason<=2;state<=FAILED;end
                    else begin
                        for(int i=0;i<4;i++)begin redPolygon.x[i]<=13'(mappedX[i]);redPolygon.y[i]<=13'(mappedY[i]);end
                        for(int i=0;i<8;i++)begin uLineX[i]<=mappedX[i+4];uLineY[i]<=mappedY[i+4];end
                        state<=RED_REFERENCE_START;
                    end
                end
                RED_REFERENCE_START:state<=RED_REFERENCE_WAIT;
                RED_REFERENCE_WAIT:if(mapperDone)begin
                    if(!mapperValid||!expectedInside||!vLinesGood)begin reason<=3;state<=FAILED;end
                    else begin
                        for(int i=0;i<4;i++)begin expectedX[i]<=mappedX[i];expectedY[i]<=mappedY[i];end
                        vLineX[0]<=16'($signed(heldRed.x[3]))<<<3;vLineY[0]<=16'($signed(heldRed.y[3]))<<<3;
                        vLineX[1]<=16'($signed(heldRed.x[2]))<<<3;vLineY[1]<=16'($signed(heldRed.y[2]))<<<3;
                        for(int i=0;i<6;i++)begin vLineX[i+2]<=mappedX[i+4];vLineY[i+2]<=mappedY[i+4];end
                        shapeKind<=0;corner<=0;state<=VALIDATE_SHAPE;
                    end
                end
                TRY_START:begin corner<=0;state<=CORNER_CHECK;end
                CORNER_CHECK:begin
                    if(!cornerGood)state<=NEXT_ROTATION;
                    else begin guardIndex<=0;state<=GUARD_CHECK;end
                end
                GUARD_CHECK:begin
                    if(!guardGood)state<=NEXT_ROTATION;
                    else if(guardIndex==3)state<=EDGE_ACTUAL;
                    else guardIndex<=guardIndex+2'd1;
                end
                EDGE_ACTUAL:begin actualLength<=$unsigned(lengthValue);state<=EDGE_EXPECTED;end
                EDGE_EXPECTED:begin
                    if(lengthValue<=0||fourActual<{3'b0,$unsigned(lengthValue)}||fourActual>nineExpected)begin
                        state<=NEXT_ROTATION;
                    end else state<=NEXT_CORNER;
                end
                NEXT_CORNER:if(corner==3)begin
                    if(matchCount<2)matchCount<=matchCount+2'd1;
                    winningRotation<=rotation;
                    state<=NEXT_ROTATION;
                end else begin corner<=corner+2'd1;state<=CORNER_CHECK;end
                NEXT_ROTATION:if(rotation==3)begin
                    if(matchCount==1)state<=BLUE_ROI_START;
                    else begin reason<=4;state<=FAILED;end
                end else begin rotation<=rotation+2'd1;state<=TRY_START;end
                BLUE_ROI_START:state<=BLUE_ROI_WAIT;
                BLUE_ROI_WAIT:if(mapperDone)begin
                    if(!mapperValid)begin reason<=5;state<=FAILED;end
                    else begin
                        for(int i=0;i<4;i++)begin bluePolygon.x[i]<=13'(mappedX[i]);bluePolygon.y[i]<=13'(mappedY[i]);end
                        shapeKind<=1;corner<=0;state<=VALIDATE_SHAPE;
                    end
                end
                VALIDATE_SHAPE:begin
                    if(crossValue<=0)begin reason<=6;state<=FAILED;end
                    else if(corner!=3)corner<=corner+2'd1;
                    else if(shapeKind==0)state<=TRY_START;
                    else if(shapeKind==1)begin shapeKind<=2;corner<=0;end
                    else begin redPolygon.valid<=1;bluePolygon.valid<=1;pairValid<=1;state<=FINISH;end
                end
                FAILED:begin pairValid<=0;redPolygon<='0;bluePolygon<='0;state<=FINISH;end
                FINISH:begin done<=1;state<=IDLE;end
                default:begin reason<=15;state<=FAILED;end
            endcase
        end
    end
endmodule
