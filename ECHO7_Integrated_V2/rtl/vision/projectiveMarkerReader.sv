// Same-frame quadrilateral rectification and pixel-derived marker decoding.
// CLOCK_50 only; both RAM inputs have one synchronous read cycle of latency.
// Corner coordinates are found from RAW colour foreground within each candidate.
// A 32x40 canonical grid uses an exact integer homography. Coefficients share a
// denominator; each source x/y quotient is calculated in nine serial bit steps,
// rather than inferring a wide combinational division circuit. No grid position
// or candidate index supplies a digit answer.
module projectiveMarkerReader #(
    parameter int MIN_EDGE_PIXELS=24,
    parameter int MIN_QUAD_AREA=400,
    // Reader8 adds same-frame colour quads for projective calibration, while
    // preserving reader7's digit gates. Historical reader7 disables QUADS.
    // Reader6 replay disables only MAIN_COMPONENT;
    // reader5 replay disables both flags. These are compile-time identities,
    // never an automatic reinterpretation of an older recorded image.
    parameter bit ENFORCE_OWNER_BOUNDS=1'b1,
    parameter bit ENFORCE_MAIN_COMPONENT=1'b1,
    parameter bit EMIT_CALIBRATION_QUADS=1'b1,
    // Reader9 preserves every strict reader8 decision. Only a globally unique
    // thin strong-white seed may request one additional weak-support scan.
    parameter bit ENABLE_THIN_ANCHOR_SUPPORT=1'b1
) (
    input logic clk,reset,start,
    // Dense shared completed pool. The independent colour bit is metadata;
    // slot order never supplies a marker type or a recognised digit.
    input candidate_pkg::candidate_array_t sharedCandidates,
    input logic [15:0] sharedColours,
    input logic [1:0] orientationProfile,
    input logic bypassPerspective,
    output logic busy,done,
    output logic [16:0] readAddress,
    input logic readWhite,readStrongWhite,readColour,
    output vision_pkg::markerArray_t markers,
    // One-cycle synchronous port. The caller may inspect geometry after done
    // and must finish before the next start. Only the 16 validity bits reset;
    // the completed-frame quad words are stored in M10K, not a register mux.
    input logic [3:0] geometryReadIndex,
    output vision_pkg::colourQuad_t geometryReadQuad,
    output logic [4:0] acceptedCount
);
    import candidate_pkg::*;
    import vision_pkg::*;
    typedef enum logic [5:0] {
        IDLE,SETUP,SCAN_INIT,SCAN_WAIT,SCAN_SAMPLE,CORNER_PREP,GEOMETRY,
        HOMO_DELTAS,HOMO_PRODUCTS,HOMO_SIGN,HOMO_COEFF,GRID_NUM,GRID_PREP,
        DIVIDE,MAP_ADDRESS,GRID_WAIT,GRID_SAMPLE,DECIDE,NEXT,MULTIPLY_WAIT,GRID_INIT,ANCHOR_START,ANCHOR_WAIT,
        DIAMETER_INIT,DIAMETER_START,DIAMETER_WAIT,DIAMETER_NEXT,
        CROSS_INIT,CROSS_START,CROSS_WAIT,CROSS_NEXT,QUAD_SELECT,QUAD_CANON,ORIENTATION_FINISH,
        MAIN_START,MAIN_WAIT
    } state_t;
    state_t state;
    candidate_array_t heldCandidates;
    logic [15:0] heldColours;
    candidate_t box;
    logic [3:0] index;
    logic [1:0] orientation,orientationHint,hypothesisIndex,selectedOrientation,cornerBaseIndex;
    logic [1:0] anchorMatches;
    logic orientationResolved,orientationRejected;
    logic heldBypassPerspective;
    logic [8:0] scanX;
    logic [7:0] scanY;
    logic [9:0] boxWidth,boxHeight;
    // Sixteen fixed directions use additions and shifts only. Native x/y make
    // every signed score fit eleven bits (largest magnitude 2*319+239=877).
    // Fixed directions avoid the duplicate weighted extrema seen at 45deg.
    logic signed [10:0] supportScore[0:15],supportMaximum[0:15];
    logic [8:0] supportX[0:15];
    logic [7:0] supportY[0:15];
    logic [3:0] pairA,pairB,diameterA,diameterB,crossIndex,crossLowIndex,crossHighIndex;
    logic geometryProductPhase;
    logic [18:0] diameterSquared;
    logic signed [19:0] crossLow,crossHigh;
    logic signed [36:0] geometryFirstProduct,geometryCombinedProduct;
    logic signed [10:0] geometryDx,geometryDy,probeDx,probeDy;
    logic [10:0] cornerSumX;
    logic [9:0] cornerSumY;
    logic [1:0] nativeBaseIndex;
    logic [8:0] cornerX[0:3];
    logic [7:0] cornerY[0:3];
    // Signed half-pixel units. Raw contour corners are expanded by half a pixel
    // towards their native quadrant to represent the coloured rectangle edges.
    logic signed [10:0] pointX[0:3],pointY[0:3];
    logic [16:0] foregroundCount;
    logic geometryRejected,mapRejected;
    // Native x spans 0..319 and y 0..239. In half-pixel units a difference
    // therefore fits signed 11 bits (-640..640). Never promote geometry to
    // int32 multiplication: that consumed 74 DSPs in the first full fitter run.
    logic signed [24:0] areaTwice;
    logic signed [10:0] edgeDx[0:3],edgeDy[0:3];
    logic signed [22:0] crossProduct[0:3],areaTerm[0:3];
    logic [22:0] edgeSquared[0:3];
    logic quadrilateralGood,calibrationQuadGood;
    logic digitSizeGood;
    (* ramstyle="M10K" *) logic [87:0] geometryMemory[0:15];
    logic [15:0] geometryValid;
    logic [87:0] geometryWriteData,geometryReadData;
    logic geometryReadValid;
    wire geometryWrite=EMIT_CALIBRATION_QUADS&&state==GEOMETRY&&
        !heldBypassPerspective&&calibrationQuadGood;
    always_comb begin
        geometryWriteData='0;
        for(int corner=0;corner<4;corner++)begin
            geometryWriteData[corner*11+:11]=pointX[corner];
            geometryWriteData[44+corner*11+:11]=pointY[corner];
        end
        geometryReadQuad='0;
        if(geometryReadValid)begin
            geometryReadQuad.valid=1;
            geometryReadQuad.x=geometryReadData[43:0];
            geometryReadQuad.y=geometryReadData[87:44];
        end
    end
    always_ff @(posedge clk)begin
        if(geometryWrite)geometryMemory[index]<=geometryWriteData;
        geometryReadData<=geometryMemory[geometryReadIndex];
        if(reset)begin geometryValid<=0;geometryReadValid<=0;end
        else begin
            geometryReadValid<=geometryValid[geometryReadIndex];
            if(state==IDLE&&start)begin geometryValid<=0;geometryReadValid<=0;end
            else if(geometryWrite)geometryValid[index]<=1;
        end
    end
    logic signed [11:0] dx1,dx2,dx3,dy1,dy2,dy3;
    logic signed [24:0] determinant,gNumerator,hNumerator,dNorm,gNorm,hNorm;
    logic signed [35:0] ax,bx,cx,ay,by,cy;
    logic [3:0] multiplyOperation;
    logic signed [24:0] multiplyA;
    logic signed [11:0] multiplyB;
    logic signed [36:0] multiplyResult,firstProduct;
    logic multiplyDone;
    logic [4:0] gridX;
    logic [5:0] gridY;
    logic signed [9:0] gridU,gridV;
    logic signed [47:0] numeratorX,numeratorY,denominator;
    logic signed [47:0] rowNumeratorX,rowNumeratorY,rowDenominator;
    logic [47:0] remainderX,remainderY,divisionDenominator,shiftedDenominator;
    logic [8:0] quotientX,quotientY;
    logic [3:0] divisionBit;
    logic [7:0] strokeProjection[0:6];
    // Algorithm 2 counts one closed native component, not repeated grid taps.
    logic [16:0] anchorCount,anchorReadAddress,selectedAnchorCount;
    logic [8:0] anchorWidth,selectedAnchorWidth;
    logic [7:0] anchorHeight,selectedAnchorHeight;
    logic anchorDone;
    logic [1:0] anchorThinCount,totalThinSeeds,thinOrientation;
    logic anchorHazard,anchorSupportAccepted,fallbackHazard,fallbackScan,selectedFallback;
    logic [8:0] anchorThinXMin,anchorThinXMax,thinXMin,thinXMax;
    logic [7:0] anchorThinYMin,anchorThinYMax,thinYMin,thinYMax;
    logic [16:0] anchorThinStrongCount,thinStrongCount;
    logic [16:0] mainReadAddress,mainForegroundCount,mainComponentCount;
    logic [8:0] mainSupportX[0:15];
    logic [7:0] mainSupportY[0:15];
    logic [3:0] mainAllocationPeak;
    logic mainBusy,mainDone,mainGeometryValid,mainOverflow;
    logic [5:0] holeUpperWhite,holeLowerWhite;
    logic [6:0] segmentBits;
    logic uncertain,strongEvidence,shapeGood,highResolutionQuad;
    logic [3:0] decodedDigit;
    marker_t decision;
    // This bounded local CCL reads the same owned glyph bank as the rest of
    // the reader. It may pause at any native pixel while updating synchronous
    // support RAM; it does not stall the camera or introduce a new frame RAM.
    // Area selects a unique geometry component only. Digits still come from
    // the existing anchor, homography, stroke and hole checks below.
    mainColourSupportReader mainGeometry(
        .clk(clk),.reset(reset),.start(state==MAIN_START),
        .ownerXMin(box.xmin),.ownerXMax(box.xmax),.ownerYMin(box.ymin),.ownerYMax(box.ymax),
        .readAddress(mainReadAddress),.readColour(readColour),.busy(mainBusy),.done(mainDone),
        .geometryValid(mainGeometryValid),.overflow(mainOverflow),
        .supportX(mainSupportX),.supportY(mainSupportY),.foregroundCount(mainForegroundCount),
        .allocationPeak(mainAllocationPeak),.componentCount(mainComponentCount));
    nativeAnchorReader #(.ENFORCE_OWNER_BOUNDS(ENFORCE_OWNER_BOUNDS)) anchorReader(
        .clk(clk),.reset(reset),.start(state==ANCHOR_START),
        .pointX(pointX),.pointY(pointY),.busy(),.done(anchorDone),
        .ownerXMin(box.xmin),.ownerXMax(box.xmax),.ownerYMin(box.ymin),.ownerYMax(box.ymax),
        .readAddress(anchorReadAddress),.readWhite(readStrongWhite),
        .weakSupportMode(fallbackScan),.readWeakWhite(readWhite),
        .seedXMin(thinXMin),.seedXMax(thinXMax),.seedYMin(thinYMin),.seedYMax(thinYMax),
        .seedStrongCount(thinStrongCount),.thinSeedCount(anchorThinCount),
        .thinSeedXMin(anchorThinXMin),.thinSeedXMax(anchorThinXMax),
        .thinSeedYMin(anchorThinYMin),.thinSeedYMax(anchorThinYMax),
        .thinSeedStrongCount(anchorThinStrongCount),.thinSeedHazard(anchorHazard),
        .supportAccepted(anchorSupportAccepted),
        .anchorCount(anchorCount),.anchorWidth(anchorWidth),.anchorHeight(anchorHeight),
        .ambiguous(),.overflow(),.allocationPeak(),.componentCount());
    projectiveSerialMultiply coefficientMultiplier(.clk(clk),.reset(reset),
        .start(state==HOMO_PRODUCTS||state==DIAMETER_START||state==CROSS_START),.operandA(multiplyA),.operandB(multiplyB),
        .result(multiplyResult),.done(multiplyDone));

    function automatic integer population(input logic [7:0] value);
        integer total;
        begin total=0;for(int bitIndex=0;bitIndex<8;bitIndex++)total=total+int'(value[bitIndex]);population=total;end
    endfunction

    function automatic logic signed [10:0] directionScore(input integer direction,
        input logic [8:0] nativeX,input logic [7:0] nativeY);
        logic signed [10:0] sx,sy;
        begin
            sx=$signed({2'b0,nativeX});sy=$signed({3'b0,nativeY});
            case(direction)
                0:directionScore=sx;1:directionScore=(sx<<<1)+sy;
                2:directionScore=sx+sy;3:directionScore=sx+(sy<<<1);
                4:directionScore=sy;5:directionScore=-sx+(sy<<<1);
                6:directionScore=-sx+sy;7:directionScore=-(sx<<<1)+sy;
                8:directionScore=-sx;9:directionScore=-(sx<<<1)-sy;
                10:directionScore=-sx-sy;11:directionScore=-sx-(sy<<<1);
                12:directionScore=-sy;13:directionScore=sx-(sy<<<1);
                14:directionScore=sx-sy;default:directionScore=(sx<<<1)-sy;
            endcase
        end
    endfunction

    always_comb begin
        boxWidth={1'b0,box.xmax}-{1'b0,box.xmin}+10'd1;
        boxHeight={2'b0,box.ymax}-{2'b0,box.ymin}+10'd1;
        for(int direction=0;direction<16;direction++)supportScore[direction]=directionScore(direction,scanX,scanY);
        // Search only the sixteen measured supports. Reuse the existing serial
        // multiplier for 120 diameter pairs and sixteen signed cross products.
        geometryDx=$signed({2'b0,supportX[pairB]})-$signed({2'b0,supportX[pairA]});
        geometryDy=$signed({3'b0,supportY[pairB]})-$signed({3'b0,supportY[pairA]});
        probeDx=$signed({2'b0,supportX[crossIndex]})-$signed({2'b0,supportX[diameterA]});
        probeDy=$signed({3'b0,supportY[crossIndex]})-$signed({3'b0,supportY[diameterA]});
        geometryCombinedProduct=state==CROSS_WAIT?geometryFirstProduct-multiplyResult:geometryFirstProduct+multiplyResult;
        // Stable native corner naming: min(x+y), then smaller y, then x. The
        // selected marker orientation is a cyclic offset from this corner; it
        // does not rotate the external native bbox or B/C coordinates.
        nativeBaseIndex=0;
        for(int corner=1;corner<4;corner++)begin
            if(({1'b0,cornerX[corner]}+{2'b0,cornerY[corner]} <
                {1'b0,cornerX[nativeBaseIndex]}+{2'b0,cornerY[nativeBaseIndex]})||
               (({1'b0,cornerX[corner]}+{2'b0,cornerY[corner]} ==
                 {1'b0,cornerX[nativeBaseIndex]}+{2'b0,cornerY[nativeBaseIndex]})&&
                (cornerY[corner]<cornerY[nativeBaseIndex]||
                 (cornerY[corner]==cornerY[nativeBaseIndex]&&cornerX[corner]<cornerX[nativeBaseIndex]))))
                nativeBaseIndex=2'(corner);
        end
        areaTwice=0;quadrilateralGood=foregroundCount>=32;highResolutionQuad=1;
        calibrationQuadGood=foregroundCount>=32;
        digitSizeGood=boxWidth>=MIN_EDGE_PIXELS&&boxHeight>=MIN_EDGE_PIXELS;
        for(int i=0;i<4;i++)begin
            edgeDx[i]=pointX[(i+1)%4]-pointX[i];
            edgeDy[i]=pointY[(i+1)%4]-pointY[i];
            areaTerm[i]=pointX[i]*pointY[(i+1)%4]-pointY[i]*pointX[(i+1)%4];
            areaTwice=areaTwice+areaTerm[i];
        end
        for(int i=0;i<4;i++)begin
            crossProduct[i]=edgeDx[i]*edgeDy[(i+1)%4]-edgeDy[i]*edgeDx[(i+1)%4];
            edgeSquared[i]=edgeDx[i]*edgeDx[i]+edgeDy[i]*edgeDy[i];
            if(crossProduct[i]<=0 || edgeSquared[i] < 23'(4*MIN_EDGE_PIXELS*MIN_EDGE_PIXELS))
                quadrilateralGood=0;
            // A calibration strip may be thinner than a numbered card. Its
            // separate geometry gate cannot relax the digit's 24-pixel edge.
            if(crossProduct[i]<=0 || edgeSquared[i]<23'd64)
                calibrationQuadGood=0;
            if(edgeSquared[i]<23'd6400)highResolutionQuad=0;
        end
        // point coordinates are doubled, so twice-area is eight times pixel area.
        if(areaTwice<8*MIN_QUAD_AREA)quadrilateralGood=0;
        if(areaTwice<25'sd256)calibrationQuadGood=0;
        gridU=$signed({1'b0,gridX,1'b1})*10'sd5;
        gridV=$signed({1'b0,gridY,1'b1})*10'sd4;
        // One signed shift/add multiplier is time-shared across determinant and
        // all six coefficients. These values change once per candidate only.
        multiplyA=0;multiplyB=0;
        case(multiplyOperation)
            0:begin multiplyA=dx1;multiplyB=dy2;end
            1:begin multiplyA=dx2;multiplyB=dy1;end
            2:begin multiplyA=dx3;multiplyB=dy2;end
            3:begin multiplyA=dx2;multiplyB=dy3;end
            4:begin multiplyA=dx1;multiplyB=dy3;end
            5:begin multiplyA=dx3;multiplyB=dy1;end
            6:begin multiplyA=dNorm;multiplyB=pointX[1]-pointX[0];end
            7:begin multiplyA=gNorm;multiplyB=pointX[1];end
            8:begin multiplyA=dNorm;multiplyB=pointX[3]-pointX[0];end
            9:begin multiplyA=hNorm;multiplyB=pointX[3];end
            10:begin multiplyA=dNorm;multiplyB=pointX[0];end
            11:begin multiplyA=dNorm;multiplyB=pointY[1]-pointY[0];end
            12:begin multiplyA=gNorm;multiplyB=pointY[1];end
            13:begin multiplyA=dNorm;multiplyB=pointY[3]-pointY[0];end
            14:begin multiplyA=hNorm;multiplyB=pointY[3];end
            default:begin multiplyA=dNorm;multiplyB=pointY[0];end
        endcase
        if(state==DIAMETER_START||state==DIAMETER_WAIT)begin
            multiplyA=geometryProductPhase?geometryDy:geometryDx;
            multiplyB=geometryProductPhase?geometryDy:geometryDx;
        end else if(state==CROSS_START||state==CROSS_WAIT)begin
            multiplyA=geometryProductPhase?
                $signed({3'b0,supportY[diameterB]})-$signed({3'b0,supportY[diameterA]}):
                $signed({2'b0,supportX[diameterB]})-$signed({2'b0,supportX[diameterA]});
            multiplyB=geometryProductPhase?probeDx:probeDy;
        end
        if(state==ANCHOR_START||state==ANCHOR_WAIT)readAddress=anchorReadAddress;
        else if(state==MAIN_START||state==MAIN_WAIT)readAddress=mainReadAddress;
        else if(state==SCAN_INIT||state==SCAN_WAIT||state==SCAN_SAMPLE)
            readAddress=17'(scanY)*17'd320+17'(scanX);
        else readAddress=17'(quotientY)*17'd320+17'(quotientX);
        segmentBits=0;uncertain=0;
        // A two-pixel stroke can classify consistently yet does not justify the
        // strongest quality tier. Every quadrilateral edge must span >=40 px.
        strongEvidence=selectedAnchorCount>=4&&highResolutionQuad&&!selectedFallback;
        for(int i=0;i<7;i++)begin
            // Horizontal strokes cover eight independent canonical columns;
            // vertical strokes cover seven rows. Middle evidence is rejected.
            if(population(strokeProjection[i])>=5)begin
                segmentBits[i]=1;
                if(population(strokeProjection[i]) < ((i==0||i==3||i==6)?7:6))strongEvidence=0;
            end else if(population(strokeProjection[i])>2)uncertain=1;
        end
        shapeGood=selectedAnchorCount>=3&&selectedAnchorWidth>=2&&selectedAnchorHeight>=2&&
            holeUpperWhite<=4&&holeLowerWhite<=4;
        decodedDigit=15;
        case(segmentBits)
            7'b0000110:decodedDigit=1;
            7'b1011011:decodedDigit=2;
            7'b1001111:decodedDigit=3;
            7'b1100110:decodedDigit=4;
            7'b1101101:decodedDigit=5;
            7'b1111101:decodedDigit=6;
            default:decodedDigit=15;
        endcase
        decision='0;decision.isBlue=heldColours[index];decision.digit=15;
        decision.xMin=box.xmin;decision.xMax=box.xmax;decision.yMin=box.ymin;decision.yMax=box.ymax;
        decision.orientation=orientation;decision.segments=segmentBits;
        if(geometryRejected)decision.reason=1;
        else if(mapRejected)decision.reason=6;
        else if(orientationRejected)decision.reason=4;
        else if(uncertain)decision.reason=3;
        else if(!shapeGood)decision.reason=4;
        else if(decodedDigit==15||(!heldColours[index]&&decodedDigit>2))decision.reason=5;
        else begin decision.accepted=1;decision.digit=decodedDigit;decision.quality=strongEvidence?8'd255:8'd192;end
    end
    assign busy=state!=IDLE;

    always_ff @(posedge clk)begin
        if(reset)begin
            state<=IDLE;done<=0;markers<='0;acceptedCount<=0;
            heldCandidates<='0;heldColours<=0;box<='0;index<=0;orientation<=0;orientationHint<=0;heldBypassPerspective<=0;
            scanX<=0;scanY<=0;foregroundCount<=0;geometryRejected<=0;mapRejected<=0;
            hypothesisIndex<=0;selectedOrientation<=0;cornerBaseIndex<=0;anchorMatches<=0;
            orientationResolved<=0;orientationRejected<=0;
            totalThinSeeds<=0;thinOrientation<=0;fallbackHazard<=0;fallbackScan<=0;selectedFallback<=0;
            thinXMin<=0;thinXMax<=0;thinYMin<=0;thinYMax<=0;thinStrongCount<=0;
            pairA<=0;pairB<=1;diameterA<=0;diameterB<=0;crossIndex<=0;crossLowIndex<=0;crossHighIndex<=0;
            geometryProductPhase<=0;diameterSquared<=0;crossLow<=0;crossHigh<=0;geometryFirstProduct<=0;
            cornerSumX<=0;cornerSumY<=0;
            selectedAnchorCount<=0;selectedAnchorWidth<=0;selectedAnchorHeight<=0;
            for(int direction=0;direction<16;direction++)begin
                supportMaximum[direction]<=0;supportX[direction]<=0;supportY[direction]<=0;
            end
            dx1<=0;dx2<=0;dx3<=0;dy1<=0;dy2<=0;dy3<=0;
            determinant<=0;gNumerator<=0;hNumerator<=0;dNorm<=0;gNorm<=0;hNorm<=0;
            ax<=0;bx<=0;cx<=0;ay<=0;by<=0;cy<=0;
            multiplyOperation<=0;firstProduct<=0;
            gridX<=0;gridY<=0;numeratorX<=0;numeratorY<=0;denominator<=0;
            rowNumeratorX<=0;rowNumeratorY<=0;rowDenominator<=0;
            remainderX<=0;remainderY<=0;divisionDenominator<=0;shiftedDenominator<=0;divisionBit<=0;quotientX<=0;quotientY<=0;
            holeUpperWhite<=0;holeLowerWhite<=0;
            for(int i=0;i<4;i++)begin cornerX[i]<=0;cornerY[i]<=0;pointX[i]<=0;pointY[i]<=0;end
            for(int i=0;i<7;i++)strokeProjection[i]<=0;
        end else begin
            done<=0;
            case(state)
                IDLE:if(start)begin
                    heldCandidates<=sharedCandidates;heldColours<=sharedColours;orientationHint<=orientationProfile;
                    heldBypassPerspective<=bypassPerspective;
                    index<=0;markers<='0;acceptedCount<=0;state<=SETUP;
                end
                SETUP:begin
                    box<=heldCandidates[index];
                    for(int direction=0;direction<16;direction++)begin
                        supportMaximum[direction]<=-11'sd1024;supportX[direction]<=0;supportY[direction]<=0;
                    end
                    orientation<=orientationHint;hypothesisIndex<=0;selectedOrientation<=0;
                    anchorMatches<=0;orientationResolved<=0;orientationRejected<=0;
                    totalThinSeeds<=0;thinOrientation<=0;fallbackHazard<=0;fallbackScan<=0;selectedFallback<=0;
                    thinXMin<=0;thinXMax<=0;thinYMin<=0;thinYMax<=0;thinStrongCount<=0;
                    selectedAnchorCount<=0;selectedAnchorWidth<=0;selectedAnchorHeight<=0;
                    foregroundCount<=0;geometryRejected<=0;mapRejected<=0;
                    holeUpperWhite<=0;holeLowerWhite<=0;
                    for(int i=0;i<4;i++)begin cornerX[i]<=0;cornerY[i]<=0;end
                    for(int i=0;i<7;i++)strokeProjection[i]<=0;
                    state<=SCAN_INIT;
                end
                SCAN_INIT:begin
                    scanX<=box.xmin;scanY<=box.ymin;
                    if(!box.valid||box.xmin>box.xmax||box.ymin>box.ymax||box.xmax>=320||box.ymax>=240||
                        ((!EMIT_CALIBRATION_QUADS||heldBypassPerspective||!heldColours[index])&&!digitSizeGood)||
                        boxWidth<4||boxHeight<4)begin geometryRejected<=1;state<=DECIDE;end
                    else if(ENFORCE_MAIN_COMPONENT&&!heldBypassPerspective)state<=MAIN_START;
                    else state<=SCAN_WAIT;
                end
                MAIN_START:state<=MAIN_WAIT;
                MAIN_WAIT:if(mainDone)begin
                    // SETUP already clears all supports/counts. A failed local
                    // scan must not publish old geometry from a prior marker.
                    if(!mainGeometryValid||mainOverflow)begin geometryRejected<=1;state<=DECIDE;end
                    else begin
                        for(int direction=0;direction<16;direction++)begin
                            supportX[direction]<=mainSupportX[direction];
                            supportY[direction]<=mainSupportY[direction];
                        end
                        // Preserve the historical >=32 RAW foreground gate;
                        // this count is not the winning component's area.
                        foregroundCount<=mainForegroundCount;
                        state<=DIAMETER_INIT;
                    end
                end
                SCAN_WAIT:state<=SCAN_SAMPLE;
                SCAN_SAMPLE:begin
                    if(readColour)begin
                        foregroundCount<=foregroundCount+17'd1;
                        for(int direction=0;direction<16;direction++)begin
                            if(supportScore[direction]>supportMaximum[direction])begin
                                supportMaximum[direction]<=supportScore[direction];
                                supportX[direction]<=scanX;supportY[direction]<=scanY;
                            end
                        end
                    end
                    if(scanX==box.xmax)begin
                        scanX<=box.xmin;
                        if(scanY==box.ymax)state<=DIAMETER_INIT;
                        else begin scanY<=scanY+8'd1;state<=SCAN_WAIT;end
                    end else begin scanX<=scanX+9'd1;state<=SCAN_WAIT;end
                end
                DIAMETER_INIT:begin
                    pairA<=0;pairB<=1;diameterA<=0;diameterB<=0;diameterSquared<=0;
                    geometryProductPhase<=0;state<=heldBypassPerspective?QUAD_SELECT:DIAMETER_START;
                end
                DIAMETER_START:state<=DIAMETER_WAIT;
                DIAMETER_WAIT:if(multiplyDone)begin
                    if(!geometryProductPhase)begin
                        geometryFirstProduct<=multiplyResult;geometryProductPhase<=1;state<=DIAMETER_START;
                    end else begin
                        if(geometryCombinedProduct>$signed({18'd0,diameterSquared}))begin
                            diameterSquared<=19'(geometryCombinedProduct);diameterA<=pairA;diameterB<=pairB;
                        end
                        state<=DIAMETER_NEXT;
                    end
                end
                DIAMETER_NEXT:begin
                    geometryProductPhase<=0;
                    if(pairB==15)begin
                        if(pairA==14)state<=CROSS_INIT;
                        else begin pairA<=pairA+4'd1;pairB<=pairA+4'd2;state<=DIAMETER_START;end
                    end else begin pairB<=pairB+4'd1;state<=DIAMETER_START;end
                end
                CROSS_INIT:begin
                    crossIndex<=0;crossLow<=0;crossHigh<=0;crossLowIndex<=diameterA;crossHighIndex<=diameterA;
                    geometryProductPhase<=0;state<=CROSS_START;
                end
                CROSS_START:state<=CROSS_WAIT;
                CROSS_WAIT:if(multiplyDone)begin
                    if(!geometryProductPhase)begin
                        geometryFirstProduct<=multiplyResult;geometryProductPhase<=1;state<=CROSS_START;
                    end else begin
                        if(geometryCombinedProduct<crossLow)begin crossLow<=20'(geometryCombinedProduct);crossLowIndex<=crossIndex;end
                        if(geometryCombinedProduct>crossHigh)begin crossHigh<=20'(geometryCombinedProduct);crossHighIndex<=crossIndex;end
                        state<=CROSS_NEXT;
                    end
                end
                CROSS_NEXT:begin
                    geometryProductPhase<=0;
                    if(crossIndex==15)state<=QUAD_SELECT;
                    else begin crossIndex<=crossIndex+4'd1;state<=CROSS_START;end
                end
                QUAD_SELECT:begin
                    if(heldBypassPerspective)begin
                        cornerX[0]<=box.xmin;cornerY[0]<=box.ymin;cornerX[1]<=box.xmax;cornerY[1]<=box.ymin;
                        cornerX[2]<=box.xmax;cornerY[2]<=box.ymax;cornerX[3]<=box.xmin;cornerY[3]<=box.ymax;
                    end else begin
                        cornerX[0]<=supportX[diameterA];cornerY[0]<=supportY[diameterA];
                        cornerX[1]<=supportX[crossLowIndex];cornerY[1]<=supportY[crossLowIndex];
                        cornerX[2]<=supportX[diameterB];cornerY[2]<=supportY[diameterB];
                        cornerX[3]<=supportX[crossHighIndex];cornerY[3]<=supportY[crossHighIndex];
                    end
                    state<=QUAD_CANON;
                end
                QUAD_CANON:begin
                    cornerBaseIndex<=nativeBaseIndex;
                    cornerSumX<={2'b0,cornerX[0]}+{2'b0,cornerX[1]}+{2'b0,cornerX[2]}+{2'b0,cornerX[3]};
                    cornerSumY<={2'b0,cornerY[0]}+{2'b0,cornerY[1]}+{2'b0,cornerY[2]}+{2'b0,cornerY[3]};
                    state<=CORNER_PREP;
                end
                CORNER_PREP:begin
                    for(int i=0;i<4;i++)begin
                        // R9 baseline: use the axis-aligned colour bbox, while
                        // retaining actual same-frame glyph pixels, anchor and
                        // all rejection rules. It removes perspective recovery
                        // rather than fabricating a failure or changing an ID.
                        pointX[i]<=11'({1'b0,cornerX[(i+int'(orientation)+int'(cornerBaseIndex))%4],1'b0})+
                            ({cornerX[(i+int'(orientation)+int'(cornerBaseIndex))%4],2'b0}>cornerSumX?11'sd1:
                             {cornerX[(i+int'(orientation)+int'(cornerBaseIndex))%4],2'b0}<cornerSumX?-11'sd1:11'sd0);
                        pointY[i]<=11'({2'b0,cornerY[(i+int'(orientation)+int'(cornerBaseIndex))%4],1'b0})+
                            ({cornerY[(i+int'(orientation)+int'(cornerBaseIndex))%4],2'b0}>cornerSumY?11'sd1:
                             {cornerY[(i+int'(orientation)+int'(cornerBaseIndex))%4],2'b0}<cornerSumY?-11'sd1:11'sd0);
                    end
                    state<=GEOMETRY;
                end
                GEOMETRY:begin
                    if(!quadrilateralGood||!digitSizeGood)begin geometryRejected<=1;state<=DECIDE;end
                    else state<=orientationResolved?HOMO_DELTAS:ANCHOR_START;
                end
                ANCHOR_START:state<=ANCHOR_WAIT;
                ANCHOR_WAIT:if(anchorDone)begin
                    if(fallbackScan)begin
                        // The weak component contributes only two-dimensional
                        // support. Its true strong seed count is preserved;
                        // the caller marks this evidence tier explicitly.
                        if(anchorSupportAccepted&&anchorCount>=3&&anchorWidth>=2&&anchorHeight>=2)begin
                            selectedAnchorCount<=anchorCount;selectedAnchorWidth<=anchorWidth;
                            selectedAnchorHeight<=anchorHeight;selectedOrientation<=orientation;
                            selectedFallback<=1;orientationResolved<=1;state<=CORNER_PREP;
                        end else begin orientation<=orientationHint;orientationRejected<=1;state<=DECIDE;end
                    end else begin
                    if(anchorCount>=3&&anchorWidth>=2&&anchorHeight>=2)begin
                        if(anchorMatches<2)anchorMatches<=anchorMatches+2'd1;
                        selectedOrientation<=orientation;selectedAnchorCount<=anchorCount;
                        selectedAnchorWidth<=anchorWidth;selectedAnchorHeight<=anchorHeight;
                    end
                    if(ENABLE_THIN_ANCHOR_SUPPORT&&!heldBypassPerspective)begin
                        fallbackHazard<=fallbackHazard||anchorHazard;
                        if({1'b0,totalThinSeeds}+{1'b0,anchorThinCount}>=3'd2)totalThinSeeds<=2;
                        else totalThinSeeds<=totalThinSeeds+anchorThinCount;
                        if(totalThinSeeds==0&&anchorThinCount==1)begin
                            thinOrientation<=orientation;thinStrongCount<=anchorThinStrongCount;
                            thinXMin<=anchorThinXMin;thinXMax<=anchorThinXMax;
                            thinYMin<=anchorThinYMin;thinYMax<=anchorThinYMax;
                        end
                    end
                    if(hypothesisIndex==3)state<=ORIENTATION_FINISH;
                    else begin hypothesisIndex<=hypothesisIndex+2'd1;orientation<=orientation+2'd1;state<=CORNER_PREP;end
                    end
                end
                ORIENTATION_FINISH:begin
                    if(anchorMatches==1)begin orientation<=selectedOrientation;orientationResolved<=1;state<=CORNER_PREP;end
                    else if(ENABLE_THIN_ANCHOR_SUPPORT&&!heldBypassPerspective&&anchorMatches==0&&
                            !fallbackHazard&&totalThinSeeds==1)begin
                        orientation<=thinOrientation;fallbackScan<=1;state<=CORNER_PREP;
                    end
                    else begin orientation<=orientationHint;orientationRejected<=1;state<=DECIDE;end
                end
                HOMO_DELTAS:begin
                    dx1<=pointX[1]-pointX[2];dx2<=pointX[3]-pointX[2];dx3<=pointX[0]-pointX[1]+pointX[2]-pointX[3];
                    dy1<=pointY[1]-pointY[2];dy2<=pointY[3]-pointY[2];dy3<=pointY[0]-pointY[1]+pointY[2]-pointY[3];
                    multiplyOperation<=0;state<=HOMO_PRODUCTS;
                end
                HOMO_PRODUCTS:state<=MULTIPLY_WAIT;
                MULTIPLY_WAIT:if(multiplyDone)begin
                    case(multiplyOperation)
                        0,2,4,6,8,11,13:firstProduct<=multiplyResult;
                        1:determinant<=25'(firstProduct-multiplyResult);
                        3:gNumerator<=25'(firstProduct-multiplyResult);
                        5:hNumerator<=25'(firstProduct-multiplyResult);
                        7:ax<=36'(firstProduct+multiplyResult);
                        9:bx<=36'(firstProduct+multiplyResult);
                        10:cx<=36'(multiplyResult);
                        12:ay<=36'(firstProduct+multiplyResult);
                        14:by<=36'(firstProduct+multiplyResult);
                        15:cy<=36'(multiplyResult);
                        default:;
                    endcase
                    if(multiplyOperation==5)state<=HOMO_SIGN;
                    else if(multiplyOperation==15)state<=GRID_INIT;
                    else begin multiplyOperation<=multiplyOperation+4'd1;state<=HOMO_PRODUCTS;end
                end
                HOMO_SIGN:begin
                    if(determinant==0)begin geometryRejected<=1;state<=DECIDE;end
                    else begin
                        dNorm<=determinant<0?-determinant:determinant;
                        gNorm<=determinant<0?-gNumerator:gNumerator;
                        hNorm<=determinant<0?-hNumerator:hNumerator;
                        state<=HOMO_COEFF;
                    end
                end
                HOMO_COEFF:begin
                    multiplyOperation<=6;state<=HOMO_PRODUCTS;
                end
                GRID_INIT:begin
                    // U=5+10*x and V=4+8*y. Exact row/column recurrence keeps
                    // every homography numerator identical to direct evaluation.
                    // Constant multipliers below reduce to shifts/adds, not DSPs.
                    rowNumeratorX<=ax*48'sd5+bx*48'sd4+cx*48'sd320;
                    rowNumeratorY<=ay*48'sd5+by*48'sd4+cy*48'sd320;
                    rowDenominator<=gNorm*48'sd5+hNorm*48'sd4+dNorm*48'sd320;
                    numeratorX<=ax*48'sd5+bx*48'sd4+cx*48'sd320;
                    numeratorY<=ay*48'sd5+by*48'sd4+cy*48'sd320;
                    denominator<=gNorm*48'sd5+hNorm*48'sd4+dNorm*48'sd320;
                    gridX<=0;gridY<=0;state<=GRID_NUM;
                end
                GRID_NUM:state<=GRID_PREP;
                GRID_PREP:begin
                    // Coordinates are doubled. Add denominator before dividing
                    // by 2*denominator to round to the nearest native pixel.
                    if(denominator<=0||numeratorX+denominator<0||numeratorY+denominator<0)begin mapRejected<=1;state<=DECIDE;end
                    else begin
                        remainderX<=numeratorX+denominator;remainderY<=numeratorY+denominator;
                        divisionDenominator<=denominator<<1;shiftedDenominator<=denominator<<9;
                        divisionBit<=8;quotientX<=0;quotientY<=0;state<=DIVIDE;
                    end
                end
                DIVIDE:begin
                    if(remainderX>=shiftedDenominator)begin remainderX<=remainderX-shiftedDenominator;quotientX[divisionBit]<=1;end
                    if(remainderY>=shiftedDenominator)begin remainderY<=remainderY-shiftedDenominator;quotientY[divisionBit]<=1;end
                    shiftedDenominator<=shiftedDenominator>>1;
                    if(divisionBit==0)state<=MAP_ADDRESS;
                    else divisionBit<=divisionBit-4'd1;
                end
                MAP_ADDRESS:begin
                    if(quotientX>=320||quotientY>=240||remainderX>=divisionDenominator||remainderY>=divisionDenominator)
                        begin mapRejected<=1;state<=DECIDE;end
                    else state<=GRID_WAIT;
                end
                GRID_WAIT:state<=GRID_SAMPLE;
                GRID_SAMPLE:begin
                    if(readWhite)begin
                        if(gridX>=12&&gridX<=19)begin
                            if(gridY>=4&&gridY<=8)strokeProjection[0][gridX-12]<=1;
                            if(gridY>=18&&gridY<=21)strokeProjection[6][gridX-12]<=1;
                            if(gridY>=31&&gridY<=35)strokeProjection[3][gridX-12]<=1;
                        end
                        if(gridY>=10&&gridY<=16)begin
                            if(gridX>=21&&gridX<=24)strokeProjection[1][gridY-10]<=1;
                            if(gridX>=7&&gridX<=10)strokeProjection[5][gridY-10]<=1;
                        end
                        if(gridY>=23&&gridY<=29)begin
                            if(gridX>=21&&gridX<=24)strokeProjection[2][gridY-23]<=1;
                            if(gridX>=7&&gridX<=10)strokeProjection[4][gridY-23]<=1;
                        end
                        if(gridX>=13&&gridX<=18)begin
                            if(gridY>=12&&gridY<=15)holeUpperWhite<=holeUpperWhite+6'd1;
                            if(gridY>=24&&gridY<=27)holeLowerWhite<=holeLowerWhite+6'd1;
                        end
                    end
                    if(gridX==31)begin
                        gridX<=0;
                        if(gridY==39)state<=DECIDE;
                        else begin
                            gridY<=gridY+6'd1;
                            rowNumeratorX<=rowNumeratorX+bx*48'sd8;rowNumeratorY<=rowNumeratorY+by*48'sd8;
                            rowDenominator<=rowDenominator+hNorm*48'sd8;
                            numeratorX<=rowNumeratorX+bx*48'sd8;numeratorY<=rowNumeratorY+by*48'sd8;
                            denominator<=rowDenominator+hNorm*48'sd8;state<=GRID_NUM;
                        end
                    end else begin
                        gridX<=gridX+5'd1;numeratorX<=numeratorX+ax*48'sd10;numeratorY<=numeratorY+ay*48'sd10;
                        denominator<=denominator+gNorm*48'sd10;state<=GRID_NUM;
                    end
                end
                DECIDE:begin
                    markers[index]<=decision;if(decision.accepted)acceptedCount<=acceptedCount+5'd1;state<=NEXT;
                end
                NEXT:if(index==15)begin done<=1;state<=IDLE;end
                    else begin index<=index+4'd1;state<=SETUP;end
                default:state<=IDLE;
            endcase
        end
    end
endmodule

// One candidate coefficient product per 12 clocks. operandA is signed 25 bits,
// operandB signed 12 bits; the full exact signed product is 37 bits. The 12-bit
// magnitude handles -2048 without overflowing a signed absolute-value register.
module projectiveSerialMultiply(
    input logic clk,reset,start,
    input logic signed [24:0] operandA,
    input logic signed [11:0] operandB,
    output logic signed [36:0] result,
    output logic done
);
    logic working,negativeB;
    logic [11:0] magnitudeB;
    logic [3:0] bitCount;
    logic signed [36:0] shiftedA,accumulator,nextAccumulator;
    always_comb nextAccumulator=accumulator+(magnitudeB[0]?shiftedA:37'sd0);
    always_ff @(posedge clk)begin
        if(reset)begin
            working<=0;negativeB<=0;magnitudeB<=0;bitCount<=0;
            shiftedA<=0;accumulator<=0;result<=0;done<=0;
        end else begin
            done<=0;
            if(start&&!working)begin
                working<=1;negativeB<=operandB[11];
                magnitudeB<=operandB[11]?-operandB:operandB;
                shiftedA<={{12{operandA[24]}},operandA};accumulator<=0;bitCount<=0;
            end else if(working)begin
                accumulator<=nextAccumulator;shiftedA<=shiftedA<<<1;magnitudeB<=magnitudeB>>1;
                if(bitCount==11)begin
                    result<=negativeB?-nextAccumulator:nextAccumulator;working<=0;done<=1;
                end else bitCount<=bitCount+4'd1;
            end
        end
    end
endmodule
