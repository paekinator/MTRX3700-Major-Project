// Readers6..8 retain the original strict scan. Reader9 may request one separate
// weak-support scan after its caller has completed all four strict hypotheses.
// The weak scan proves the full component around an already measured thin
// strong seed; it never lowers the strong threshold or invents white pixels.
// CLOCK_50 only. readWhite has one synchronous RAM cycle of latency.
// The caller supplies the original, orientation-ordered half-pixel quad.
// CAP bounds active labels INCLUDING aliases; any exhaustion rejects the anchor.
// The single previous-row label RAM is not reset: row zero ignores and replaces
// all entries used by this ROI. Components retire after a full canonical pass.
module nativeAnchorReader #(
    parameter int CAP=8,
    // Disable only for explicitly labelled historical reader1..5 RTL replay.
    parameter bit ENFORCE_OWNER_BOUNDS=1'b1
)(
    input logic clk,reset,start,
    input logic signed [10:0] pointX[0:3],pointY[0:3],
    // Original measured colour-candidate bbox, native inclusive pixel centres.
    // This is independent of the approximate rectification quad and is held
    // atomically with that quad on start; no scene positions/IDs are involved.
    input logic [8:0] ownerXMin,ownerXMax,
    input logic [7:0] ownerYMin,ownerYMax,
    output wire busy,
    output logic done,
    output logic [16:0] readAddress,
    input logic readWhite,
    // Both planes have the same synchronous read latency. readWhite remains
    // the strict plane for all historical callers; strong must be a subset of
    // readWeakWhite. All mode/seed inputs are captured on idle start.
    input logic weakSupportMode,readWeakWhite,
    input logic [8:0] seedXMin,seedXMax,
    input logic [7:0] seedYMin,seedYMax,
    input logic [16:0] seedStrongCount,
    output logic [16:0] anchorCount,
    output logic [8:0] anchorWidth,
    output logic [7:0] anchorHeight,
    output logic ambiguous,overflow,
    output logic [3:0] allocationPeak,
    output logic [15:0] componentCount,
    output logic [1:0] thinSeedCount,
    output logic [8:0] thinSeedXMin,thinSeedXMax,
    output logic [7:0] thinSeedYMin,thinSeedYMax,
    output logic [16:0] thinSeedStrongCount,
    output logic thinSeedHazard,supportAccepted
);
    typedef enum logic [3:0] {
        IDLE,PREP_VERTEX,PREP_EXTREMA,DIV_INIT,DIV_WAIT,ROI_BIND,
        READ_WAIT,SAMPLE,CANON_READ,CANON_SAMPLE,RETIRE,FINISH
    } state_t;
    typedef struct packed {
        logic [8:0] xMin,xMax;
        logic [7:0] yMin,yMax;
        logic [16:0] area;
        logic touchesBorder;
        logic containsSeed,foreignStrong;
    } component_t;
    state_t state;
    logic [8:0] roiXMin,roiXMax,localX,canonIndex;
    logic [7:0] roiYMin,roiYMax,localY;
    logic [9:0] roiWidth;
    logic [8:0] roiHeight;
    logic [10:0] spanHalfX,spanHalfY;
    // Capture the entire quad on start. Preparation never rereads caller ports.
    logic signed [10:0] heldPointX[0:3],heldPointY[0:3];
    logic [8:0] heldOwnerXMin,heldOwnerXMax;
    logic [7:0] heldOwnerYMin,heldOwnerYMax;
    logic signed [16:0] vertexX[0:3],vertexY[0:3];
    logic signed [16:0] minNumeratorX,maxNumeratorX,minNumeratorY,maxNumeratorY;
    logic signed [10:0] minPointX,maxPointX,minPointY,maxPointY;
    logic [16:0] divisionInput[0:3],divisionQuotient[0:3];
    logic divisionDone;
    logic [3:0] lineLabels[0:319];
    logic [3:0] lineReadData,lineWriteData;
    logic [8:0] lineAddress;
    logic lineReadEnable,lineWriteEnable;
    logic [3:0] parents[0:CAP-1],leftLabel;
    component_t components[0:CAP-1],updatedComponent,retiringComponent;
    logic [CAP-1:0] freeSlots,liveRoots;
    logic [3:0] leftRoot,upRoot,chosenLabel,mergedLabel,canonicalLabel,scanIndex,usedPlusOne;
    logic allocatePixel,capacityHit,pixelBorder,eligible;
    logic [1:0] eligibleCount;
    logic [16:0] firstEligibleCount;
    logic [8:0] firstEligibleWidth,retiringWidth;
    logic [7:0] firstEligibleHeight,retiringHeight;
    logic [24:0] componentAreaTimes200;
    logic [21:0] spanArea;
    logic [9:0] componentCentreX2;
    logic [8:0] componentCentreY2;
    logic componentOwned;
    logic heldWeakSupportMode,selectedWhite,componentBaseEligible,thinEligible;
    logic [8:0] heldSeedXMin,heldSeedXMax,firstThinXMin,firstThinXMax;
    logic [7:0] heldSeedYMin,heldSeedYMax,firstThinYMin,firstThinYMax;
    logic [16:0] heldSeedStrongCount,seenSeedCount,firstThinStrongCount;
    logic [1:0] thinCandidateCount;
    logic [9:0] globalPixelX,seedWidth,seedCentreX2;
    logic [8:0] globalPixelY,seedHeight,seedCentreY2;
    logic inSeedBox,seedDescriptorGood,planeMismatch;
    logic checkingSeed,checkTouchesBorder;
    logic [8:0] checkWidth;
    logic [7:0] checkHeight;
    logic [16:0] checkArea;

    nativeAnchorDivide40 roiDivider(.clk(clk),.reset(reset),.start(state==DIV_INIT),
        .numerator(divisionInput),.quotient(divisionQuotient),.done(divisionDone));

    function automatic logic [3:0] rootOf(input logic [3:0] label);
        if(label!=0 && int'(label)<=CAP)return parents[int'(label)-1];
        return 4'd0;
    endfunction
    function automatic logic signed [16:0] minimum17(input logic signed [16:0] a,b);
        return a<b?a:b;
    endfunction
    function automatic logic signed [16:0] maximum17(input logic signed [16:0] a,b);
        return a>b?a:b;
    endfunction
    function automatic logic signed [10:0] minimum11(input logic signed [10:0] a,b);
        return a<b?a:b;
    endfunction
    function automatic logic signed [10:0] maximum11(input logic signed [10:0] a,b);
        return a>b?a:b;
    endfunction
    // The exact quotient comes from the sequential divider. Clipping occupies
    // its own register stage, with no multiply/min/max/divide cone before it.
    function automatic logic [8:0] lowerBoundaryFromQuotient(input logic [16:0] quotient,input int limit);
        begin
            if(quotient==0)return 9'd0;
            if(quotient-17'd1>17'(limit))return 9'(limit);
            return 9'(quotient-17'd1);
        end
    endfunction
    function automatic logic [8:0] upperBoundaryFromQuotient(input logic [16:0] quotient,input logic negative,input int limit);
        logic [16:0] expanded;
        begin
            if(negative)return 9'd0;
            expanded=quotient+17'd1;
            if(expanded>17'(limit))return 9'(limit);
            return 9'(expanded);
        end
    endfunction

    always_comb begin
        // Lower bounds use floor(max(N,0)/40)-1; upper bounds use
        // floor((N+39)/40)+1 for nonnegative N, retaining the exact original
        // negative-input clipping. Positive signed-17 N plus 39 fits 17 bits.
        divisionInput[0]=minNumeratorX>0?$unsigned(minNumeratorX):17'd0;
        divisionInput[1]=maxNumeratorX<0?17'd0:$unsigned(maxNumeratorX)+17'd39;
        divisionInput[2]=minNumeratorY>0?$unsigned(minNumeratorY):17'd0;
        divisionInput[3]=maxNumeratorY<0?17'd0:$unsigned(maxNumeratorY)+17'd39;
        roiWidth={1'b0,roiXMax}-{1'b0,roiXMin}+10'd1;
        roiHeight={1'b0,roiYMax}-{1'b0,roiYMin}+9'd1;
        readAddress=17'(roiYMin+localY)*17'd320+17'(roiXMin+localX);
        selectedWhite=heldWeakSupportMode?readWeakWhite:readWhite;
        globalPixelX={1'b0,roiXMin}+{1'b0,localX};
        globalPixelY={1'b0,roiYMin}+{1'b0,localY};
        inSeedBox=globalPixelX>={1'b0,heldSeedXMin}&&globalPixelX<={1'b0,heldSeedXMax}&&
            globalPixelY>={1'b0,heldSeedYMin}&&globalPixelY<={1'b0,heldSeedYMax};
        lineAddress=(state==CANON_READ||state==CANON_SAMPLE)?canonIndex:localX;
        lineReadEnable=!reset&&(state==READ_WAIT||state==CANON_READ);
        lineWriteEnable=!reset&&(state==SAMPLE||state==CANON_SAMPLE);
        canonicalLabel=rootOf(lineReadData);
        pixelBorder=localX==0||localY==0||{1'b0,localX}==roiWidth-10'd1||{1'b0,localY}==roiHeight-9'd1;
        leftRoot=localX==0?4'd0:rootOf(leftLabel);
        upRoot=localY==0?4'd0:rootOf(lineReadData);
        chosenLabel=0;mergedLabel=0;updatedComponent='0;allocatePixel=0;capacityHit=0;
        usedPlusOne=4'd1;
        for(int i=0;i<CAP;i++)if(!freeSlots[i])usedPlusOne=usedPlusOne+4'd1;
        if(selectedWhite)begin
            if(leftRoot==0&&upRoot==0)begin
                for(int i=0;i<CAP;i++)if(chosenLabel==0&&freeSlots[i])chosenLabel=4'(i+1);
                if(chosenLabel==0)capacityHit=1;
                else begin
                    allocatePixel=1;updatedComponent.area=17'd1;
                    updatedComponent.xMin=localX;updatedComponent.xMax=localX;
                    updatedComponent.yMin=localY;updatedComponent.yMax=localY;
                    updatedComponent.touchesBorder=pixelBorder;
                end
            end else begin
                chosenLabel=leftRoot==0?upRoot:(upRoot==0?leftRoot:(leftRoot<upRoot?leftRoot:upRoot));
                updatedComponent=components[int'(chosenLabel)-1];
                if(leftRoot!=0&&upRoot!=0&&leftRoot!=upRoot)begin
                    mergedLabel=leftRoot<upRoot?upRoot:leftRoot;
                    updatedComponent.area=updatedComponent.area+components[int'(mergedLabel)-1].area;
                    if(components[int'(mergedLabel)-1].xMin<updatedComponent.xMin)updatedComponent.xMin=components[int'(mergedLabel)-1].xMin;
                    if(components[int'(mergedLabel)-1].xMax>updatedComponent.xMax)updatedComponent.xMax=components[int'(mergedLabel)-1].xMax;
                    if(components[int'(mergedLabel)-1].yMin<updatedComponent.yMin)updatedComponent.yMin=components[int'(mergedLabel)-1].yMin;
                    if(components[int'(mergedLabel)-1].yMax>updatedComponent.yMax)updatedComponent.yMax=components[int'(mergedLabel)-1].yMax;
                    updatedComponent.touchesBorder=updatedComponent.touchesBorder||components[int'(mergedLabel)-1].touchesBorder;
                    updatedComponent.containsSeed=updatedComponent.containsSeed||components[int'(mergedLabel)-1].containsSeed;
                    updatedComponent.foreignStrong=updatedComponent.foreignStrong||components[int'(mergedLabel)-1].foreignStrong;
                end
                updatedComponent.area=updatedComponent.area+17'd1;
                if(localX<updatedComponent.xMin)updatedComponent.xMin=localX;
                if(localX>updatedComponent.xMax)updatedComponent.xMax=localX;
                if(localY<updatedComponent.yMin)updatedComponent.yMin=localY;
                if(localY>updatedComponent.yMax)updatedComponent.yMax=localY;
                updatedComponent.touchesBorder=updatedComponent.touchesBorder||pixelBorder;
            end
            // A four-connected single-row/column seed occupies every pixel of
            // its bbox. Two flags therefore prove seed membership/exclusion;
            // no per-component second17-bit area accumulator is required.
            updatedComponent.containsSeed=updatedComponent.containsSeed||(heldWeakSupportMode&&readWhite&&inSeedBox);
            updatedComponent.foreignStrong=updatedComponent.foreignStrong||(heldWeakSupportMode&&readWhite&&!inSeedBox);
        end
        lineWriteData=state==CANON_SAMPLE?canonicalLabel:(selectedWhite?chosenLabel:4'd0);
        retiringComponent='0;
        if(int'(scanIndex)<CAP)retiringComponent=components[scanIndex];
        retiringWidth=retiringComponent.xMax-retiringComponent.xMin+9'd1;
        retiringHeight=retiringComponent.yMax-retiringComponent.yMin+8'd1;
        seedWidth={1'b0,heldSeedXMax}-{1'b0,heldSeedXMin}+10'd1;
        seedHeight={1'b0,heldSeedYMax}-{1'b0,heldSeedYMin}+9'd1;
        seedCentreX2={1'b0,heldSeedXMin}+{1'b0,heldSeedXMax};
        seedCentreY2={1'b0,heldSeedYMin}+{1'b0,heldSeedYMax};
        // FINISH reuses the component eligibility arithmetic to validate the
        // seed descriptor. There is no second parallel set of multipliers.
        // Range/order checks below precede acceptance of the narrowed widths.
        checkingSeed=state==FINISH&&heldWeakSupportMode;
        checkWidth=checkingSeed?9'(seedWidth):retiringWidth;
        checkHeight=checkingSeed?8'(seedHeight):retiringHeight;
        checkArea=checkingSeed?heldSeedStrongCount:retiringComponent.area;
        checkTouchesBorder=checkingSeed?(heldSeedXMin<=roiXMin||heldSeedXMax>=roiXMax||
            heldSeedYMin<=roiYMin||heldSeedYMax>=roiYMax):retiringComponent.touchesBorder;
        componentAreaTimes200=25'(checkArea)*25'd200;
        spanArea=spanHalfX*spanHalfY;
        // Compare doubled global centres before rounding. Extending each term
        // before adding preserves x=319 (638 doubled) and y=239 (478 doubled).
        // Only the small retiring descriptor is inspected, adding no DSP or
        // pixel RAM access and preserving the existing row retirement schedule.
        componentCentreX2=checkingSeed?seedCentreX2:({roiXMin,1'b0}+{1'b0,retiringComponent.xMin}+{1'b0,retiringComponent.xMax});
        componentCentreY2=checkingSeed?seedCentreY2:({roiYMin,1'b0}+{1'b0,retiringComponent.yMin}+{1'b0,retiringComponent.yMax});
        componentOwned=!ENFORCE_OWNER_BOUNDS||(
            componentCentreX2>={heldOwnerXMin,1'b0}&&componentCentreX2<={heldOwnerXMax,1'b0}&&
            componentCentreY2>={heldOwnerYMin,1'b0}&&componentCentreY2<={heldOwnerYMax,1'b0});
        componentBaseEligible=componentOwned&&!checkTouchesBorder&&checkArea>=3&&
            20'(checkWidth)*20'd100<=20'(spanHalfX)*20'd11&&
            20'(checkHeight)*20'd100<=20'(spanHalfY)*20'd11&&
            componentAreaTimes200<=25'(spanArea);
        eligible=componentBaseEligible&&retiringWidth>=2&&retiringHeight>=2&&
            (!heldWeakSupportMode||(retiringComponent.containsSeed&&!retiringComponent.foreignStrong));
        thinEligible=componentBaseEligible&&((retiringWidth==1)^(retiringHeight==1));
        // Revalidate the caller's descriptor. Counting all strong seed pixels
        // during this scan additionally rejects missing/split or stale seeds.
        seedDescriptorGood=heldSeedXMin<=heldSeedXMax&&heldSeedYMin<=heldSeedYMax&&
            heldSeedXMax<320&&heldSeedYMax<240&&heldSeedStrongCount>=3&&
            ((seedWidth==1)^(seedHeight==1))&&
            heldSeedStrongCount==(seedWidth==1?17'(seedHeight):17'(seedWidth))&&
            checkingSeed&&componentBaseEligible;
    end
    assign busy=state!=IDLE;
    // Synchronous old-data read/write. There is one access address per cycle;
    // READ_WAIT/CANON_READ precede their corresponding consume/write states.
    always_ff @(posedge clk)begin
        if(lineReadEnable)lineReadData<=lineLabels[lineAddress];
        if(lineWriteEnable)lineLabels[lineAddress]<=lineWriteData;
    end
    always_ff @(posedge clk)begin
        if(reset)begin
            state<=IDLE;done<=0;anchorCount<=0;anchorWidth<=0;anchorHeight<=0;
            ambiguous<=0;overflow<=0;allocationPeak<=0;componentCount<=0;
            heldWeakSupportMode<=0;heldSeedXMin<=0;heldSeedXMax<=0;heldSeedYMin<=0;heldSeedYMax<=0;
            heldSeedStrongCount<=0;seenSeedCount<=0;planeMismatch<=0;
            thinCandidateCount<=0;firstThinXMin<=0;firstThinXMax<=0;firstThinYMin<=0;firstThinYMax<=0;firstThinStrongCount<=0;
            thinSeedCount<=0;thinSeedXMin<=0;thinSeedXMax<=0;thinSeedYMin<=0;thinSeedYMax<=0;thinSeedStrongCount<=0;
            thinSeedHazard<=0;supportAccepted<=0;
            roiXMin<=0;roiXMax<=0;roiYMin<=0;roiYMax<=0;localX<=0;localY<=0;canonIndex<=0;
            spanHalfX<=0;spanHalfY<=0;leftLabel<=0;scanIndex<=0;freeSlots<='1;liveRoots<='0;
            eligibleCount<=0;firstEligibleCount<=0;firstEligibleWidth<=0;firstEligibleHeight<=0;
            minPointX<=0;maxPointX<=0;minPointY<=0;maxPointY<=0;
            heldOwnerXMin<=0;heldOwnerXMax<=0;heldOwnerYMin<=0;heldOwnerYMax<=0;
            minNumeratorX<=0;maxNumeratorX<=0;minNumeratorY<=0;maxNumeratorY<=0;
            for(int i=0;i<4;i++)begin heldPointX[i]<=0;heldPointY[i]<=0;vertexX[i]<=0;vertexY[i]<=0;end
            for(int i=0;i<CAP;i++)begin parents[i]<=4'(i+1);components[i]<='0;end
        end else begin
            done<=0;
            case(state)
                IDLE:if(start)begin
                    for(int i=0;i<4;i++)begin heldPointX[i]<=pointX[i];heldPointY[i]<=pointY[i];end
                    heldOwnerXMin<=ownerXMin;heldOwnerXMax<=ownerXMax;
                    heldOwnerYMin<=ownerYMin;heldOwnerYMax<=ownerYMax;
                    heldWeakSupportMode<=weakSupportMode;heldSeedXMin<=seedXMin;heldSeedXMax<=seedXMax;
                    heldSeedYMin<=seedYMin;heldSeedYMax<=seedYMax;heldSeedStrongCount<=seedStrongCount;
                    seenSeedCount<=0;planeMismatch<=0;thinCandidateCount<=0;
                    firstThinXMin<=0;firstThinXMax<=0;firstThinYMin<=0;firstThinYMax<=0;firstThinStrongCount<=0;
                    thinSeedCount<=0;thinSeedXMin<=0;thinSeedXMax<=0;thinSeedYMin<=0;thinSeedYMax<=0;thinSeedStrongCount<=0;
                    thinSeedHazard<=0;supportAccepted<=0;
                    localX<=0;localY<=0;leftLabel<=0;freeSlots<='1;liveRoots<='0;
                    eligibleCount<=0;firstEligibleCount<=0;firstEligibleWidth<=0;firstEligibleHeight<=0;
                    anchorCount<=0;anchorWidth<=0;anchorHeight<=0;ambiguous<=0;overflow<=0;allocationPeak<=0;componentCount<=0;
                    for(int i=0;i<CAP;i++)begin parents[i]<=4'(i+1);components[i]<='0;end
                    state<=PREP_VERTEX;
                end
                PREP_VERTEX:begin
                    // N=20*q0+S*(q1-q0)+T*(q3-q0), S=-3/5,T=-1/4.
                    // q uses half-pixel units. Each signed numerator fits 17
                    // bits for native 320x240 geometry. These registers end
                    // the constant arithmetic path before extrema selection.
                    vertexX[0]<=17'sd24*heldPointX[0]-17'sd3*heldPointX[1]-heldPointX[3];
                    vertexX[1]<=17'sd19*heldPointX[0]-17'sd3*heldPointX[1]+17'sd4*heldPointX[3];
                    vertexX[2]<=17'sd16*heldPointX[0]+17'sd5*heldPointX[1]-heldPointX[3];
                    vertexX[3]<=17'sd11*heldPointX[0]+17'sd5*heldPointX[1]+17'sd4*heldPointX[3];
                    vertexY[0]<=17'sd24*heldPointY[0]-17'sd3*heldPointY[1]-heldPointY[3];
                    vertexY[1]<=17'sd19*heldPointY[0]-17'sd3*heldPointY[1]+17'sd4*heldPointY[3];
                    vertexY[2]<=17'sd16*heldPointY[0]+17'sd5*heldPointY[1]-heldPointY[3];
                    vertexY[3]<=17'sd11*heldPointY[0]+17'sd5*heldPointY[1]+17'sd4*heldPointY[3];
                    minPointX<=minimum11(minimum11(heldPointX[0],heldPointX[1]),minimum11(heldPointX[2],heldPointX[3]));
                    maxPointX<=maximum11(maximum11(heldPointX[0],heldPointX[1]),maximum11(heldPointX[2],heldPointX[3]));
                    minPointY<=minimum11(minimum11(heldPointY[0],heldPointY[1]),minimum11(heldPointY[2],heldPointY[3]));
                    maxPointY<=maximum11(maximum11(heldPointY[0],heldPointY[1]),maximum11(heldPointY[2],heldPointY[3]));
                    state<=PREP_EXTREMA;
                end
                PREP_EXTREMA:begin
                    minNumeratorX<=minimum17(minimum17(vertexX[0],vertexX[1]),minimum17(vertexX[2],vertexX[3]));
                    maxNumeratorX<=maximum17(maximum17(vertexX[0],vertexX[1]),maximum17(vertexX[2],vertexX[3]));
                    minNumeratorY<=minimum17(minimum17(vertexY[0],vertexY[1]),minimum17(vertexY[2],vertexY[3]));
                    maxNumeratorY<=maximum17(maximum17(vertexY[0],vertexY[1]),maximum17(vertexY[2],vertexY[3]));
                    spanHalfX<=$unsigned(maxPointX-minPointX);spanHalfY<=$unsigned(maxPointY-minPointY);
                    state<=DIV_INIT;
                end
                DIV_INIT:state<=DIV_WAIT;
                DIV_WAIT:if(divisionDone)state<=ROI_BIND;
                ROI_BIND:begin
                    roiXMin<=lowerBoundaryFromQuotient(divisionQuotient[0],319);
                    roiXMax<=upperBoundaryFromQuotient(divisionQuotient[1],maxNumeratorX[16],319);
                    roiYMin<=8'(lowerBoundaryFromQuotient(divisionQuotient[2],239));
                    roiYMax<=8'(upperBoundaryFromQuotient(divisionQuotient[3],maxNumeratorY[16],239));
                    state<=READ_WAIT;
                end
                READ_WAIT:state<=SAMPLE;
                SAMPLE:begin
                    leftLabel<=selectedWhite?chosenLabel:4'd0;
                    if(heldWeakSupportMode)begin
                        if(readWhite&&!readWeakWhite)planeMismatch<=1;
                        if(readWhite&&inSeedBox)seenSeedCount<=seenSeedCount+17'd1;
                    end
                    if(selectedWhite)begin
                        if(capacityHit)overflow<=1;
                        if(chosenLabel!=0)components[int'(chosenLabel)-1]<=updatedComponent;
                        if(allocatePixel)begin
                            freeSlots[int'(chosenLabel)-1]<=0;parents[int'(chosenLabel)-1]<=chosenLabel;
                            if(usedPlusOne>allocationPeak)allocationPeak<=usedPlusOne;
                        end
                        if(mergedLabel!=0)begin
                            for(int i=0;i<CAP;i++)if(parents[i]==mergedLabel)parents[i]<=chosenLabel;
                            components[int'(mergedLabel)-1]<='0;
                        end
                    end
                    if({1'b0,localX}==roiWidth-10'd1)begin
                        localX<=0;canonIndex<=0;liveRoots<='0;state<=CANON_READ;
                    end else begin localX<=localX+9'd1;state<=READ_WAIT;end
                end
                CANON_READ:state<=CANON_SAMPLE;
                CANON_SAMPLE:begin
                    if(canonicalLabel!=0)liveRoots[int'(canonicalLabel)-1]<=1;
                    if({1'b0,canonIndex}==roiWidth-10'd1)begin scanIndex<=0;state<=RETIRE;end
                    else begin canonIndex<=canonIndex+9'd1;state<=CANON_READ;end
                end
                RETIRE:begin
                    if(!freeSlots[scanIndex]&&(parents[scanIndex]!=scanIndex+4'd1||
                        {1'b0,localY}==roiHeight-9'd1||!liveRoots[scanIndex]))begin
                        freeSlots[scanIndex]<=1;parents[scanIndex]<=scanIndex+4'd1;components[scanIndex]<='0;
                        if(parents[scanIndex]==scanIndex+4'd1&&retiringComponent.area!=0)begin
                            if(componentCount!=16'hffff)componentCount<=componentCount+16'd1;
                            if(eligible)begin
                                if(eligibleCount<2)eligibleCount<=eligibleCount+2'd1;
                                if(eligibleCount==0)begin
                                    firstEligibleCount<=retiringComponent.area;firstEligibleWidth<=retiringWidth;firstEligibleHeight<=retiringHeight;
                                end
                            end
                            if(!heldWeakSupportMode&&thinEligible)begin
                                if(thinCandidateCount<2)thinCandidateCount<=thinCandidateCount+2'd1;
                                if(thinCandidateCount==0)begin
                                    firstThinXMin<=roiXMin+retiringComponent.xMin;firstThinXMax<=roiXMin+retiringComponent.xMax;
                                    firstThinYMin<=roiYMin+retiringComponent.yMin;firstThinYMax<=roiYMin+retiringComponent.yMax;
                                    firstThinStrongCount<=retiringComponent.area;
                                end
                            end
                        end
                    end
                    if(scanIndex==4'(CAP-1))begin
                        if({1'b0,localY}==roiHeight-9'd1)state<=FINISH;
                        else begin localY<=localY+8'd1;leftLabel<=0;state<=READ_WAIT;end
                    end else scanIndex<=scanIndex+4'd1;
                end
                FINISH:begin
                    if(!heldWeakSupportMode)begin
                        thinSeedCount<=thinCandidateCount;thinSeedHazard<=overflow||eligibleCount==2;
                        if(!overflow&&eligibleCount!=2&&thinCandidateCount==1)begin
                            thinSeedXMin<=firstThinXMin;thinSeedXMax<=firstThinXMax;
                            thinSeedYMin<=firstThinYMin;thinSeedYMax<=firstThinYMax;thinSeedStrongCount<=firstThinStrongCount;
                        end
                        if(!overflow&&eligibleCount==1)begin
                            anchorCount<=firstEligibleCount;anchorWidth<=firstEligibleWidth;anchorHeight<=firstEligibleHeight;
                        end
                    end else if(!overflow&&eligibleCount==1&&seedDescriptorGood&&!planeMismatch&&seenSeedCount==heldSeedStrongCount)begin
                        anchorCount<=heldSeedStrongCount;anchorWidth<=firstEligibleWidth;anchorHeight<=firstEligibleHeight;
                        supportAccepted<=1;
                    end
                    ambiguous<=eligibleCount==2;done<=1;state<=IDLE;
                end
                default:state<=IDLE;
            endcase
        end
    end
endmodule

// Exact unsigned division by 40 for all 17-bit inputs, four parallel lanes.
// Each transaction takes 17 bit steps after start. A lane stores remainder<40;
// appending one dividend bit therefore creates at most 79, so its entire
// compare/subtract path is seven bits. Inputs are captured only on idle start.
module nativeAnchorDivide40(
    input logic clk,reset,start,
    input logic [16:0] numerator[0:3],
    output logic [16:0] quotient[0:3],
    output logic done
);
    logic working;
    logic [4:0] bitIndex;
    logic [16:0] dividend[0:3];
    logic [5:0] remainder[0:3];
    logic [6:0] extendedRemainder[0:3];
    always_comb begin
        for(int lane=0;lane<4;lane++)extendedRemainder[lane]={remainder[lane],dividend[lane][16]};
    end
    always_ff @(posedge clk)begin
        if(reset)begin
            working<=0;done<=0;bitIndex<=0;
            for(int lane=0;lane<4;lane++)begin dividend[lane]<=0;remainder[lane]<=0;quotient[lane]<=0;end
        end else begin
            done<=0;
            if(start&&!working)begin
                working<=1;bitIndex<=5'd16;
                for(int lane=0;lane<4;lane++)begin dividend[lane]<=numerator[lane];remainder[lane]<=0;quotient[lane]<=0;end
            end else if(working)begin
                for(int lane=0;lane<4;lane++)begin
                    dividend[lane]<={dividend[lane][15:0],1'b0};
                    if(extendedRemainder[lane]>=7'd40)begin
                        remainder[lane]<=6'(extendedRemainder[lane]-7'd40);
                        quotient[lane]<={quotient[lane][15:0],1'b1};
                    end else begin
                        remainder[lane]<=extendedRemainder[lane][5:0];
                        quotient[lane]<={quotient[lane][15:0],1'b0};
                    end
                end
                if(bitIndex==0)begin working<=0;done<=1;end
                else bitIndex<=bitIndex-5'd1;
            end
        end
    end
endmodule
