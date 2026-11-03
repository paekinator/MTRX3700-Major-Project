// VGA-domain diagnostic sampling and text. rawAccept taps the unmodified input
// to the contour pipeline; the streaming input here is the labelled image.
// Candidate samples are 4x4 displayed pixels; centre is 8x8 displayed pixels.
// Averages and HSV belong to a completed VGA scan, not an atomic camera frame.
// Published measurements switch together at display SOP and say "VGA HELD".
// This adds only small counters/records, no RGB frame RAM or clock crossing.
module memberBVgaDiagnostics #(
    parameter int BLUE_HUE_UPPER=260,
    parameter int DEFAULT_BLUE_MINIMUM=20
)(
    input logic clk,reset,showCandidates,showCentre,
    input logic [perception_pkg::DEBUG_WORD_COUNT*32-1:0] debugWords,rawDebugWords,
    input logic [29:0] rawData,
    input logic rawSop,rawEop,rawAccept,
    input logic [29:0] inData,
    input logic inSop,inEop,inValid,
    output logic inReady,
    output logic [29:0] outData,
    output logic outSop,outEop,outValid,
    input logic outReady
);
    import perception_pkg::*;
    // Bound display cost independently of the16 shared production candidates: six red
    // rows, eight blue bay rows, centre16, and a dedicated calibration bar17.
    // Slots6/7 are reserved. BJ never consumes a blue bay presentation tag.
    localparam int SLOTS=18, CENTRE_SLOT=16, REFERENCE_SLOT=17;
    // Record: valid79, accepted78, blue77, digit76:73, centreX72:64,
    // centreY63:55, RGB54:31, H30:22, S21:14, V13:6, colour5:4,
    // calibrationReference0. The last flag is a schema7 proven pairing, not ID.
    logic [79:0] displayRecords[0:SLOTS-1];
    // Three ownership banks: converter writes a free bank, publication names a
    // complete bank, and the SOP loader pins its bank until the final read.
    // No reset on RAM data: only publishedReady grants access to written rows.
    (* ramstyle = "M10K" *) logic [79:0] recordRam[0:95];
    logic [1:0] workBank,publishedBank,loadBank,freeBank;
    logic loadActive,readPending;
    logic [4:0] readIssueIndex,readSlot;
    logic [79:0] recordReadData;
    logic displayReferenceMatches;
    // The overlay freezes debugWords at accepted raw SOP. Its next-clock value
    // is stable for this serial scan; another raw SOP cancels and restarts it.
    // No sample ROI begins before x=138; all16 candidates finish by clock18.
    logic metadataScanning;
    logic [4:0] metadataIndex,metadataCount;
    logic [4:0] redSampleCount,blueSampleCount;
    logic [5:0] centreMatches;
    logic metadataReferenceValid;
    // Sampling metadata: valid24, accepted23, blue22, digit21:18, x17:9,y8:0.
    logic [24:0] sampleMeta[0:SLOTS-1],workMeta[0:SLOTS-1];
    logic [SLOTS-1:0] sampleReference,workReference;
    logic [3:0] sampleReferenceIndex,workReferenceIndex,publishedReferenceIndex;
    logic [1:0] sampleOverflow,workOverflow,publishedOverflow;
    logic [23:0] workRgb[0:SLOTS-1];
    logic [13:0] sumRed[0:SLOTS-1],sumGreen[0:SLOTS-1],sumBlue[0:SLOTS-1];
    logic [6:0] sampleCount[0:SLOTS-1];
    logic [9:0] rawX,rawPixelX,rasterX,pixelX;
    logic [8:0] rawY,rawPixelY,rasterY,pixelY;
    logic [7:0] sampleRedMinimum,sampleBlueMinimum,workRedMinimum,workBlueMinimum;
    logic [15:0] sampleScanId,workScanId,publishedScanId,displayScanId;
    logic [15:0] sampleMetadataFrame,workMetadataFrame,publishedMetadataFrame,displayMetadataFrame;
    logic publishedReady,heldShowCandidates,heldShowCentre;
    logic [31:0] rawCaptureAge;
    logic metadataFresh,sampleFrameGood,workFrameGood,publishedFrameGood,displayFrameGood;
    logic sampleMetadataFresh,workMetadataFresh,publishedMetadataFresh,displayMetadataFresh;
    logic [15:0] previousMetadataFrame,previousConfigVersion;
    logic [7:0] repeatedMetadataScans;
    perceptionStatus_t displayStatus;
    logic displayBypass;
    logic [3:0] displaySampleCount;
    typedef enum logic [1:0] {IDLE,START_CONVERSION,WAIT_CONVERSION} conversionState_t;
    conversionState_t conversionState;
    logic [4:0] conversionIndex;
    logic converterStart,converterReady,converterValid;
    logic [8:0] convertedHue;
    logic [7:0] convertedSaturation,convertedValue;
    logic [1:0] convertedColour;
    logic [79:0] convertedRecord;
    logic [31:0] metadataHeader,metadataX,metadataY;
    logic [8:0] mappedX,mappedY;
    logic [8:0] nativeXMin,nativeXMax;
    logic [7:0] nativeYMin,nativeYMax;
    logic candidatePresent,candidateReference;
    // Presentation is compact and independent of internal candidate addresses:
    // red rows0..5 use #A..#F; blue rows0..7 use #0..#7. Unknown candidates
    // do not reserve a sample/panel slot; all16 shared candidates remain in JTAG/core.
    logic [SLOTS-1:0] displayUiVisible;
    logic [3:0] displayUiTags[0:15];
    logic [3:0] displayPanelSlots[0:13];
    logic [3:0] displayRedRows,displayBlueRows;
    logic displayRedOverflow,displayBlueOverflow;
    logic displaySourceFresh,displaySourceGood;
    logic [31:0] displaySourceAge;
    logic [29:0] renderedData,textBackground;
    logic [79:0] selectedRecord;
    logic textActive;
    logic [7:0] character;
    logic [4:0] fontRow;
    logic [8:0] numberValue;
    logic [1:0] decimalPosition;
    logic decimalActive,numberValid;
    logic [7:0] textX;
    logic [5:0] textY;
    logic [6:0] characterIndex;
    logic [2:0] glyphRow,glyphColumn;
    integer panelSlot,panelLine,crossSlot,localX,localY;
    // Exact bounded unsigned constant division. Quartus18.1 implemented the
    // original /6 then /10 chain as deep combinational dividers (37 levels,
    // -0.291ns setup in source7eec0ba4). These reciprocal products are exact
    // over every input of the declared width; the independent arithmetic TB
    // exhausts all values. They preserve the stream latency and pixel layout.
    function automatic logic [7:0] divideSix(input logic [9:0] value);
        logic [19:0] product;
        product=20'(value)*20'd683;
        return product[19:12];
    endfunction
    function automatic logic [2:0] remainderSix(input logic [9:0] value);
        logic [9:0] quotient;
        quotient=10'(divideSix(value));
        return 3'(value-((quotient<<2)+(quotient<<1)));
    endfunction
    function automatic logic [5:0] divideTen(input logic [8:0] value);
        logic [16:0] product;
        product=17'(value)*17'd205;
        return product[16:11];
    endfunction
    function automatic logic [3:0] remainderTen(input logic [8:0] value);
        logic [8:0] quotient;
        quotient=9'(divideTen(value));
        return 4'(value-((quotient<<3)+(quotient<<1)));
    endfunction
    function automatic logic [2:0] divideHundred(input logic [8:0] value);
        logic [14:0] product;
        product=15'(value)*15'd41;
        return product[14:12];
    endfunction
    // Exact for valid native interval endpoints (0..320). Ten-bit sums
    // cover 0..958; no signed 32-bit multiply/divide is inferred per slot.
    function automatic logic [8:0] scaledCentre(input logic [8:0] first,lastExclusive);
        logic [9:0] lowerScaled,upperScaled,sumScaled;
        lowerScaled={1'b0,first}+({1'b0,first}>>1);
        upperScaled={1'b0,lastExclusive}+({1'b0,lastExclusive}>>1)-10'd1;
        sumScaled=lowerScaled+upperScaled;
        return sumScaled[9:1];
    endfunction
    wire acceptedRaw=rawAccept&&!reset;
    assign rawPixelX=rawSop?10'd0:rawX;
    assign rawPixelY=rawSop?9'd0:rawY;
    assign pixelX=inSop?10'd0:rasterX;
    assign pixelY=inSop?9'd0:rasterY;
    assign inReady=!outValid||outReady;
    assign converterStart=conversionState==START_CONVERSION&&converterReady;
    memberBVgaHsv converter(.clk(clk),.reset(reset),.start(converterStart),.rgb(workRgb[conversionIndex]),
        .ready(converterReady),.valid(converterValid),.hue(convertedHue),.saturation(convertedSaturation),.value(convertedValue));
    hsvColourGate #(.BLUE_HUE_UPPER(BLUE_HUE_UPPER)) sampleGate(.rgb(workRgb[conversionIndex]),.redMinimum(workRedMinimum),
        .blueMinimum(workBlueMinimum),.colourMask(convertedColour));
    always_comb begin
        convertedRecord={workMeta[conversionIndex][24:18],workMeta[conversionIndex][17:9],
            workMeta[conversionIndex][8:0],workRgb[conversionIndex],convertedHue,
            convertedSaturation,convertedValue,convertedColour,4'd0};
        convertedRecord[0]=workReference[conversionIndex];
        metadataHeader=0;metadataX=0;metadataY=0;mappedX=0;mappedY=0;
        rawCaptureAge=rawDebugWords[2*32+:32]-rawDebugWords[4*32+:32];
        metadataFresh=rawDebugWords[31:0]==32'h45425031&&rawDebugWords[1*32+16+:16]==16'(DEBUG_SCHEMA_VERSION)&&
            !rawCaptureAge[31]&&rawCaptureAge<=32'd150000&&
            (rawDebugWords[3*32+:16]!=previousMetadataFrame||rawDebugWords[6*32+:16]!=previousConfigVersion||repeatedMetadataScans<8'd9);
        // One descriptor is selected each cycle from the held SOP snapshot.
        metadataHeader=debugWords[(24+4*metadataIndex[3:0])*32+:32];
        metadataX=debugWords[(25+4*metadataIndex[3:0])*32+:32];
        metadataY=debugWords[(26+4*metadataIndex[3:0])*32+:32];
        nativeXMin=metadataX[24:16];nativeXMax=metadataX[8:0];
        nativeYMin=metadataY[23:16];nativeYMax=metadataY[7:0];
        candidatePresent=sampleMetadataFresh&&sampleFrameGood&&metadataIndex<metadataCount&&
            nativeXMin<=nativeXMax&&nativeXMax<320&&nativeYMin<=nativeYMax&&nativeYMax<240;
        mappedX=9'd140+scaledCentre({1'b0,nativeYMin},{1'b0,nativeYMax}+9'd1);
        mappedY=scaledCentre(9'd319-nativeXMax,9'd320-nativeXMin);
        candidateReference=candidatePresent&&metadataHeader[30]&&metadataReferenceValid&&
            metadataIndex[3:0]==sampleReferenceIndex;
        freeBank=0;
        for(int bank=0;bank<3;bank++)
            if((!publishedReady||2'(bank)!=publishedBank)&&
               (!(loadActive||readPending)||2'(bank)!=loadBank))freeBank=2'(bank);
    end
    // Simple dual-port synchronous RAM. No asynchronous reads or reset loop.
    always_ff @(posedge clk)begin
        if(!reset&&conversionState==WAIT_CONVERSION&&converterValid)
            recordRam[{workBank,conversionIndex}]<=convertedRecord;
        if(loadActive)recordReadData<=recordRam[{loadBank,readIssueIndex}];
    end
    always_ff @(posedge clk)begin
        if(reset)begin
            rawX<=0;rawY<=0;sampleScanId<=0;workScanId<=0;publishedScanId<=0;
            sampleMetadataFrame<=0;workMetadataFrame<=0;publishedMetadataFrame<=0;
            sampleRedMinimum<=48;sampleBlueMinimum<=8'(DEFAULT_BLUE_MINIMUM);workRedMinimum<=48;workBlueMinimum<=8'(DEFAULT_BLUE_MINIMUM);
            conversionState<=IDLE;conversionIndex<=0;publishedReady<=0;
            previousMetadataFrame<=0;previousConfigVersion<=0;repeatedMetadataScans<=0;
            sampleFrameGood<=0;workFrameGood<=0;publishedFrameGood<=0;
            sampleMetadataFresh<=0;workMetadataFresh<=0;publishedMetadataFresh<=0;
            sampleReference<=0;workReference<=0;
            sampleReferenceIndex<=0;workReferenceIndex<=0;publishedReferenceIndex<=0;
            sampleOverflow<=0;workOverflow<=0;publishedOverflow<=0;
            workBank<=0;publishedBank<=0;
            metadataScanning<=0;metadataIndex<=0;metadataCount<=0;
            redSampleCount<=0;blueSampleCount<=0;centreMatches<=0;metadataReferenceValid<=0;
            for(int i=0;i<SLOTS;i++)begin
                sampleMeta[i]<=0;workMeta[i]<=0;workRgb[i]<=0;
                sumRed[i]<=0;sumGreen[i]<=0;sumBlue[i]<=0;sampleCount[i]<=0;
            end
        end else begin
            if(metadataScanning)begin
                if(metadataIndex==16)begin
                    metadataScanning<=0;
                    if(centreMatches!=1)sampleMeta[CENTRE_SLOT][23:18]<=0;
                    sampleOverflow<={blueSampleCount>8,redSampleCount>6};
                end else begin
                    metadataIndex<=metadataIndex+5'd1;
                    if(candidateReference)begin
                        sampleMeta[REFERENCE_SLOT]<={1'b1,1'b0,1'b1,4'd15,mappedX,mappedY};
                        sampleReference[REFERENCE_SLOT]<=1;
                    end else if(candidatePresent&&metadataHeader[31]&&metadataHeader[27:24]>=1&&metadataHeader[27:24]<=6)begin
                        if(!metadataHeader[30])begin
                            if(redSampleCount<6)sampleMeta[redSampleCount]<={1'b1,1'b1,1'b0,metadataHeader[27:24],mappedX,mappedY};
                            redSampleCount<=redSampleCount+5'd1;
                        end else begin
                            if(blueSampleCount<8)sampleMeta[5'd8+blueSampleCount]<={1'b1,1'b1,1'b1,metadataHeader[27:24],mappedX,mappedY};
                            blueSampleCount<=blueSampleCount+5'd1;
                        end
                        if(nativeXMin<=159&&nativeXMax>=159&&nativeYMin<=120&&nativeYMax>=120)begin
                            centreMatches<=centreMatches+6'd1;
                            sampleMeta[CENTRE_SLOT][23:18]<={1'b1,metadataHeader[30],metadataHeader[27:24]};
                        end
                    end
                end
            end
            if(acceptedRaw)begin
                if(rawSop)begin
                    sampleScanId<=sampleScanId+16'd1;sampleMetadataFrame<=rawDebugWords[3*32+:16];
                    sampleFrameGood<=rawDebugWords[(DEBUG_TAIL_BASE+3)*32];sampleMetadataFresh<=metadataFresh;
                    sampleReference<=0;sampleOverflow<=0;
                    metadataScanning<=1;metadataIndex<=0;
                    metadataCount<=rawDebugWords[9*32+:5]+rawDebugWords[9*32+5+:5];
                    metadataReferenceValid<=rawDebugWords[(DEBUG_TAIL_BASE+2)*32+3];
                    redSampleCount<=0;blueSampleCount<=0;centreMatches<=0;
                    sampleReferenceIndex<=rawDebugWords[(DEBUG_TAIL_BASE+2)*32+4+:4];
                    previousMetadataFrame<=rawDebugWords[3*32+:16];previousConfigVersion<=rawDebugWords[6*32+:16];
                    if(rawDebugWords[3*32+:16]!=previousMetadataFrame||rawDebugWords[6*32+:16]!=previousConfigVersion)repeatedMetadataScans<=0;
                    else if(repeatedMetadataScans!=255)repeatedMetadataScans<=repeatedMetadataScans+8'd1;
                    sampleRedMinimum<=rawDebugWords[31:0]==32'h45425031 ? rawDebugWords[7*32+8+:8]:8'd48;
                    sampleBlueMinimum<=rawDebugWords[31:0]==32'h45425031 ? rawDebugWords[7*32+:8]:8'(DEFAULT_BLUE_MINIMUM);
                    for(int i=0;i<SLOTS;i++)begin
                        sampleMeta[i]<=i==CENTRE_SLOT?{1'b1,1'b0,1'b0,4'd0,9'd320,9'd240}:25'd0;sumRed[i]<=0;sumGreen[i]<=0;sumBlue[i]<=0;sampleCount[i]<=0;
                    end
                end else for(int i=0;i<SLOTS;i++)begin
                    if(sampleMeta[i][24]&&int'(rawPixelX)>=int'(sampleMeta[i][17:9])-(i==16?4:2)&&
                       int'(rawPixelX)<int'(sampleMeta[i][17:9])+(i==16?4:2)&&
                       int'(rawPixelY)>=int'(sampleMeta[i][8:0])-(i==16?4:2)&&
                       int'(rawPixelY)<int'(sampleMeta[i][8:0])+(i==16?4:2))begin
                        sumRed[i]<=sumRed[i]+{6'd0,rawData[29:22]};
                        sumGreen[i]<=sumGreen[i]+{6'd0,rawData[19:12]};
                        sumBlue[i]<=sumBlue[i]+{6'd0,rawData[9:2]};sampleCount[i]<=sampleCount[i]+7'd1;
                    end
                end
                if(rawPixelX==639)begin rawX<=0;rawY<=rawPixelY==479?9'd0:rawPixelY+9'd1;end
                else begin rawX<=rawPixelX+10'd1;rawY<=rawPixelY;end
                if(rawEop&&conversionState==IDLE)begin
                    conversionIndex<=0;conversionState<=START_CONVERSION;workBank<=freeBank;
                    workScanId<=sampleScanId;workMetadataFrame<=sampleMetadataFrame;
                    workFrameGood<=sampleFrameGood;workMetadataFresh<=sampleMetadataFresh;
                    workReference<=sampleReference;
                    workReferenceIndex<=sampleReferenceIndex;workOverflow<=sampleOverflow;
                    workRedMinimum<=sampleRedMinimum;workBlueMinimum<=sampleBlueMinimum;
                    for(int i=0;i<SLOTS;i++)begin
                        workMeta[i]<=sampleMeta[i];
                        workMeta[i][24]<=sampleMeta[i][24]&&sampleCount[i]==(i==16?64:16)&&rawPixelX==639&&rawPixelY==479;
                        if(i==16)workRgb[i]<={sumRed[i][13:6],sumGreen[i][13:6],sumBlue[i][13:6]};
                        else workRgb[i]<={sumRed[i][11:4],sumGreen[i][11:4],sumBlue[i][11:4]};
                    end
                end
            end
            if(converterStart)conversionState<=WAIT_CONVERSION;
            if(conversionState==WAIT_CONVERSION&&converterValid)begin
                if(conversionIndex==SLOTS-1)begin
                    publishedBank<=workBank;publishedReady<=1;
                    publishedReferenceIndex<=workReferenceIndex;publishedOverflow<=workOverflow;
                    publishedScanId<=workScanId;publishedMetadataFrame<=workMetadataFrame;
                    publishedFrameGood<=workFrameGood;publishedMetadataFresh<=workMetadataFresh;
                    conversionState<=IDLE;
                end else begin conversionIndex<=conversionIndex+5'd1;conversionState<=START_CONVERSION;end
            end
        end
    end

    always_comb begin
        displaySourceAge=debugWords[2*32+:32]-debugWords[4*32+:32];
        displaySourceFresh=debugWords[31:0]==32'h45425031 && debugWords[1*32+16+:16]==16'(DEBUG_SCHEMA_VERSION) &&
            !displaySourceAge[31] && displaySourceAge<=32'd150000;
        displaySourceGood=displaySourceFresh && debugWords[(DEBUG_TAIL_BASE+3)*32];
    end

    function automatic logic [7:0] hexCharacter(input logic [3:0] nibble);
        return nibble<10?8'd48+{4'd0,nibble}:8'd55+{4'd0,nibble};
    endfunction
    function automatic logic [7:0] stringCharacter(input logic [511:0] text,input integer length,index);
        if(index<0||index>=length)return 8'd32;
        return text[(length-index-1)*8+:8];
    endfunction
    function automatic logic [4:0] font(input logic [7:0] ch,input logic [2:0] row);
        logic [34:0] bits;
        case(ch)
            "0":bits=35'b01110_10001_10011_10101_11001_10001_01110;
            "1":bits=35'b00100_01100_00100_00100_00100_00100_01110;
            "2":bits=35'b01110_10001_00001_00010_00100_01000_11111;
            "3":bits=35'b11110_00001_00001_01110_00001_00001_11110;
            "4":bits=35'b00010_00110_01010_10010_11111_00010_00010;
            "5":bits=35'b11111_10000_10000_11110_00001_00001_11110;
            "6":bits=35'b01110_10000_10000_11110_10001_10001_01110;
            "7":bits=35'b11111_00001_00010_00100_01000_01000_01000;
            "8":bits=35'b01110_10001_10001_01110_10001_10001_01110;
            "9":bits=35'b01110_10001_10001_01111_00001_00001_01110;
            "A":bits=35'b01110_10001_10001_11111_10001_10001_10001;
            "B":bits=35'b11110_10001_10001_11110_10001_10001_11110;
            "C":bits=35'b01111_10000_10000_10000_10000_10000_01111;
            "D":bits=35'b11110_10001_10001_10001_10001_10001_11110;
            "E":bits=35'b11111_10000_10000_11110_10000_10000_11111;
            "F":bits=35'b11111_10000_10000_11110_10000_10000_10000;
            "G":bits=35'b01111_10000_10000_10111_10001_10001_01111;
            "H":bits=35'b10001_10001_10001_11111_10001_10001_10001;
            "I":bits=35'b01110_00100_00100_00100_00100_00100_01110;
            "J":bits=35'b00111_00010_00010_00010_10010_10010_01100;
            "L":bits=35'b10000_10000_10000_10000_10000_10000_11111;
            "M":bits=35'b10001_11011_10101_10101_10001_10001_10001;
            "N":bits=35'b10001_11001_10101_10011_10001_10001_10001;
            "O":bits=35'b01110_10001_10001_10001_10001_10001_01110;
            "P":bits=35'b11110_10001_10001_11110_10000_10000_10000;
            "R":bits=35'b11110_10001_10001_11110_10100_10010_10001;
            "S":bits=35'b01111_10000_10000_01110_00001_00001_11110;
            "T":bits=35'b11111_00100_00100_00100_00100_00100_00100;
            "U":bits=35'b10001_10001_10001_10001_10001_10001_01110;
            "V":bits=35'b10001_10001_10001_10001_10001_01010_00100;
            "W":bits=35'b10001_10001_10001_10101_10101_11011_10001;
            "X":bits=35'b10001_10001_01010_00100_01010_10001_10001;
            "Y":bits=35'b10001_10001_01010_00100_00100_00100_00100;
            "#":bits=35'b01010_01010_11111_01010_11111_01010_01010;
            ":":bits=35'b00000_00100_00100_00000_00100_00100_00000;
            "-":bits=35'b00000_00000_00000_11111_00000_00000_00000;
            "/":bits=35'b00001_00010_00010_00100_01000_01000_10000;
            "?":bits=35'b01110_10001_00001_00010_00100_00000_00100;
            default:bits=0;
        endcase
        return row<7?bits[(6-int'(row))*5+:5]:5'd0;
    endfunction
    always_comb begin
        renderedData=inData;textActive=0;character=" ";textX=0;textY=0;characterIndex=0;glyphRow=0;glyphColumn=0;
        numberValue=0;decimalPosition=0;decimalActive=0;numberValid=0;selectedRecord=0;
        panelSlot=-1;panelLine=-1;crossSlot=-1;localX=0;localY=0;textBackground=30'd0;fontRow=0;
        if(heldShowCandidates)begin
            // Compact display tags identify the matching sample ROI and panel.
            // These tags never replace the separately displayed recognised ID.
            for(int i=0;i<SLOTS;i++)if(displayUiVisible[i])begin
                localX=int'(pixelX)-int'(displayRecords[i][72:64]);
                localY=int'(pixelY)-int'(displayRecords[i][63:55]);
                if(localX>=-2&&localX<=1&&localY>=-2&&localY<=1&&
                    (localX==-2||localX==1||localY==-2||localY==1))renderedData={10'h3ff,10'h3ff,10'd0};
                if(localX>=3&&localX<15&&localY>=-3&&localY<4)begin
                    crossSlot=i;textX=8'(localX-3);textY=6'(localY+3);
                end
            end
            if(crossSlot>=0)begin
                textActive=1;
                if(crossSlot==REFERENCE_SLOT)character=textX<6?"B":"J";
                else character=textX<6?"#":hexCharacter(displayUiTags[crossSlot]);
            end
            if(pixelX<140||pixelX>=500)begin
                for(int row=0;row<8;row++)if(pixelY>=70+row*46&&pixelY<70+row*46+30)begin
                    if((pixelX<140 && row<int'(displayRedRows)) ||
                       (pixelX>=500 && row<int'(displayBlueRows)) ||
                       (pixelX<140 && row==6 && displayUiVisible[REFERENCE_SLOT]))begin
                        if(pixelX<140 && row==6)panelSlot=REFERENCE_SLOT;
                        else panelSlot=int'(displayPanelSlots[pixelX>=500?6+row:row]);
                        textX=pixelX>=500?8'(pixelX-504):8'(pixelX-4);
                        localY=int'(pixelY)-(70+row*46);textY=6'(remainderTen(9'(6'(localY))));panelLine=int'(divideTen(9'(6'(localY))));
                        if(pixelX>=4&&pixelX<136||pixelX>=504&&pixelX<636)textActive=1;
                    end
                end
                if(panelSlot>=0)begin
                    selectedRecord=displayRecords[panelSlot];characterIndex=divideSix({2'd0,textX});
                    numberValid=selectedRecord[79];
                    if(panelLine==0)begin
                        if(characterIndex==0)character=selectedRecord[77]?"B":"R";
                        else if(characterIndex==1)character=selectedRecord[0]?"J":hexCharacter(selectedRecord[76:73]);
                        else if(panelSlot==REFERENCE_SLOT&&characterIndex>=3&&characterIndex<=5)character=stringCharacter("REF",3,int'(characterIndex)-3);
                        else if(characterIndex==3)character="#";
                        else if(characterIndex==4&&panelSlot<16)character=hexCharacter(displayUiTags[panelSlot]);
                        else if(characterIndex>=7)character=stringCharacter("4X4",3,int'(characterIndex)-7);
                        else character=" ";
                        textBackground=selectedRecord[77]?{10'd0,10'd64,10'd256}:{10'd256,10'd0,10'd0};
                    end else begin
                        if(characterIndex==0)character=panelLine==1?"R":"H";
                        else if(characterIndex==5)character=panelLine==1?"G":"S";
                        else if(characterIndex==10)character=panelLine==1?"B":"V";
                        else if(characterIndex>=1&&characterIndex<=3)begin
                            decimalActive=1;decimalPosition=2'(characterIndex-1);
                            numberValue=panelLine==1?{1'b0,selectedRecord[54:47]}:selectedRecord[30:22];
                        end else if(characterIndex>=6&&characterIndex<=8)begin
                            decimalActive=1;decimalPosition=2'(characterIndex-6);
                            numberValue=panelLine==1?{1'b0,selectedRecord[46:39]}:{1'b0,selectedRecord[21:14]};
                        end else if(characterIndex>=11&&characterIndex<=13)begin
                            decimalActive=1;decimalPosition=2'(characterIndex-11);
                            numberValue=panelLine==1?{1'b0,selectedRecord[38:31]}:{1'b0,selectedRecord[13:6]};
                        end else character=" ";
                    end
                end
            end
            // Six red tag letters are available by request. Extra accepted red
            // objects remain in the internal arrays; disclose the display cap.
            if(displayRedOverflow && pixelX>=4 && pixelX<52 && pixelY>=430 && pixelY<437)begin
                textActive=1;textX=8'(pixelX-4);textY=6'(pixelY-430);decimalActive=0;
                character=stringCharacter("RED OVF",7,int'(divideSix({2'd0,textX})));
                textBackground={10'd256,10'd0,10'd0};
            end
            if(displayBlueOverflow && pixelX>=504 && pixelX<558 && pixelY>=430 && pixelY<437)begin
                textActive=1;textX=8'(pixelX-504);textY=6'(pixelY-430);decimalActive=0;
                character=stringCharacter("BLUE OVF",8,int'(divideSix({2'd0,textX})));
                textBackground={10'd0,10'd64,10'd256};
            end
        end
        if(heldShowCentre)begin
            if(pixelX>=316&&pixelX<=323&&pixelY>=236&&pixelY<=243&&
                (pixelX==316||pixelX==323||pixelY==236||pixelY==243))renderedData={10'h3ff,10'h3ff,10'h3ff};
            if(pixelY>=448&&pixelY<475&&pixelX<500)begin
                localY=int'(pixelY)-448;panelLine=int'(divideTen(9'(6'(localY))));textY=6'(remainderTen(9'(6'(localY))));textX=8'(pixelX);
                // Centre panel is intentionally 240 px wide, avoiding wrap in textX.
                if(pixelX<240)begin
                    textActive=1;characterIndex=divideSix({2'd0,textX});selectedRecord=displayRecords[16];numberValid=selectedRecord[79];
                    if(panelLine==0)begin
                        character=stringCharacter("CENTRE8X8 C:  ID:  ",19,int'(characterIndex));
                        if(characterIndex==12)character=!numberValid?"?":selectedRecord[5:4]==1?"R":selectedRecord[5:4]==2?"B":"-";
                        if(characterIndex==16)character=selectedRecord[78]&&numberValid&&displayFrameGood&&displayMetadataFresh?(selectedRecord[77]?"B":"R"):"?";
                        if(characterIndex==17)character=selectedRecord[78]&&numberValid&&displayFrameGood&&displayMetadataFresh?hexCharacter(selectedRecord[76:73]):"?";
                    end else begin
                        if(characterIndex==0)character=panelLine==1?"R":"H";
                        else if(characterIndex==5)character=panelLine==1?"G":"S";
                        else if(characterIndex==10)character=panelLine==1?"B":"V";
                        else if(characterIndex>=1&&characterIndex<=3)begin decimalActive=1;decimalPosition=2'(characterIndex-1);numberValue=panelLine==1?{1'b0,selectedRecord[54:47]}:selectedRecord[30:22];end
                        else if(characterIndex>=6&&characterIndex<=8)begin decimalActive=1;decimalPosition=2'(characterIndex-6);numberValue=panelLine==1?{1'b0,selectedRecord[46:39]}:{1'b0,selectedRecord[21:14]};end
                        else if(characterIndex>=11&&characterIndex<=13)begin decimalActive=1;decimalPosition=2'(characterIndex-11);numberValue=panelLine==1?{1'b0,selectedRecord[38:31]}:{1'b0,selectedRecord[13:6]};end
                        else character=" ";
                    end
                end
            end
        end
        if((pixelX<140||pixelX>=500)&&pixelY>=34&&pixelY<51)begin
            textActive=1;textX=pixelX>=500?8'(pixelX-504):8'(pixelX-4);
            textY=pixelY<41?6'(pixelY-34):6'(pixelY-44);characterIndex=divideSix({2'd0,textX});decimalActive=0;
            character=" ";textBackground=0;
            if(pixelY<41)begin
                if(characterIndex<4)character=stringCharacter(pixelX<140?"VGA:":"META:",pixelX<140?4:5,int'(characterIndex));
                if(pixelX<140&&characterIndex>=4&&characterIndex<8)
                    character=hexCharacter(4'(displayScanId>>(4*(7-int'(characterIndex)))));
                if(pixelX>=500)begin
                    if(characterIndex==4)character=":";
                    if(characterIndex>=5&&characterIndex<9)character=hexCharacter(4'(displayMetadataFrame>>(4*(8-int'(characterIndex)))));
                end
            end else if(pixelY>=44)begin
                if(pixelX<140)character=stringCharacter(!displayMetadataFresh?"FRAME:STALE":displayFrameGood?"FRAME:GOOD":"FRAME:BAD",!displayMetadataFresh?11:displayFrameGood?10:9,int'(characterIndex));
                else character=stringCharacter("ID:BOX ASSOC",12,int'(characterIndex));
            end
        end
        if(pixelY<20)begin
            textActive=1;textBackground=0;textX=8'(pixelX);textY=6'(remainderTen(pixelY));
            characterIndex=7'(divideSix(pixelX));decimalActive=0;
            // Header spans at most 64 characters. Use the full column here.
            if(pixelY<10)begin
                case(int'(divideSix(pixelX)))
                    0,1,2,3:character=stringCharacter("CAL:",4,int'(divideSix(pixelX)));
                    4:character=displayStatus.interactionBusy?"B":displayStatus.calibrated?"Y":"W";
                    6,7,8,9:character=stringCharacter("CFG:",4,int'(divideSix(pixelX))-6);
                    10,11,12,13:character=hexCharacter(4'(displayStatus.activeCfgVersion>>(4*(13-int'(divideSix(pixelX))))));
                    15,16,17,18,19,20,21:character=stringCharacter("SAMPLE:",7,int'(divideSix(pixelX))-15);
                    22:character=hexCharacter(displaySampleCount);
                    24,25,26,27:character=stringCharacter("ARM:",4,int'(divideSix(pixelX))-24);
                    28:character=displayStatus.speechArmed?"1":"0";
                    30,31,32,33,34,35,36,37,38,39,40,41,42,43:character=stringCharacter("AUDIO DEFERRED",14,int'(divideSix(pixelX))-30);
                    45,46,47,48,49,50:character=stringCharacter("STATE:",6,int'(divideSix(pixelX))-45);
                    51:character=hexCharacter(displayStatus.state);
                    53,54,55,56,57,58,59:character=stringCharacter("BYPASS:",7,int'(divideSix(pixelX))-53);
                    60:character=displayBypass?"1":"0";
                    default:character=" ";
                endcase
            end else character=stringCharacter("SW0:REGIONS SW1:CENTRE RGB/S/V:0-255 H:DEG VGA HELD",51,int'(divideSix(pixelX)));
        end
        if(decimalActive)begin
            if(!numberValid)character="-";
            else case(decimalPosition)
                0:character=8'd48+8'(divideHundred(numberValue));
                1:character=8'd48+8'(remainderTen(9'(divideTen(numberValue))));
                default:character=8'd48+8'(remainderTen(numberValue));
            endcase
        end
        glyphColumn=pixelY<20?3'(remainderSix(pixelX)):3'(remainderSix({2'd0,textX}));glyphRow=3'(textY);fontRow=font(character,glyphRow);
        if(textActive)begin
            renderedData=textBackground;
            if(textY<7&&glyphColumn<5&&fontRow[4-glyphColumn])renderedData={10'h3ff,10'h3ff,10'h3ff};
        end
    end
    always_ff @(posedge clk)begin
        if(reset)begin
            outValid<=0;outData<=0;outSop<=0;outEop<=0;rasterX<=0;rasterY<=0;
            heldShowCandidates<=0;heldShowCentre<=0;displayStatus<='0;displaySampleCount<=0;
            displayBypass<=0;
            loadActive<=0;readPending<=0;readIssueIndex<=0;readSlot<=0;loadBank<=0;displayReferenceMatches<=0;
            displayScanId<=0;displayMetadataFrame<=0;
            displayFrameGood<=0;displayMetadataFresh<=0;
            displayUiVisible<=0;displayRedRows<=0;displayBlueRows<=0;displayRedOverflow<=0;displayBlueOverflow<=0;
            for(int i=0;i<16;i++)displayUiTags[i]<=0;
            for(int row=0;row<14;row++)displayPanelSlots[row]<=0;
            for(int i=0;i<SLOTS;i++)displayRecords[i]<=0;
        end else begin
            // Consume one registered M10K read per clock, independently of pixel
            // backpressure. This completes19 clocks after SOP, before any ROI
            // glyph can appear (earliest x=137); headers use separate registers.
            readPending<=loadActive;
            if(loadActive)begin
                readSlot<=readIssueIndex;
                if(readIssueIndex==SLOTS-1)loadActive<=0;
                else readIssueIndex<=readIssueIndex+5'd1;
            end
            if(readPending)begin
                displayRecords[readSlot]<=recordReadData;
                if(displayFrameGood&&displayMetadataFresh&&recordReadData[79])begin
                    if(readSlot<16&&recordReadData[78]&&recordReadData[76:73]>=1&&recordReadData[76:73]<=6)begin
                        if(readSlot<8&&displayRedRows<6)begin
                            displayUiVisible[readSlot]<=1;
                            displayUiTags[readSlot]<=4'd10+displayRedRows;
                            displayPanelSlots[displayRedRows]<=4'(readSlot);
                            displayRedRows<=displayRedRows+4'd1;
                        end else if(readSlot>=8)begin
                            displayUiVisible[readSlot]<=1;
                            displayUiTags[readSlot]<=displayBlueRows;
                            displayPanelSlots[4'd6+displayBlueRows]<=4'(readSlot);
                            displayBlueRows<=displayBlueRows+4'd1;
                        end
                    end else if(readSlot==REFERENCE_SLOT&&recordReadData[0]&&displayReferenceMatches)
                        displayUiVisible[REFERENCE_SLOT]<=1;
                end
            end
            if(inReady)begin
            outValid<=inValid;
            if(inValid)begin
                outData<=renderedData;outSop<=inSop;outEop<=inEop;
                if(inSop)begin
                    heldShowCandidates<=showCandidates;heldShowCentre<=showCentre;
                    displayStatus<=debugWords[10*32+:76];displaySampleCount<=debugWords[(DEBUG_TAIL_BASE+1)*32+:4];
                    displayBypass<=debugWords[1*32+16+:16]>=3&&debugWords[7*32+20];
                    displayScanId<=publishedScanId;displayMetadataFrame<=publishedMetadataFrame;
                    displayFrameGood<=publishedFrameGood&&displaySourceGood;
                    displayMetadataFresh<=publishedMetadataFresh&&displaySourceFresh;
                    loadActive<=publishedReady;loadBank<=publishedBank;readIssueIndex<=0;readPending<=0;
                    displayReferenceMatches<=debugWords[(DEBUG_TAIL_BASE+2)*32+3]&&
                        debugWords[(DEBUG_TAIL_BASE+2)*32+4+:4]==publishedReferenceIndex;
                    displayUiVisible<=0;displayRedRows<=0;displayBlueRows<=0;
                    displayRedOverflow<=publishedReady&&publishedFrameGood&&publishedMetadataFresh&&displaySourceGood&&publishedOverflow[0];
                    displayBlueOverflow<=publishedReady&&publishedFrameGood&&publishedMetadataFresh&&displaySourceGood&&publishedOverflow[1];
                    for(int i=0;i<16;i++)displayUiTags[i]<=0;
                    for(int row=0;row<14;row++)displayPanelSlots[row]<=0;
                    if(!publishedReady)for(int i=0;i<SLOTS;i++)displayRecords[i]<=0;
                end
                if(pixelX==639)begin rasterX<=0;rasterY<=pixelY==479?9'd0:pixelY+9'd1;end
                else begin rasterX<=pixelX+10'd1;rasterY<=pixelY;end
            end
        end
        end
    end
endmodule
