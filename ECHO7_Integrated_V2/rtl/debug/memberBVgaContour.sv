// Display-space raw HSV transitions, independently of candidate/ID acceptance.
// Two elastic stages bind RGB, class, previous-row RAM data and SOP/EOP. All
// state/RAM enables advance only on an accepted input. A 640x2 synchronous RAM
// stores classes, not another RGB frame. Same-address read must return OLD data.
// Left/top transitions are marked on the current pixel; right/bottom transitions
// are one pixel outside the region. At screen boundaries they are marked on the
// last visible foreground pixel. Red/blue contact uses the current class colour.
module memberBVgaContour #(
    parameter int BLUE_HUE_UPPER=250
) (
    input logic clk, reset,
    input logic [7:0] redMinimum,blueMinimum,
    input logic [29:0] inData,
    input logic inSop,inEop,inValid,
    output logic inReady,
    output logic [29:0] outData,
    output logic outSop,outEop,outValid,
    input logic outReady
);
    (* ramstyle="M10K" *) logic [1:0] previousRow [0:639];
    logic [1:0] aboveClass,leftClass,liveClass;
    logic [7:0] heldRedMinimum,heldBlueMinimum;
    logic [9:0] rasterX,sampleX;
    logic [8:0] rasterY,sampleY;
    logic stageValid,stageSop,stageEop,stageFirstRow,stageLastColumn,stageLastRow;
    logic [29:0] stageData,contouredData;
    logic [1:0] stageClass,stageLeft,upperClass,edgeClass;
    logic horizontalEdge,verticalEdge,boundaryEdge;
    wire outputReady=!outValid || outReady;
    wire inputAccept=inValid && inReady && !reset;
    wire [7:0] activeRed=inSop?redMinimum:heldRedMinimum;
    wire [7:0] activeBlue=inSop?blueMinimum:heldBlueMinimum;
    assign inReady=!stageValid || outputReady;
    assign sampleX=inSop?10'd0:rasterX;
    assign sampleY=inSop?9'd0:rasterY;
    hsvColourGate #(.BLUE_HUE_UPPER(BLUE_HUE_UPPER)) gate(.rgb({inData[29:22],inData[19:12],inData[9:2]}),
        .redMinimum(activeRed),.blueMinimum(activeBlue),.colourMask(liveClass));

    // Separate synchronous read/write block preserves RAM inference. No reset
    // loop: the complete first row is rewritten and its old contents ignored.
    always_ff @(posedge clk) begin
        if(inputAccept)begin
            aboveClass<=previousRow[sampleX];
            previousRow[sampleX]<=liveClass;
        end
    end
    always_comb begin
        upperClass=stageFirstRow?2'd0:aboveClass;
        horizontalEdge=stageClass!=stageLeft;
        verticalEdge=stageClass!=upperClass;
        boundaryEdge=(stageLastColumn || stageLastRow) && stageClass!=0;
        edgeClass=0;
        if(horizontalEdge || verticalEdge || boundaryEdge)begin
            if(stageClass!=0)edgeClass=stageClass;
            else if(horizontalEdge && stageLeft!=0)edgeClass=stageLeft;
            else if(verticalEdge)edgeClass=upperClass;
        end
        contouredData=stageData;
        if(edgeClass==1)contouredData={10'h3ff,10'd0,10'd0};
        else if(edgeClass==2)contouredData={10'd0,10'd0,10'h3ff};
    end
    always_ff @(posedge clk)begin
        if(reset)begin
            stageValid<=0;stageSop<=0;stageEop<=0;stageData<=0;
            stageClass<=0;stageLeft<=0;stageFirstRow<=0;stageLastColumn<=0;stageLastRow<=0;
            outValid<=0;outSop<=0;outEop<=0;outData<=0;
            rasterX<=0;rasterY<=0;leftClass<=0;
            heldRedMinimum<=8'd48;heldBlueMinimum<=8'd32;
        end else begin
            if(outputReady)begin
                outValid<=stageValid;
                if(stageValid)begin
                    outData<=contouredData;outSop<=stageSop;outEop<=stageEop;
                end else begin outSop<=0;outEop<=0;end
            end
            if(inReady)begin
                stageValid<=inValid;
                if(inValid)begin
                    stageData<=inData;stageSop<=inSop;stageEop<=inEop;
                    stageClass<=liveClass;stageLeft<=sampleX==0?2'd0:leftClass;
                    stageFirstRow<=sampleY==0;stageLastColumn<=sampleX==639;stageLastRow<=sampleY==479;
                    leftClass<=liveClass;
                    if(inSop)begin heldRedMinimum<=redMinimum;heldBlueMinimum<=blueMinimum;end
                    if(sampleX==639)begin
                        rasterX<=0;rasterY<=sampleY==479?9'd0:sampleY+9'd1;
                    end else begin rasterX<=sampleX+10'd1;rasterY<=sampleY;end
                end
            end
        end
    end
endmodule
