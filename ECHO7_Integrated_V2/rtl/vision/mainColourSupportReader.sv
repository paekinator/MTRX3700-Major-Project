// Reader7 colour geometry: isolate one complete, uniquely largest raw component.
// CLOCK_50 only; readColour is the one-cycle synchronous glyph-RAM foreground
// bit (red OR blue). No digit or scene position enters this selection. Inputs
// are held on idle start. The output supports use native pixel centres and the
// same sixteen directions/tie order as the historical projective reader.
module mainColourSupportReader #(
    parameter int CAP=8
)(
    input logic clk,reset,start,
    input logic [8:0] ownerXMin,ownerXMax,
    input logic [7:0] ownerYMin,ownerYMax,
    output logic [16:0] readAddress,
    input logic readColour,
    output wire busy,
    output logic done,geometryValid,overflow,
    output logic [8:0] supportX[0:15],
    output logic [7:0] supportY[0:15],
    output logic [16:0] foregroundCount,
    output logic [3:0] allocationPeak,
    output logic [16:0] componentCount
);
    typedef enum logic [4:0] {
        IDLE,BIND,READ_WAIT,SAMPLE,SUPPORT_INIT,SUPPORT_READ,SUPPORT_APPLY,
        SUPPORT_MERGE_READ,SUPPORT_MERGE_APPLY,ADVANCE_PIXEL,
        CANON_READ,CANON_SAMPLE,RETIRE,WINNER_READ,WINNER_SAMPLE,
        ADVANCE_RETIRE,FINISH
    } state_t;
    typedef struct packed {
        logic signed [10:0] score;
        logic [8:0] x;
        logic [7:0] y;
    } support_t;
    state_t state;
    logic [8:0] heldXMin,heldXMax,localX,canonIndex;
    logic [7:0] heldYMin,heldYMax,localY;
    logic [9:0] roiWidth;
    logic [8:0] roiHeight,nativeX;
    logic [7:0] nativeY;
    logic [3:0] parents[0:CAP-1],leftLabel;
    logic [16:0] areas[0:CAP-1],updatedArea,rawForegroundCount,winnerArea;
    logic [CAP-1:0] freeSlots,liveRoots;
    logic [3:0] leftRoot,upRoot,chosenLabel,mergedLabel,canonicalLabel,usedPlusOne;
    logic [3:0] currentLabel,currentMergedLabel,direction,scanIndex,winnerReadLabel;
    logic allocatePixel,capacityHit,winnerUnique;

    // One previous-row label RAM; no reset of RAM contents. Row0 ignores its
    // read values and overwrites every used column before any later row reads.
    logic [3:0] lineLabels[0:319],lineReadData,lineWriteData;
    logic [8:0] lineAddress;
    logic lineReadEnable,lineWriteEnable;

    // CAP8 requires128x28 bits. One addressed read/modify/write path serialises
    // the16 directions, including union merges, rather than creating sixteen
    // parallel mux banks. Allocation overwrites all16 entries before use.
    // Actual M10K inference must be checked in the Quartus map/fitter reports.
    (* ramstyle = "M10K" *) logic [27:0] supportMemory[0:CAP*16-1];
    logic [7:0] supportAddress;
    logic supportReadEnable,supportWriteEnable;
    support_t supportReadData,supportWriteData,baseSupport,pixelSupport,mergedSupport;

    function automatic logic [3:0] rootOf(input logic [3:0] label);
        if(label!=0&&int'(label)<=CAP)return parents[int'(label)-1];
        return 4'd0;
    endfunction
    function automatic logic signed [10:0] directionScore(
        input logic [3:0] index,input logic [8:0] x,input logic [7:0] y);
        logic signed [10:0] sx,sy;
        begin
            sx=$signed({2'b00,x});sy=$signed({3'b000,y});
            case(index)
                0:return sx;        1:return (sx<<<1)+sy;
                2:return sx+sy;     3:return sx+(sy<<<1);
                4:return sy;        5:return -sx+(sy<<<1);
                6:return -sx+sy;    7:return -(sx<<<1)+sy;
                8:return -sx;       9:return -(sx<<<1)-sy;
                10:return -sx-sy;   11:return -sx-(sy<<<1);
                12:return -sy;      13:return sx-(sy<<<1);
                14:return sx-sy;    15:return (sx<<<1)-sy;
                default:return 11'sd0;
            endcase
        end
    endfunction
    function automatic support_t earlierMaximum(input support_t first,second);
        // Raster-first ties are essential when independently accumulated
        // components merge: label number is not a substitute for pixel order.
        if(second.score>first.score || (second.score==first.score &&
            (second.y<first.y || (second.y==first.y&&second.x<first.x))))return second;
        return first;
    endfunction

    always_comb begin
        roiWidth={1'b0,heldXMax}-{1'b0,heldXMin}+10'd1;
        roiHeight={1'b0,heldYMax}-{1'b0,heldYMin}+9'd1;
        nativeX=heldXMin+localX;nativeY=heldYMin+localY;
        readAddress=17'(nativeY)*17'd320+17'(nativeX);
        lineAddress=(state==CANON_READ||state==CANON_SAMPLE)?canonIndex:localX;
        lineReadEnable=!reset&&(state==READ_WAIT||state==CANON_READ);
        lineWriteEnable=!reset&&(state==SAMPLE||state==CANON_SAMPLE);
        canonicalLabel=rootOf(lineReadData);
        leftRoot=localX==0?4'd0:rootOf(leftLabel);
        upRoot=localY==0?4'd0:rootOf(lineReadData);
        chosenLabel=0;mergedLabel=0;updatedArea=0;allocatePixel=0;capacityHit=0;
        usedPlusOne=4'd1;
        for(int slot=0;slot<CAP;slot++)if(!freeSlots[slot])usedPlusOne=usedPlusOne+4'd1;
        if(readColour)begin
            if(leftRoot==0&&upRoot==0)begin
                for(int slot=0;slot<CAP;slot++)if(chosenLabel==0&&freeSlots[slot])chosenLabel=4'(slot+1);
                if(chosenLabel==0)capacityHit=1;
                else begin allocatePixel=1;updatedArea=17'd1;end
            end else begin
                chosenLabel=leftRoot==0?upRoot:(upRoot==0?leftRoot:(leftRoot<upRoot?leftRoot:upRoot));
                updatedArea=areas[int'(chosenLabel)-1]+17'd1;
                if(leftRoot!=0&&upRoot!=0&&leftRoot!=upRoot)begin
                    mergedLabel=leftRoot<upRoot?upRoot:leftRoot;
                    updatedArea=updatedArea+areas[int'(mergedLabel)-1];
                end
            end
        end
        lineWriteData=state==CANON_SAMPLE?canonicalLabel:(readColour?chosenLabel:4'd0);
        pixelSupport.score=directionScore(direction,nativeX,nativeY);
        pixelSupport.x=nativeX;pixelSupport.y=nativeY;
        mergedSupport=earlierMaximum(baseSupport,supportReadData);
        supportAddress=8'((int'(currentLabel)-1)*16+int'(direction));
        supportReadEnable=0;supportWriteEnable=0;supportWriteData=pixelSupport;
        case(state)
            SUPPORT_INIT:begin supportWriteEnable=1;end
            SUPPORT_READ:begin supportReadEnable=1;end
            SUPPORT_APPLY:begin
                supportWriteEnable=1;supportWriteData=earlierMaximum(supportReadData,pixelSupport);
            end
            SUPPORT_MERGE_READ:begin
                supportAddress=8'((int'(currentMergedLabel)-1)*16+int'(direction));supportReadEnable=1;
            end
            SUPPORT_MERGE_APPLY:begin
                supportWriteEnable=1;supportWriteData=earlierMaximum(mergedSupport,pixelSupport);
            end
            WINNER_READ,WINNER_SAMPLE:begin
                supportAddress=8'((int'(winnerReadLabel)-1)*16+int'(direction));
                supportReadEnable=state==WINNER_READ;
            end
            default:begin end
        endcase
        supportReadEnable=supportReadEnable&&!reset;
        supportWriteEnable=supportWriteEnable&&!reset;
    end
    assign busy=state!=IDLE;
    always_ff @(posedge clk)begin
        if(lineReadEnable)lineReadData<=lineLabels[lineAddress];
        if(lineWriteEnable)lineLabels[lineAddress]<=lineWriteData;
        if(supportReadEnable)supportReadData<=supportMemory[supportAddress];
        if(supportWriteEnable)supportMemory[supportAddress]<=supportWriteData;
    end
    always_ff @(posedge clk)begin
        if(reset)begin
            state<=IDLE;done<=0;geometryValid<=0;overflow<=0;foregroundCount<=0;
            allocationPeak<=0;componentCount<=0;heldXMin<=0;heldXMax<=0;heldYMin<=0;heldYMax<=0;
            localX<=0;localY<=0;canonIndex<=0;leftLabel<=0;freeSlots<='1;liveRoots<='0;
            rawForegroundCount<=0;winnerArea<=0;winnerUnique<=0;
            currentLabel<=0;currentMergedLabel<=0;direction<=0;scanIndex<=0;winnerReadLabel<=0;baseSupport<='0;
            for(int slot=0;slot<CAP;slot++)begin parents[slot]<=4'(slot+1);areas[slot]<=0;end
            for(int index=0;index<16;index++)begin supportX[index]<=0;supportY[index]<=0;end
        end else begin
            done<=0;
            case(state)
                IDLE:if(start)begin
                    heldXMin<=ownerXMin;heldXMax<=ownerXMax;heldYMin<=ownerYMin;heldYMax<=ownerYMax;
                    localX<=0;localY<=0;leftLabel<=0;freeSlots<='1;liveRoots<='0;
                    rawForegroundCount<=0;winnerArea<=0;winnerUnique<=0;
                    geometryValid<=0;overflow<=0;foregroundCount<=0;allocationPeak<=0;componentCount<=0;
                    for(int slot=0;slot<CAP;slot++)begin parents[slot]<=4'(slot+1);areas[slot]<=0;end
                    for(int index=0;index<16;index++)begin supportX[index]<=0;supportY[index]<=0;end
                    state<=BIND;
                end
                BIND:begin
                    if(heldXMin>heldXMax||heldYMin>heldYMax||heldXMax>319||heldYMax>239)state<=FINISH;
                    else state<=READ_WAIT;
                end
                READ_WAIT:state<=SAMPLE;
                SAMPLE:begin
                    leftLabel<=readColour?chosenLabel:4'd0;
                    if(readColour)begin
                        rawForegroundCount<=rawForegroundCount+17'd1;
                        if(capacityHit)begin
                            overflow<=1;
                            if(usedPlusOne>allocationPeak)allocationPeak<=usedPlusOne;
                            state<=FINISH;
                        end else begin
                            areas[int'(chosenLabel)-1]<=updatedArea;
                            currentLabel<=chosenLabel;currentMergedLabel<=mergedLabel;direction<=0;
                            if(allocatePixel)begin
                                freeSlots[int'(chosenLabel)-1]<=0;parents[int'(chosenLabel)-1]<=chosenLabel;
                                if(usedPlusOne>allocationPeak)allocationPeak<=usedPlusOne;
                                state<=SUPPORT_INIT;
                            end else state<=SUPPORT_READ;
                            if(mergedLabel!=0)begin
                                for(int slot=0;slot<CAP;slot++)if(parents[slot]==mergedLabel)parents[slot]<=chosenLabel;
                                areas[int'(mergedLabel)-1]<=0;
                            end
                        end
                    end else state<=ADVANCE_PIXEL;
                end
                SUPPORT_INIT,SUPPORT_APPLY,SUPPORT_MERGE_APPLY:begin
                    if(direction==15)state<=ADVANCE_PIXEL;
                    else begin direction<=direction+4'd1;state<=state==SUPPORT_INIT?SUPPORT_INIT:SUPPORT_READ;end
                end
                SUPPORT_READ:state<=currentMergedLabel!=0?SUPPORT_MERGE_READ:SUPPORT_APPLY;
                SUPPORT_MERGE_READ:begin baseSupport<=supportReadData;state<=SUPPORT_MERGE_APPLY;end
                ADVANCE_PIXEL:begin
                    if({1'b0,localX}==roiWidth-10'd1)begin localX<=0;canonIndex<=0;liveRoots<='0;state<=CANON_READ;end
                    else begin localX<=localX+9'd1;state<=READ_WAIT;end
                end
                CANON_READ:state<=CANON_SAMPLE;
                CANON_SAMPLE:begin
                    if(canonicalLabel!=0)liveRoots[int'(canonicalLabel)-1]<=1;
                    if({1'b0,canonIndex}==roiWidth-10'd1)begin scanIndex<=0;state<=RETIRE;end
                    else begin canonIndex<=canonIndex+9'd1;state<=CANON_READ;end
                end
                RETIRE:begin
                    state<=ADVANCE_RETIRE;
                    if(!freeSlots[scanIndex]&&(parents[scanIndex]!=scanIndex+4'd1||
                        {1'b0,localY}==roiHeight-9'd1||!liveRoots[scanIndex]))begin
                        freeSlots[scanIndex]<=1;parents[scanIndex]<=scanIndex+4'd1;areas[scanIndex]<=0;
                        if(parents[scanIndex]==scanIndex+4'd1&&areas[scanIndex]!=0)begin
                            componentCount<=componentCount+17'd1;
                            if(areas[scanIndex]>winnerArea)begin
                                winnerArea<=areas[scanIndex];winnerUnique<=1;
                                winnerReadLabel<=scanIndex+4'd1;direction<=0;state<=WINNER_READ;
                            end else if(areas[scanIndex]==winnerArea)winnerUnique<=0;
                        end
                    end
                end
                WINNER_READ:state<=WINNER_SAMPLE;
                WINNER_SAMPLE:begin
                    supportX[direction]<=supportReadData.x;supportY[direction]<=supportReadData.y;
                    if(direction==15)state<=ADVANCE_RETIRE;
                    else begin direction<=direction+4'd1;state<=WINNER_READ;end
                end
                ADVANCE_RETIRE:begin
                    if(scanIndex==4'(CAP-1))begin
                        if({1'b0,localY}==roiHeight-9'd1)state<=FINISH;
                        else begin localY<=localY+8'd1;leftLabel<=0;state<=READ_WAIT;end
                    end else begin scanIndex<=scanIndex+4'd1;state<=RETIRE;end
                end
                FINISH:begin
                    // Cardinal supports provide the complete component bbox.
                    // Requiring all four sides preserves the caller's public
                    // bbox: a smaller card inside a mixed descriptor is rejected.
                    if(!overflow&&winnerUnique&&winnerArea!=0&&
                        supportX[0]==heldXMax&&supportY[4]==heldYMax&&
                        supportX[8]==heldXMin&&supportY[12]==heldYMin)begin
                        geometryValid<=1;foregroundCount<=rawForegroundCount;
                    end else begin
                        geometryValid<=0;foregroundCount<=0;
                        for(int index=0;index<16;index++)begin supportX[index]<=0;supportY[index]<=0;end
                    end
                    done<=1;state<=IDLE;
                end
                default:state<=IDLE;
            endcase
        end
    end
endmodule
