// Accepted labels for the native320x240 -> upright640x480 display mapping.
// Compact label geometry is frozen at the accepted SOP. Per-pixel selection
// retains the original last-slot-wins priority, then uses one shared font.
module memberBVgaLabels #(
    parameter int MAX_HOLD_FRAMES=10
) (
    input logic clk, reset,
    input logic [perception_pkg::DEBUG_WORD_COUNT*32-1:0] debugWords,
    input logic [29:0] inData,
    input logic inSop,inEop,inValid,
    output logic inReady,
    output logic [29:0] outData,
    output logic outSop,outEop,outValid,
    input logic outReady
);
    import perception_pkg::*;
    // x=143..501 and y=3..481 for valid native boxes; nine bits suffice.
    // Original 64 full metadata words are not needed after the SOP boundary.
    typedef struct packed {
        logic valid, isBlue;
        logic [6:0] segments;
        logic [8:0] x,y;
    } label_t;
    label_t labels[0:DEBUG_MARKER_COUNT-1];
    logic [15:0] heldFrameId,heldConfigVersion;
    logic haveFrame,heldFrameGood;
    logic [7:0] unchangedFrames;
    logic [9:0] rasterX,pixelX;
    logic [8:0] rasterY,pixelY;
    logic [29:0] renderedData;
    logic [31:0] captureAge;
    logic sourceFrameGood,sourceReferenceValid;
    logic selectedValid,selectedBlue,typeInk,digitInk;
    logic [6:0] selectedSegments;
    logic [3:0] glyphX,glyphY;
    logic [8:0] deltaX,deltaY;

    function automatic logic [6:0] segmentsForDigit(input logic [3:0] digit);
        case(digit)
            1:segmentsForDigit=7'b0000110;
            2:segmentsForDigit=7'b1011011;
            3:segmentsForDigit=7'b1001111;
            4:segmentsForDigit=7'b1100110;
            5:segmentsForDigit=7'b1101101;
            6:segmentsForDigit=7'b1111101;
            default:segmentsForDigit=0;
        endcase
    endfunction

    function automatic label_t labelFor(input logic [31:0] header,xWord,yWord,
                                         input logic isReference);
        label_t result;
        logic [8:0] nativeLeft,nativeRight,nativeTop,nativeBottom,portraitTop;
        logic [9:0] scaledX,scaledY;
        begin
            nativeLeft=xWord[24:16];nativeRight=xWord[8:0];
            nativeTop={1'b0,yWord[23:16]};nativeBottom={1'b0,yWord[7:0]};
            portraitTop=9'd319-nativeRight;
            scaledX={1'b0,nativeTop}+{nativeTop,1'b0};
            scaledY={1'b0,portraitTop}+{portraitTop,1'b0};
            result='0;
            result.valid=((header[31]&&header[27:24]>=1&&header[27:24]<=6)||isReference)&&
                nativeLeft<=nativeRight&&nativeRight<320&&nativeTop<=nativeBottom&&nativeBottom<240;
            result.isBlue=header[30]||isReference;
            result.segments=isReference?7'b0011110:segmentsForDigit(header[27:24]);
            result.x=9'd143+scaledX[9:1];result.y=9'd3+scaledY[9:1];
            return result;
        end
    endfunction

    assign inReady=!outValid||outReady;
    always_comb begin
        captureAge=debugWords[2*32+:32]-debugWords[4*32+:32];
        sourceFrameGood=debugWords[31:0]==32'h45425031&&
            debugWords[1*32+16+:16]==16'(DEBUG_SCHEMA_VERSION)&&
            debugWords[(DEBUG_TAIL_BASE+3)*32]&&!captureAge[31]&&captureAge<=32'd150000;
        sourceReferenceValid=debugWords[31:0]==32'h45425031&&
            debugWords[1*32+16+:16]==16'(DEBUG_SCHEMA_VERSION)&&
            debugWords[(DEBUG_TAIL_BASE+2)*32+3]&&sourceFrameGood;
        pixelX=inSop?10'd0:rasterX;pixelY=inSop?9'd0:rasterY;
        selectedValid=0;selectedBlue=0;selectedSegments=0;glyphX=0;glyphY=0;
        deltaX=0;deltaY=0;typeInk=0;digitInk=0;renderedData=inData;
        if(heldFrameGood&&haveFrame&&pixelX>=140&&pixelX<500)begin
            for(int index=0;index<DEBUG_MARKER_COUNT;index++)begin
                // The outer x bound and valid-label bounds make every negative
                // nine-bit wrapped delta >=31, so it cannot pass <16/<12.
                deltaX=pixelX[8:0]-labels[index].x;
                deltaY=pixelY-labels[index].y;
                if(labels[index].valid&&deltaX<16&&deltaY<12)begin
                    selectedValid=1;selectedBlue=labels[index].isBlue;
                    selectedSegments=labels[index].segments;
                    glyphX=deltaX[3:0];glyphY=deltaY[3:0];
                end
            end
        end
        if(selectedValid)begin
            // The winning slot supplies only a 4-bit glyph coordinate. Share
            // this font across all16 labels instead of replicating it16 times.
            typeInk=(glyphX==0&&glyphY>=1&&glyphY<=10)||
                ((glyphY==0||glyphY==5)&&glyphX<=4)||
                (glyphX==5&&glyphY>=1&&glyphY<=4);
            if(selectedBlue)typeInk=typeInk||(glyphY==11&&glyphX<=4)||
                (glyphX==5&&glyphY>=6&&glyphY<=10);
            else typeInk=typeInk||(glyphY>=6&&glyphY<=10&&glyphX==glyphY-4'd5);
            digitInk=(selectedSegments[0]&&glyphY==0&&glyphX>=9&&glyphX<=14)||
                (selectedSegments[1]&&glyphX==15&&glyphY>=1&&glyphY<=4)||
                (selectedSegments[2]&&glyphX==15&&glyphY>=6&&glyphY<=10)||
                (selectedSegments[3]&&glyphY==11&&glyphX>=9&&glyphX<=14)||
                (selectedSegments[4]&&glyphX==8&&glyphY>=6&&glyphY<=10)||
                (selectedSegments[5]&&glyphX==8&&glyphY>=1&&glyphY<=4)||
                (selectedSegments[6]&&glyphY==5&&glyphX>=9&&glyphX<=14);
            renderedData=(digitInk||typeInk)?{10'h3ff,10'h3ff,10'h3ff}:
                selectedBlue?{10'd0,10'd128,10'd512}:{10'd512,10'd0,10'd0};
        end
    end

    always_ff @(posedge clk)begin
        if(reset)begin
            outData<=0;outSop<=0;outEop<=0;outValid<=0;
            rasterX<=0;rasterY<=0;heldFrameId<=0;heldConfigVersion<=0;
            haveFrame<=0;heldFrameGood<=0;unchangedFrames<=0;
            for(int index=0;index<DEBUG_MARKER_COUNT;index++)labels[index]<='0;
        end else if(inReady)begin
            outValid<=inValid;
            if(inValid)begin
                outData<=renderedData;outSop<=inSop;outEop<=inEop;
                if(inSop)begin
                    rasterX<=1;rasterY<=0;
                    for(int index=0;index<DEBUG_MARKER_COUNT;index++)
                        labels[index]<=labelFor(debugWords[(24+4*index)*32+:32],
                            debugWords[(25+4*index)*32+:32],debugWords[(26+4*index)*32+:32],
                            sourceReferenceValid&&index==int'(debugWords[(DEBUG_TAIL_BASE+2)*32+4+:4]));
                    heldFrameId<=debugWords[3*32+:16];heldConfigVersion<=debugWords[6*32+:16];haveFrame<=1;
                    if(haveFrame&&heldFrameId==debugWords[3*32+:16]&&heldConfigVersion==debugWords[6*32+:16])begin
                        if(unchangedFrames!=255)unchangedFrames<=unchangedFrames+8'd1;
                        heldFrameGood<=sourceFrameGood&&unchangedFrames<MAX_HOLD_FRAMES-1;
                    end else begin unchangedFrames<=0;heldFrameGood<=sourceFrameGood;end
                end else if(rasterX==639)begin
                    rasterX<=0;rasterY<=rasterY==479?9'd0:rasterY+9'd1;
                end else rasterX<=rasterX+10'd1;
            end
        end
    end
endmodule
