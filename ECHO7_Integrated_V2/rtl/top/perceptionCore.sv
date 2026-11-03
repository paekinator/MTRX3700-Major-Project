// CLOCK_50 processing, native-pixel FIFO input, no motion outputs. Temporary
// label capacity is independent of the sixteen completed candidates shared by both colours.
module perceptionCore (
    input logic clk,reset,pclk,resetPclk,cameraFrameStart,cameraPixelValid,
    input logic [15:0] cameraPixel,
    input logic [9:0] cameraX,
    input logic [8:0] cameraY,
    input logic [31:0] timeUs,
    input logic interactionEnable,interactionPermit,debugCalArm,debugSpeechArm,
    output logic debugInteractionArmReady,
    input logic [1:0] orientationProfile,
    input logic bypassPerspective,
    // CLOCK_50 control. Readiness falls immediately when disabled; the pixel
    // processing mode changes atomically at the next input SOF. Camera capture,
    // native frame numbering, the shared clock and held team transactions run
    // continuously in both modes.
    input logic processingEnable,
    input perception_pkg::targetRequest_t targetRequest,
    input logic targetRequestValid,
    output logic targetRequestReady,
    output perception_pkg::targetReport_t targetReport,
    output logic targetReportValid,
    input logic targetReportReady,
    // LIST/GET use this independent response stream. Holding a query result
    // never stalls capture or replaces the separately selected tracking target.
    output perception_pkg::queryResult_t queryResult,
    output logic queryResultValid,
    input logic queryResultReady,
    output logic queryBusy,
    output perception_pkg::userEvent_t userEvent,
    output logic userEventValid,
    input logic userEventReady,
    output perception_pkg::perceptionStatus_t status,
    output logic [perception_pkg::DEBUG_WORD_COUNT*32-1:0] debugWords,
    output logic completedFrame,
    output logic [15:0] completedFrameId
);
    import camera_pkg::*;
    import candidate_pkg::*;
    import perception_pkg::*;
    import vision_pkg::*;
    // Real source5633257e frame16493 exhausted all twelve temporary red
    // handles, invalidating the whole frame. Fifteen is the largest capacity
    // representable by four-bit labels with zero reserved as the sentinel.
    // Actual frame56554 contains nine completed blue regions (including the
    // calibration bar). Sixteen completed outputs retain this scene without
    // widening active labels; a genuine seventeenth output still rejects the
    // whole frame. Row maintenance remains335 clocks (336 after EOP).
    localparam int ACTIVE_CAPACITY=15, OUTPUT_CAPACITY=16;
    localparam int ROW_GUARD=320+ACTIVE_CAPACITY+6;
    targetRequest_t activeRequest;
    logic streamValid,transportFault;
    logic [79:0] streamData;
    logic [8:0] rowGuard;
    wire sof=streamValid&&streamData[79];
    wire pixelValid=streamValid&&!streamData[79];
    wire [8:0] x=streamData[32:24];
    wire [7:0] y=streamData[23:16];
    wire pixelSop=pixelValid&&x==0&&y==0;
    wire pixelEop=pixelValid&&x==319&&y==239;
    logic activeProcessing,rawFrameOpen,lastFrameRaw;
    wire processingModeChange=sof&&(activeProcessing!=processingEnable);
    wire processingReset=reset||!activeProcessing||processingModeChange;
    wire processingPixelValid=pixelValid&&activeProcessing&&!processingReset;
    // Stop combinational colour/white classification toggling in raw mode as
    // well as stopping all sequential processing. The capture FIFO is untouched.
    wire [23:0] rgb=activeProcessing?rgb565_to_rgb888(streamData[15:0]):24'd0;
    wire [9:0] r={2'b0,rgb[23:16]},g={2'b0,rgb[15:8]},b={2'b0,rgb[7:0]};
    logic [7:0] activeRedMinimum,activeBlueMinimum,shadowRedMinimum,shadowBlueMinimum;
    logic [1:0] activeOrientation;
    logic activeBypass,bankBypass[0:1],lastFrameBypass;
    logic [15:0] configVersion;
    logic [15:0] lastFrameConfigVersion;
    logic [1:0] lastFrameOrientation;
    wire [1:0] colourMask;
    hsvColourGate #(.BLUE_HUE_UPPER(260)) colourGate (.rgb(rgb),.redMinimum(activeRedMinimum),
        .blueMinimum(activeBlueMinimum),.colourMask(colourMask));
    // Reader algorithm 4 preserves strict anchor connectivity, while admitting
    // dim, unsaturated stroke pixels. Actual frame31285's lower-right stroke
    // has luma 73..88 although its anchor is brighter. A global white-floor
    // reduction joined anchor components to paper in earlier counterexamples.
    // This is NOT automatic white calibration: red/blue calibration never
    // changes the fixed threshold. R+2G+B spans 0..1020 and fits ten bits.
    // Debug word95's white byte is quarter-luma units for algorithms 2/3/4;
    // historical algorithm 1 keeps its minimum-channel interpretation.
    localparam int WHITE_LUMA_QUARTER=84;
    wire [9:0] whiteLumaSum=r+(g<<1)+b;
    wire [9:0] rgbMaximum=r>g?(r>b?r:b):(g>b?g:b);
    wire [9:0] rgbMinimum=r<g?(r<b?r:b):(g<b?g:b);
    wire whiteSpreadGood=rgbMaximum-rgbMinimum<=64;
    wire strongWhitePixel=whiteSpreadGood&&whiteLumaSum>=10'd384;
    // The weak branch has S<1/2, disjoint from colour S>=1/2. Retaining the
    // strict branch as a union guarantees strongWhite is a subset of white.
    // Exhaustive RGB565 checks also prove strictWhite/colour disjointness for
    // colour algorithm2. Thus both predicates and raw colour still fit 2 bits.
    wire whitePixel=strongWhitePixel||(whiteSpreadGood&&
        whiteLumaSum>=10'(4*WHITE_LUMA_QUARTER-2)&&
        ((rgbMaximum-rgbMinimum)<<1)<rgbMaximum);
    cameraStreamBridge cameraBridge (
        .pclk(pclk),.resetPclk(resetPclk),.frameStart(cameraFrameStart),
        .pixelValid(cameraPixelValid),.pixel(cameraPixel),.pixelX(cameraX),.pixelY(cameraY),
        .clk(clk),.reset(reset),.timeUs(timeUs),.activeRequest(activeRequest),
        .streamReady(rowGuard==0),.streamValid(streamValid),.streamData(streamData),.transportFault(transportFault));
    logic cleanValid,cleanSop,cleanEop,abandonAtSof;
    logic [8:0] cleanX;
    logic [7:0] cleanY;
    logic [1:0] cleanMask;
    logic runValid,runSop,runEop;
    logic [8:0] runX;
    logic [7:0] runY;
    logic [1:0] runMask;
    // Keep complete >=2-pixel horizontal runs, including their first/last
    // pixels. This removes quantised orange speckles without eroding card
    // corners. The reader's foreground bank deliberately retains raw HSV bits.
    // Colour algorithm3 retains measured two-pixel side connections in rotated
    // signs. The filter keeps its two-token latency and row-flush schedule.
    horizontalRunFilter #(.MIN_RUN_LENGTH(2)) runFilter (.clk(clk),.reset(processingReset||abandonAtSof),
        .in_valid(processingPixelValid),.in_sop(pixelSop),.in_eop(pixelEop),.in_x(x),.in_y(y),.in_mask(colourMask),
        .out_valid(runValid),.out_sop(runSop),.out_eop(runEop),.out_x(runX),.out_y(runY),.out_mask(runMask));
    causalMaskCleanup cleanup (.clk(clk),.reset(processingReset||abandonAtSof),.in_valid(runValid),.in_sop(runSop),.in_eop(runEop),
        .in_x(runX),.in_y(runY),.in_mask(runMask),.out_valid(cleanValid),.out_sop(cleanSop),
        .out_eop(cleanEop),.out_x(cleanX),.out_y(cleanY),.out_mask(cleanMask));
    candidate_array_t sharedCandidates;
    logic [15:0] sharedColours;
    logic [4:0] sharedCount;
    logic [4:0] redCount,blueCount;
    logic [3:0] allocationPeakRed,allocationPeakBlue;
    logic candidateValid,candidateGood,candidateOverflow,candidateError,candidateOverrun;
    logic [15:0] candidateSequence;
    boundedCandidates #(.CAP(OUTPUT_CAPACITY),.SHARED_POOL(1),.PRUNE_UNUSABLE(1),.ACTIVE_CAP(ACTIVE_CAPACITY)) candidates (.clk(clk),.reset(processingReset||abandonAtSof),.in_valid(cleanValid),.in_sop(cleanSop),.in_eop(cleanEop),
        .in_mask(cleanMask),.in_x(cleanX),.in_y(cleanY),.sharedCandidates(sharedCandidates),.sharedColours(sharedColours),.sharedCount(sharedCount),
        .red_count(redCount),.blue_count(blueCount),.out_valid(candidateValid),.frame_valid(candidateGood),
        .overflow(candidateOverflow),.red_overflow(),.blue_overflow(),.frame_error(candidateError),
        .overrun(candidateOverrun),.frame_id(candidateSequence),.busy(),
        .allocationPeakRed(allocationPeakRed),.allocationPeakBlue(allocationPeakBlue));
    typedef enum logic [1:0] {FREE,WRITING,READY,READING} bankState_t;
    bankState_t bankState[0:1];
    frameObservation_t bankMeta[0:1],captureMeta,observation,processedObservation;
    candidate_array_t bankCandidates[0:1];
    logic [15:0] bankColours[0:1];
    logic [1:0] bankOrientation[0:1];
    // The segmentation profile belongs to the captured bank, not the later
    // global profile when that bank finishes recognition.
    logic [7:0] bankRedMinimum[0:1],bankBlueMinimum[0:1];
    logic [4:0] bankRedCount[0:1],bankBlueCount[0:1];
    logic [3:0] bankPeakRed[0:1],bankPeakBlue[0:1];
    logic [2:0] bankCandidateFaults[0:1];
    logic writeBank,haveWriteBank,readBank,readerStart,readerBusy,readerDone;
    // Part A intentionally publishes an aborted old frame on an overlapping SOP.
    // Discarding a partial capture here resets only the candidate/cleanup state,
    // so that old packet cannot be attached to the new frame's metadata.
    assign abandonAtSof=sof&&activeProcessing&&processingEnable&&!processingModeChange&&
        haveWriteBank&&bankState[writeBank]==WRITING&&!candidateValid;
    logic [16:0] glyphAddress;
    logic glyphWhite,glyphStrongWhite,glyphColour;
    markerArray_t markers,lastMarkers;
    logic [3:0] geometryReadIndex;
    colourQuad_t geometryReadQuad,aggregateRedQuad,aggregateBlueQuad;
    logic [4:0] acceptedCount;
    logic observationValid;
    logic [15:0] bufferDropCount,reportDropCount;
    logic requestInvalidFault;
    glyphBanks glyphMemory (.clk(clk),.writeEnable(processingPixelValid&&haveWriteBank&&x<320&&y<240),
        .writeBank(writeBank),.writeAddress(17'(y)*17'd320+17'(x)),.writeWhite(whitePixel),
        .writeStrongWhite(strongWhitePixel),.writeColour(colourMask!=0),
        .readBank(readBank),.readAddress(glyphAddress),.readWhite(glyphWhite),
        .readStrongWhite(glyphStrongWhite),.readColour(glyphColour));
    projectiveMarkerReader reader (.clk(clk),.reset(processingReset),.start(readerStart),.sharedCandidates(bankCandidates[readBank]),
        .sharedColours(bankColours[readBank]),.orientationProfile(bankOrientation[readBank]),.busy(readerBusy),
        .bypassPerspective(bankBypass[readBank]),
        .done(readerDone),.readAddress(glyphAddress),.readWhite(glyphWhite),
        .readStrongWhite(glyphStrongWhite),.readColour(glyphColour),
        .markers(markers),.acceptedCount(acceptedCount),
        .geometryReadIndex(geometryReadIndex),.geometryReadQuad(geometryReadQuad));
    logic trackerRequestReady,queryRequestReady;
    wire requestIsQuery=targetRequest.operation==TARGET_LIST||targetRequest.operation==TARGET_GET;
    assign targetRequestReady=requestIsQuery?queryRequestReady:trackerRequestReady;
    targetTracker tracker (.clk(clk),.reset(reset),.timeUs(timeUs),.activeCfgVersion(configVersion),
        .perceptionReady(status.perceptionReady),.targetRequest(targetRequest),.targetRequestValid(targetRequestValid&&!requestIsQuery),
        .targetRequestReady(trackerRequestReady),.frameObservation(observation),.frameValid(observationValid),
        .targetReport(targetReport),.targetReportValid(targetReportValid),.targetReportReady(targetReportReady),
        .activeRequest(activeRequest),.reportDropCount(reportDropCount),.requestInvalidFault(requestInvalidFault));

    // Pair using the red card's local geometry, never a sheet cell/known bay.
    function automatic logic referencePaired(input marker_t card,input candidate_t refBox,input logic [1:0] rotation);
        // All geometry is in native pixels along the configured card axes.
        // Signed15-bit intermediates cover coordinates <=319, doubled centres,
        // signed gaps and the largest constant product (width x12 <=3840).
        // Pair lateral centres, not both absolute bbox edges: perspective can
        // change strip width while keeping its centre aligned with its own red1.
        // Tolerance is ceil(cardWidth/16), with no fixed pixel allowance. Ceil
        // retains one-pixel quantisation at small scales; twice-centre arithmetic
        // avoids rounding either centre before comparing them. This remains a
        // configured-quadrant check, not arbitrary-angle projective calibration.
        logic signed [14:0] cw,ch,rw,rh,lo,hi,rl,rhEnd,gap;
        logic signed [14:0] centreDelta2,centreTolerance,overlapLow,overlapHigh,overlapWidth;
        begin
            cw=15'(rotation[0]?int'(card.yMax)-int'(card.yMin)+1:int'(card.xMax)-int'(card.xMin)+1);
            ch=15'(rotation[0]?int'(card.xMax)-int'(card.xMin)+1:int'(card.yMax)-int'(card.yMin)+1);
            rw=15'(rotation[0]?int'(refBox.ymax)-int'(refBox.ymin)+1:int'(refBox.xmax)-int'(refBox.xmin)+1);
            rh=15'(rotation[0]?int'(refBox.xmax)-int'(refBox.xmin)+1:int'(refBox.ymax)-int'(refBox.ymin)+1);
            lo=15'(rotation[0]?int'(card.yMin):int'(card.xMin));hi=15'(rotation[0]?int'(card.yMax):int'(card.xMax));
            rl=15'(rotation[0]?int'(refBox.ymin):int'(refBox.xmin));rhEnd=15'(rotation[0]?int'(refBox.ymax):int'(refBox.xmax));
            case(rotation)
                0:gap=15'(int'(refBox.ymin)-int'(card.yMax)-1);
                1:gap=15'(int'(card.xMin)-int'(refBox.xmax)-1);
                2:gap=15'(int'(card.yMin)-int'(refBox.ymax)-1);
                default:gap=15'(int'(refBox.xmin)-int'(card.xMax)-1);
            endcase
            centreDelta2=rl+rhEnd-lo-hi;
            centreTolerance=(cw+15'sd15)>>>4;
            overlapLow=lo>rl?lo:rl;overlapHigh=hi<rhEnd?hi:rhEnd;
            overlapWidth=overlapHigh>=overlapLow?overlapHigh-overlapLow+15'sd1:15'sd0;
            referencePaired=refBox.valid&&cw>0&&ch>0&&rw>0&&rh>0&&
                gap>=0&&gap*15'sd8<=ch&&rw*15'sd10>=cw*15'sd8&&rw*15'sd10<=cw*15'sd12&&
                rh*15'sd10>=ch&&rh*15'sd10<=ch*15'sd3&&
                centreDelta2>=-(centreTolerance<<<1)&&centreDelta2<=(centreTolerance<<<1)&&
                overlapWidth*15'sd5>=cw*15'sd4;
        end
    endfunction
    function automatic logic stationary(input candidate_t a,input candidate_t c);
        stationary=a.valid&&c.valid&&int'(a.xmin)-int'(c.xmin)<=3&&int'(c.xmin)-int'(a.xmin)<=3&&
            int'(a.xmax)-int'(c.xmax)<=3&&int'(c.xmax)-int'(a.xmax)<=3&&
            int'(a.ymin)-int'(c.ymin)<=3&&int'(c.ymin)-int'(a.ymin)<=3&&
            int'(a.ymax)-int'(c.ymax)<=3&&int'(c.ymax)-int'(a.ymax)<=3;
    endfunction
    candidate_t pairRed,pairBlue,lastPairRed,lastPairBlue,sampledRed,sampledBlue;
    candidate_t bankSampleRed[0:1],bankSampleBlue[0:1];
    samplePolygon_t pairRedPolygon,pairBluePolygon,lastRedPolygon,lastBluePolygon;
    samplePolygon_t sampledRedPolygon,sampledBluePolygon;
    samplePolygon_t bankRedPolygon[0:1],bankBluePolygon[0:1];
    logic sampledProjective,bankSampleProjective[0:1];
    // Blue polygon corners are ordered relative to the matched red1 anchor,
    // not the contour scanner's cyclic start. Compare actual sampled geometry
    // with this frame's independently remeasured quad before accepting RGB.
    function automatic logic polygonStationary(input samplePolygon_t a,input samplePolygon_t c);
        logic signed [13:0] dx,dy;
        begin
            polygonStationary=a.valid&&c.valid;
            for(int i=0;i<4;i++)begin
                dx=$signed({1'b0,a.x[i]})-$signed({1'b0,c.x[i]});
                dy=$signed({1'b0,a.y[i]})-$signed({1'b0,c.y[i]});
                if(dx < -14'sd48 || dx > 14'sd48 || dy < -14'sd48 || dy > 14'sd48)
                    polygonStationary=0;
            end
        end
    endfunction
    logic red1Paired,red2Seen,roiValid;
    logic [4:0] pairCount,red2Count;
    logic [3:0] pairReferenceIndex,lastCalibrationReferenceIndex;
    logic [7:0] pairQuality,lastCalibrationReferenceQuality;
    logic lastCalibrationReferenceValid;
    // One geometric comparator is shared across candidate pairs. The former
    // combinational 16x8 loop duplicated 128 arithmetic/priority paths and was
    // the largest contributor to the failed fit. Keep the READING bank owned
    // until this bounded scan completes, so all data still belongs to one frame.
    typedef enum logic [3:0] {AG_IDLE,AG_MARKER,AG_RED_READ,AG_RED_WAIT,
        AG_REFERENCE,AG_BLUE_READ,AG_BLUE_WAIT,AG_GEOMETRY_START,AG_GEOMETRY_WAIT,
        AG_PAIR,AG_NEXT_REFERENCE,AG_DONE} aggregateState_t;
    aggregateState_t aggregateState;
    logic [3:0] markerIndex;
    logic [3:0] referenceIndex;
    logic geometryBusy,geometryDone,geometryPairValid;
    logic [3:0] geometryReason;
    samplePolygon_t geometryRedPolygon,geometryBluePolygon;
    assign geometryReadIndex=(aggregateState==AG_RED_READ||aggregateState==AG_RED_WAIT)?markerIndex:referenceIndex;
    calibrationGeometry calibrationPair (
        .clk(clk),.reset(processingReset),.start(aggregateState==AG_GEOMETRY_START),
        .redQuad(aggregateRedQuad),.blueQuad(aggregateBlueQuad),
        .redBox(bankCandidates[readBank][markerIndex]),.blueIsBay(markers[referenceIndex].accepted),
        .busy(geometryBusy),.done(geometryDone),.pairValid(geometryPairValid),.reason(geometryReason),
        .redPolygon(geometryRedPolygon),.bluePolygon(geometryBluePolygon));
    wire aggregateDone=aggregateState==AG_DONE;
    // Share the existing indexed marker bus with the descriptor writer. This
    // adds only 48 small RAM entries; it does not duplicate a frame buffer.
    marker_t aggregateMarker;
    assign aggregateMarker=markers[markerIndex];
    // Capture can report a newer truncated/dropped frame on the same clock as
    // an older owned bank finishes classification. The newer bad observation
    // must win: publishing the old good result would hide immediate lock loss.
    wire captureDropNow=abandonAtSof||(candidateValid&&!haveWriteBank);
    wire aggregateAccepted=aggregateDone&&!captureDropNow&&activeProcessing&&processingEnable&&!processingModeChange;
    logic [15:0] completionDiscardCount;
    assign red1Paired=pairCount==1;
    assign red2Seen=red2Count==1;
    wire referencePatch=aggregateAccepted&&red1Paired&&processedObservation.frameGood;
    wire queryPublishBad=captureDropNow||(!activeProcessing&&rawFrameOpen&&pixelEop);
    markerQueryStore queryStore (
        .clk(clk),.reset(reset),.timeUs(timeUs),.activeConfigVersion(configVersion),
        .perceptionReady(status.perceptionReady),
        .beginFrame(readerDone&&activeProcessing&&processingEnable&&!processingModeChange),
        .inputFrameId(bankMeta[readBank].frameId),.inputCaptureStartUs(bankMeta[readBank].captureStartUs),
        .inputConfigVersion(bankMeta[readBank].configVersion),.inputFrameGood(bankMeta[readBank].frameGood),
        .writeValid((aggregateState==AG_MARKER&&!processingReset)||referencePatch),
        .writeIndex(referencePatch?pairReferenceIndex:markerIndex),
        .writeAccepted(referencePatch||aggregateMarker.accepted),
        .writeType(referencePatch?MARKER_REFERENCE:(aggregateMarker.isBlue?MARKER_BAY:MARKER_FUNCTION)),
        .writeDigit(referencePatch?4'hf:aggregateMarker.digit),
        .writeQuality(referencePatch?pairQuality:aggregateMarker.quality),
        .writeXMin(referencePatch?pairBlue.xmin:aggregateMarker.xMin),
        .writeXMax(referencePatch?pairBlue.xmax:aggregateMarker.xMax),
        .writeYMin(referencePatch?pairBlue.ymin:aggregateMarker.yMin),
        .writeYMax(referencePatch?pairBlue.ymax:aggregateMarker.yMax),
        .commitFrame(aggregateAccepted),.cancelFrame(processingModeChange||!processingEnable),
        .publishBad(queryPublishBad),.badFrameId(captureMeta.frameId),
        .badCaptureStartUs(captureMeta.captureStartUs),.badConfigVersion(captureMeta.configVersion),
        .queryRequest(targetRequest),.queryRequestValid(targetRequestValid&&requestIsQuery),
        .queryRequestReady(queryRequestReady),.queryResult(queryResult),
        .queryResultValid(queryResultValid),.queryResultReady(queryResultReady),.queryBusy(queryBusy));
    always_ff @(posedge clk) begin
        if(processingReset) begin
            aggregateState<=AG_IDLE;markerIndex<=0;referenceIndex<=0;
            processedObservation<='0;pairRed<='0;pairBlue<='0;pairCount<=0;red2Count<=0;pairReferenceIndex<=0;pairQuality<=0;
            aggregateRedQuad<='0;aggregateBlueQuad<='0;pairRedPolygon<='0;pairBluePolygon<='0;
        end else case(aggregateState)
            AG_IDLE: if(readerDone) begin
                processedObservation<=bankMeta[readBank];processedObservation.matchCount<=0;
                pairRed<='0;pairBlue<='0;pairCount<=0;red2Count<=0;pairReferenceIndex<=0;pairQuality<=0;
                pairRedPolygon<='0;pairBluePolygon<='0;
                markerIndex<=0;referenceIndex<=0;aggregateState<=AG_MARKER;
            end
            AG_MARKER: begin
                if(markers[markerIndex].accepted) begin
                    if((markers[markerIndex].isBlue?MARKER_BAY:MARKER_FUNCTION)==bankMeta[readBank].boundRequest.markerType &&
                        markers[markerIndex].digit==bankMeta[readBank].boundRequest.digit) begin
                        processedObservation.matchCount<=processedObservation.matchCount+5'd1;
                        processedObservation.xMin<=markers[markerIndex].xMin;
                        processedObservation.xMax<=markers[markerIndex].xMax;
                        processedObservation.yMin<=markers[markerIndex].yMin;
                        processedObservation.yMax<=markers[markerIndex].yMax;
                        processedObservation.quality<=markers[markerIndex].quality;
                    end
                    if(!markers[markerIndex].isBlue && markers[markerIndex].digit==2)
                        red2Count<=red2Count+5'd1;
                end
                if(markers[markerIndex].accepted && !markers[markerIndex].isBlue && markers[markerIndex].digit==1) begin
                    referenceIndex<=0;aggregateState<=bankBypass[readBank]?AG_REFERENCE:AG_RED_READ;
                end else if(markerIndex==15) aggregateState<=AG_DONE;
                else markerIndex<=markerIndex+4'd1;
            end
            AG_RED_READ:aggregateState<=AG_RED_WAIT;
            AG_RED_WAIT:begin aggregateRedQuad<=geometryReadQuad;aggregateState<=AG_REFERENCE;end
            AG_REFERENCE: begin
                // A recognised blue bay cannot double as the red-1 reference,
                // even if an unusual scene makes its bbox match the geometry.
                // Only this actual unique pairing may receive the BJ label.
                if(bankColours[readBank][referenceIndex]&&!markers[referenceIndex].accepted&&
                   bankCandidates[readBank][referenceIndex].valid)begin
                    if(!bankBypass[readBank])aggregateState<=AG_BLUE_READ;
                    else if(referencePaired(markers[markerIndex],bankCandidates[readBank][referenceIndex],bankOrientation[readBank]))
                        aggregateState<=AG_PAIR;
                    else aggregateState<=AG_NEXT_REFERENCE;
                end else aggregateState<=AG_NEXT_REFERENCE;
            end
            AG_BLUE_READ:aggregateState<=AG_BLUE_WAIT;
            AG_BLUE_WAIT:begin aggregateBlueQuad<=geometryReadQuad;aggregateState<=AG_GEOMETRY_START;end
            AG_GEOMETRY_START:aggregateState<=AG_GEOMETRY_WAIT;
            AG_GEOMETRY_WAIT:if(geometryDone)aggregateState<=geometryPairValid?AG_PAIR:AG_NEXT_REFERENCE;
            AG_PAIR:begin
                    // Saturating uniqueness must not wrap back to one.
                    if(pairCount<2) pairCount<=pairCount+5'd1;
                    pairRed.valid<=1;
                    pairRed.xmin<=markers[markerIndex].xMin;pairRed.xmax<=markers[markerIndex].xMax;
                    pairRed.ymin<=markers[markerIndex].yMin;pairRed.ymax<=markers[markerIndex].yMax;
                    pairBlue<=bankCandidates[readBank][referenceIndex];
                    pairReferenceIndex<=referenceIndex;
                    pairQuality<=markers[markerIndex].quality;
                    pairRedPolygon<=bankBypass[readBank]?'0:geometryRedPolygon;
                    pairBluePolygon<=bankBypass[readBank]?'0:geometryBluePolygon;
                    aggregateState<=AG_NEXT_REFERENCE;
            end
            AG_NEXT_REFERENCE:begin
                if(referenceIndex==15) begin
                    if(markerIndex==15) aggregateState<=AG_DONE;
                    else begin markerIndex<=markerIndex+4'd1;aggregateState<=AG_MARKER;end
                end else begin referenceIndex<=referenceIndex+4'd1;aggregateState<=AG_REFERENCE;end
            end
            AG_DONE: aggregateState<=AG_IDLE;
            default: aggregateState<=AG_IDLE;
        endcase
    end
    logic collectEnable,calibrationAttempt,commitRequest,commitAck,calibrated,speechArmed,interactionBusy;
    logic commitConsumed;
    wire applyCommit=commitRequest&&!commitConsumed&&interactionEnable&&interactionPermit&&
        processingEnable&&activeProcessing&&activeBypass==bypassPerspective&&activeOrientation==orientationProfile;
    logic [3:0] sampleCount;
    logic [15:0] interactionId;
    interactionKind_t interactionKind;
    interactionState_t interactionState;
    assign debugInteractionArmReady=interactionEnable&&processingEnable&&activeProcessing&&
        (interactionState==INTERACTION_IDLE||interactionState==INTERACTION_SPEECH_ARMED);
    logic eventOverflow,samplerGood;
    logic [7:0] sampleRedMinimum,sampleBlueMinimum;
    logic [16:0] redSamples,blueSamples;
    logic bankSampling[0:1],bankSampleGood[0:1];
    logic [7:0] bankSampleRedMin[0:1],bankSampleBlueMin[0:1];
    logic [15:0] bankInteractionId[0:1];
    logic [16:0] bankRedSamples[0:1],bankBlueSamples[0:1];
    logic [16:0] lastSampleRedCount,lastSampleBlueCount;
    logic [15:0] lastSampleFrameId;
    logic [4:0] lastSampleChecks;
    userEvent_t lastConsumedEvent;
    logic haveConsumedEvent;
    // Diagnostic history is separate from valid/ready delivery: retaining an
    // accepted event never delivers it to C a second time.
    always_ff @(posedge clk) begin
        if(reset)begin lastConsumedEvent<='0;haveConsumedEvent<=0;end
        else if(userEventValid&&userEventReady)begin
            lastConsumedEvent<=userEvent;haveConsumedEvent<=1;
        end
    end
    logic [7:0] windowRedMaximum,windowBlueMaximum;
    // Samples are accepted only by the collection window that requested them.
    // A reader may finish an older bank after cancellation or another request.
    wire currentSample=aggregateAccepted&&bankSampling[readBank]&&collectEnable&&
        bankInteractionId[readBank]==interactionId&&
        processedObservation.configVersion==configVersion;
    wire sampleGeometryGood=stationary(pairRed,bankSampleRed[readBank])&&stationary(pairBlue,bankSampleBlue[readBank])&&
        bankSampleProjective[readBank]==!bankBypass[readBank]&&
        (bankBypass[readBank]||(polygonStationary(pairRedPolygon,bankRedPolygon[readBank])&&
                              polygonStationary(pairBluePolygon,bankBluePolygon[readBank])));
    wire sampleWindowGood=sampleCount==0||(
        int'(bankSampleRedMin[readBank])-int'(shadowRedMinimum)<=24&&
        int'(windowRedMaximum)-int'(bankSampleRedMin[readBank])<=24&&
        int'(bankSampleBlueMin[readBank])-int'(shadowBlueMinimum)<=24&&
        int'(windowBlueMaximum)-int'(bankSampleBlueMin[readBank])<=24);
    wire sampleGood=bankSampleGood[readBank]&&red1Paired&&processedObservation.frameGood&&
        sampleGeometryGood&&sampleWindowGood;
    // At SOF the active profile registers still contain the preceding frame.
    // A switch or commit must therefore suppress sampling explicitly; never
    // label old geometry with the newly committed configuration version.
    wire sampleRoiAvailable=roiValid&&lastFrameConfigVersion==configVersion&&!applyCommit&&
        activeBypass==bypassPerspective&&lastFrameBypass==bypassPerspective&&
        activeOrientation==orientationProfile&&lastFrameOrientation==orientationProfile;
    colourSampler sampler (.clk(clk),.reset(processingReset),.sof(sof),.pixelValid(processingPixelValid),.eop(pixelEop),
        .collectEnable(collectEnable),.roiValid(sampleRoiAvailable),.x(x),.y(y),.rgb(rgb),.orientation(activeOrientation),
        .redBox(lastPairRed),.blueBox(lastPairBlue),.frameSampleGood(samplerGood),.redMinimum(sampleRedMinimum),
        .blueMinimum(sampleBlueMinimum),.redSamples(redSamples),.blueSamples(blueSamples),
        .sampledRedBox(sampledRed),.sampledBlueBox(sampledBlue),
        .useProjective(!lastFrameBypass),.redPolygon(lastRedPolygon),.bluePolygon(lastBluePolygon),
        .sampledRedPolygon(sampledRedPolygon),.sampledBluePolygon(sampledBluePolygon),
        .sampledUseProjective(sampledProjective));
    fixedSheetInteraction interaction (.clk(clk),.reset(reset),.timeUs(timeUs),
        .enable(interactionEnable&&processingEnable&&activeProcessing),
        .permit(interactionPermit),.debugCalArm(debugCalArm&&debugInteractionArmReady),
        .debugSpeechArm(debugSpeechArm&&debugInteractionArmReady),
        .frameValid(aggregateAccepted),.frameGood(processedObservation.frameGood),.frameId(processedObservation.frameId),
        .configVersion(processedObservation.configVersion),.activeCfgVersion(configVersion),.red1Paired(red1Paired),
        .red2Seen(red2Seen),.sampleResultValid(currentSample),.sampleGood(sampleGood),
        .commitAck(commitAck),.commitVersion(configVersion),.collectEnable(collectEnable),.commitRequest(commitRequest),
        .calibrationAttempt(calibrationAttempt),.sampleCount(sampleCount),.calibrated(calibrated),.speechArmed(speechArmed),
        .busy(interactionBusy),.kind(interactionKind),.state(interactionState),.interactionId(interactionId),
        .userEvent(userEvent),.userEventValid(userEventValid),.userEventReady(userEventReady),.eventOverflow(eventOverflow));
    logic [15:0] faults,lastFrameId;
    logic [7:0] lastFrameRedMinimum,lastFrameBlueMinimum;
    logic haveFrame,lastFrameGood;
    logic [31:0] lastCompletionUs,lastCaptureUs;
    logic [4:0] lastRedCount,lastBlueCount;
    logic [3:0] lastPeakRed,lastPeakBlue;
    logic [2:0] lastCandidateFaults;
    always_ff @(posedge clk) begin
        if(reset)begin
            rowGuard<=0;activeRedMinimum<=48;activeBlueMinimum<=20;shadowRedMinimum<=255;shadowBlueMinimum<=255;
            windowRedMaximum<=0;windowBlueMaximum<=0;
            lastSampleRedCount<=0;lastSampleBlueCount<=0;lastSampleFrameId<=0;lastSampleChecks<=0;
            activeOrientation<=0;activeBypass<=0;lastFrameBypass<=0;configVersion<=0;commitAck<=0;commitConsumed<=0;writeBank<=0;haveWriteBank<=0;readBank<=0;readerStart<=0;
            activeProcessing<=1;rawFrameOpen<=0;lastFrameRaw<=0;
            lastCalibrationReferenceValid<=0;lastCalibrationReferenceIndex<=0;lastCalibrationReferenceQuality<=0;
            observationValid<=0;observation<='0;captureMeta<='0;bufferDropCount<=0;faults<=0;haveFrame<=0;lastCompletionUs<=0;
            lastMarkers<='0;lastFrameId<=0;lastCaptureUs<=0;lastRedCount<=0;lastBlueCount<=0;roiValid<=0;
            lastPairRed<='0;lastPairBlue<='0;completedFrame<=0;completedFrameId<=0;lastFrameGood<=0;
            lastRedPolygon<='0;lastBluePolygon<='0;
            lastPeakRed<=0;lastPeakBlue<=0;lastCandidateFaults<=0;
            lastFrameConfigVersion<=0;lastFrameOrientation<=0;
            lastFrameRedMinimum<=48;lastFrameBlueMinimum<=20;
            completionDiscardCount<=0;
            for(int i=0;i<2;i++)begin
                bankState[i]<=FREE;bankMeta[i]<='0;bankCandidates[i]<='0;bankColours[i]<=0;bankOrientation[i]<=0;
                bankBypass[i]<=0;
                bankRedMinimum[i]<=48;bankBlueMinimum[i]<=20;
                bankRedCount[i]<=0;bankBlueCount[i]<=0;bankPeakRed[i]<=0;bankPeakBlue[i]<=0;bankCandidateFaults[i]<=0;
                bankSampling[i]<=0;bankSampleGood[i]<=0;bankSampleRedMin[i]<=0;bankSampleBlueMin[i]<=0;
                bankInteractionId[i]<=0;bankRedSamples[i]<=0;bankBlueSamples[i]<=0;
                bankSampleRed[i]<='0;bankSampleBlue[i]<='0;
                bankRedPolygon[i]<='0;bankBluePolygon[i]<='0;bankSampleProjective[i]<=0;
            end
        end else begin
            readerStart<=0;observationValid<=0;commitAck<=0;completedFrame<=0;
            if(!commitRequest)commitConsumed<=0;
            if(rowGuard!=0)rowGuard<=rowGuard-9'd1;
            if(processingPixelValid&&x==319)rowGuard<=9'(ROW_GUARD);
            if(transportFault)faults[FAULT_CAMERA_TRANSPORT]<=1;
            if(requestInvalidFault)faults[FAULT_REQUEST_INVALID]<=1;
            if(calibrationAttempt)begin
                shadowRedMinimum<=255;shadowBlueMinimum<=255;
                windowRedMaximum<=0;windowBlueMaximum<=0;
            end
            if(currentSample)begin
                lastSampleFrameId<=processedObservation.frameId;
                lastSampleRedCount<=bankRedSamples[readBank];lastSampleBlueCount<=bankBlueSamples[readBank];
                lastSampleChecks<={sampleWindowGood,sampleGeometryGood,red1Paired,
                    processedObservation.frameGood,bankSampleGood[readBank]};
            end
            if(currentSample&&sampleGood&&!calibrationAttempt)begin
                if(bankSampleRedMin[readBank]<shadowRedMinimum)shadowRedMinimum<=bankSampleRedMin[readBank];
                if(bankSampleBlueMin[readBank]<shadowBlueMinimum)shadowBlueMinimum<=bankSampleBlueMin[readBank];
                if(bankSampleRedMin[readBank]>windowRedMaximum)windowRedMaximum<=bankSampleRedMin[readBank];
                if(bankSampleBlueMin[readBank]>windowBlueMaximum)windowBlueMaximum<=bankSampleBlueMin[readBank];
            end
            if(sof)begin
                // Revoke already visible in the commit domain wins this edge.
                if(applyCommit)begin
                    activeRedMinimum<=shadowRedMinimum;activeBlueMinimum<=shadowBlueMinimum;
                    configVersion<=configVersion+16'd1;commitAck<=1;commitConsumed<=1;
                end else if(activeOrientation!=orientationProfile||activeBypass!=bypassPerspective||processingModeChange)
                    configVersion<=configVersion+16'd1;
                activeProcessing<=processingEnable;rawFrameOpen<=!processingEnable;
                activeBypass<=bypassPerspective;
                activeOrientation<=orientationProfile;captureMeta<='0;
                captureMeta.boundRequest<=targetRequest_t'(streamData[50+:$bits(targetRequest_t)]);captureMeta.frameId<=streamData[49:34];
                captureMeta.captureStartUs<=streamData[33:2];
                captureMeta.configVersion<=configVersion+16'(applyCommit||activeOrientation!=orientationProfile||
                    activeBypass!=bypassPerspective||processingModeChange);
                captureMeta.frameGood<=processingEnable&&!streamData[78];
                if(processingModeChange)begin
                    // A stopped reader may still own either bank. Discard both
                    // ownership tokens before a fresh normal frame can claim
                    // bank0. No reset reaches the camera bridge or the tracker.
                    haveFrame<=0;roiValid<=0;rowGuard<=0;readerStart<=0;
                    haveWriteBank<=processingEnable;writeBank<=0;
                    for(int i=0;i<2;i++)begin
                        bankState[i]<=FREE;bankSampling[i]<=0;bankSampleGood[i]<=0;
                        bankCandidates[i]<='0;bankColours[i]<=0;bankRedCount[i]<=0;bankBlueCount[i]<=0;
                    end
                    if(processingEnable)begin
                        bankState[0]<=WRITING;bankOrientation[0]<=orientationProfile;
                        bankBypass[0]<=bypassPerspective;
                        bankRedMinimum[0]<=activeRedMinimum;bankBlueMinimum[0]<=activeBlueMinimum;
                        bankSampling[0]<=0;bankInteractionId[0]<=interactionId;
                    end
                end else if(!processingEnable)begin
                    haveWriteBank<=0;rowGuard<=0;roiValid<=0;
                end else if(abandonAtSof)begin
                    // A new SOF without a completed candidate packet abandons
                    // the truncated frame. Reclaim only its WRITING bank; READY
                    // and READING banks are never overwritten by this recovery.
                    observation<=captureMeta;observation.frameGood<=0;
                    observation.resourceDrop<=1;observationValid<=1;
                    bankOrientation[writeBank]<=orientationProfile;
                    bankBypass[writeBank]<=bypassPerspective;
                    bankRedMinimum[writeBank]<=applyCommit?shadowRedMinimum:activeRedMinimum;
                    bankBlueMinimum[writeBank]<=applyCommit?shadowBlueMinimum:activeBlueMinimum;
                    bankSampling[writeBank]<=collectEnable;
                    bankInteractionId[writeBank]<=interactionId;
                    if(bufferDropCount!=16'hffff)bufferDropCount<=bufferDropCount+16'd1;
                    faults[FAULT_CAMERA_TRANSPORT]<=1;
                end else if(bankState[0]==FREE||bankState[1]==FREE)begin
                    writeBank<=bankState[0]==FREE?1'b0:1'b1;haveWriteBank<=1;
                    bankState[bankState[0]==FREE?0:1]<=WRITING;bankOrientation[bankState[0]==FREE?0:1]<=orientationProfile;
                    bankBypass[bankState[0]==FREE?0:1]<=bypassPerspective;
                    bankRedMinimum[bankState[0]==FREE?0:1]<=applyCommit?shadowRedMinimum:activeRedMinimum;
                    bankBlueMinimum[bankState[0]==FREE?0:1]<=applyCommit?shadowBlueMinimum:activeBlueMinimum;
                    bankSampling[bankState[0]==FREE?0:1]<=collectEnable;
                    bankInteractionId[bankState[0]==FREE?0:1]<=interactionId;
                end else begin
                    haveWriteBank<=0;captureMeta.resourceDrop<=1;
                    if(bufferDropCount!=16'hffff)bufferDropCount<=bufferDropCount+16'd1;
                    faults[FAULT_MASK_BUFFER_OVERRUN]<=1;
                end
            end
            if(candidateValid&&activeProcessing&&!processingModeChange)begin
                if(candidateOverflow)faults[FAULT_CANDIDATE_OVERFLOW]<=1;
                if(haveWriteBank)begin
                    bankMeta[writeBank]<=captureMeta;bankMeta[writeBank].frameGood<=captureMeta.frameGood&&candidateGood&&!candidateOverflow;
                    bankCandidates[writeBank]<=sharedCandidates;bankColours[writeBank]<=sharedColours;bankState[writeBank]<=READY;
                    // Diagnostics travel with the same owned bank as its image.
                    bankRedCount[writeBank]<=redCount;bankBlueCount[writeBank]<=blueCount;
                    bankPeakRed[writeBank]<=allocationPeakRed;bankPeakBlue[writeBank]<=allocationPeakBlue;
                    bankCandidateFaults[writeBank]<={candidateOverflow,candidateError,candidateOverrun};
                    // A simultaneous SOF may already have claimed the other bank.
                    if(!sof)haveWriteBank<=0;
                    bankRedSamples[writeBank]<=redSamples;bankBlueSamples[writeBank]<=blueSamples;
                    bankSampleGood[writeBank]<=samplerGood;bankSampleRedMin[writeBank]<=sampleRedMinimum;
                    bankSampleBlueMin[writeBank]<=sampleBlueMinimum;bankSampleRed[writeBank]<=sampledRed;bankSampleBlue[writeBank]<=sampledBlue;
                    bankRedPolygon[writeBank]<=sampledRedPolygon;bankBluePolygon[writeBank]<=sampledBluePolygon;
                    bankSampleProjective[writeBank]<=sampledProjective;
                end else begin
                    observation<=captureMeta;observation.resourceDrop<=1;observation.frameGood<=0;observationValid<=1;
                end
            end
            if(activeProcessing&&processingEnable&&!processingModeChange&&!readerBusy&&!readerStart&&!readerDone&&
                aggregateState==AG_IDLE&&(bankState[0]==READY||bankState[1]==READY))begin
                readBank<=bankState[0]==READY?1'b0:1'b1;bankState[bankState[0]==READY?0:1]<=READING;readerStart<=1;
            end
            if(aggregateDone&&activeProcessing&&!processingModeChange)begin
                // Release the old reader even if its result loses arbitration.
                // Snapshot publication and calibration must use the same
                // accepted result as the report; never attach old good marker
                // words to the newer dropped frame's observation.
                bankState[readBank]<=FREE;
                if(captureDropNow&&completionDiscardCount!=16'hffff)
                    completionDiscardCount<=completionDiscardCount+16'd1;
            end
            if(aggregateAccepted)begin
                observation<=processedObservation;observationValid<=1;
                // The reference is recognised by unique ownership/geometry,
                // not by inventing a seventh digit. Its confidence is the
                // associated red1 digit confidence, explicitly documented.
                if(processedObservation.boundRequest.markerType==MARKER_REFERENCE&&
                   processedObservation.boundRequest.digit==4'hf&&red1Paired)begin
                    observation.matchCount<=1;observation.xMin<=pairBlue.xmin;observation.xMax<=pairBlue.xmax;
                    observation.yMin<=pairBlue.ymin;observation.yMax<=pairBlue.ymax;observation.quality<=pairQuality;
                end
                lastMarkers<=markers;lastFrameId<=processedObservation.frameId;lastCaptureUs<=processedObservation.captureStartUs;
                lastCompletionUs<=timeUs;haveFrame<=1;completedFrame<=1;completedFrameId<=processedObservation.frameId;
                lastFrameGood<=processedObservation.frameGood;
                lastFrameConfigVersion<=processedObservation.configVersion;
                lastFrameOrientation<=bankOrientation[readBank];
                lastFrameBypass<=bankBypass[readBank];
                lastFrameRaw<=0;
                lastCalibrationReferenceValid<=red1Paired&&processedObservation.frameGood;
                lastCalibrationReferenceIndex<=red1Paired&&processedObservation.frameGood?pairReferenceIndex:4'd0;
                lastCalibrationReferenceQuality<=red1Paired&&processedObservation.frameGood?pairQuality:8'd0;
                lastFrameRedMinimum<=bankRedMinimum[readBank];lastFrameBlueMinimum<=bankBlueMinimum[readBank];
                lastRedCount<=bankRedCount[readBank];lastBlueCount<=bankBlueCount[readBank];
                lastPeakRed<=bankPeakRed[readBank];lastPeakBlue<=bankPeakBlue[readBank];
                lastCandidateFaults<=bankCandidateFaults[readBank];
                roiValid<=red1Paired&&processedObservation.frameGood;lastPairRed<=pairRed;lastPairBlue<=pairBlue;
                lastRedPolygon<=pairRedPolygon;lastBluePolygon<=pairBluePolygon;
            end
            if(!activeProcessing&&rawFrameOpen&&pixelEop)begin
                // GRAB still receives a new, immutable result token for each
                // raw frame. Invalid/empty recognition is intentional here,
                // not evidence that the camera transport failed. SOF metadata
                // and native frame identity continue through the same FIFO.
                rawFrameOpen<=0;observation<=captureMeta;observationValid<=1;
                observation.frameGood<=0;observation.matchCount<=0;
                lastMarkers<='0;lastRedCount<=0;lastBlueCount<=0;lastPeakRed<=0;lastPeakBlue<=0;
                lastCandidateFaults<=0;lastFrameGood<=0;lastFrameRaw<=1;
                lastCalibrationReferenceValid<=0;lastCalibrationReferenceIndex<=0;lastCalibrationReferenceQuality<=0;
                lastFrameId<=captureMeta.frameId;lastCaptureUs<=captureMeta.captureStartUs;
                lastFrameConfigVersion<=captureMeta.configVersion;
                lastFrameOrientation<=activeOrientation;lastFrameBypass<=activeBypass;
                lastFrameRedMinimum<=activeRedMinimum;lastFrameBlueMinimum<=activeBlueMinimum;
                lastCompletionUs<=timeUs;completedFrame<=1;completedFrameId<=captureMeta.frameId;
            end
        end
    end
    always_comb begin
        status='0;status.interactionBusy=interactionBusy;status.kind=interactionKind;status.state=interactionState;
        status.calibrated=calibrated;status.audioReady=0;
        status.perceptionReady=processingEnable&&activeProcessing&&haveFrame&&freshTime(timeUs,lastCompletionUs,32'd150000);
        status.activeCfgVersion=configVersion;status.reportDropCount=reportDropCount;status.eventOverflow=eventOverflow;
        status.faultFlags=faults;status.interactionId=interactionId;status.speechArmed=speechArmed;
        debugWords='0;
        debugWords[0*32+:32]=32'h45425031;
        debugWords[1*32+:32]={16'(DEBUG_SCHEMA_VERSION),16'(PERCEPTION_CONTRACT_VERSION)};
        debugWords[2*32+:32]=timeUs;debugWords[3*32+:32]={16'd0,lastFrameId};debugWords[4*32+:32]=lastCaptureUs;
        debugWords[5*32+:32]=lastCompletionUs;debugWords[6*32+:32]={16'd0,lastFrameConfigVersion};
        debugWords[7*32+:32]={10'd0,lastFrameRaw,lastFrameBypass,lastFrameOrientation,2'd0,lastFrameRedMinimum,lastFrameBlueMinimum};
        debugWords[8*32+:32]={16'd0,bufferDropCount};debugWords[9*32+:32]={22'd0,lastBlueCount,lastRedCount};
        debugWords[10*32+:76]=status;debugWords[13*32+:$bits(targetReport_t)]=targetReport;debugWords[18*32+:104]=userEventValid?userEvent:lastConsumedEvent;
        debugWords[22*32+:32]={15'd0,lastSampleRedCount};debugWords[23*32+:32]={15'd0,lastSampleBlueCount};
        for(int i=0;i<DEBUG_MARKER_COUNT;i++)begin
            debugWords[(24+i*4)*32+:32]={lastMarkers[i].accepted,lastMarkers[i].isBlue,lastMarkers[i].orientation,
                lastMarkers[i].digit,lastMarkers[i].quality,lastMarkers[i].reason,1'b0,lastMarkers[i].segments};
            debugWords[(25+i*4)*32+:32]={7'd0,lastMarkers[i].xMin,7'd0,lastMarkers[i].xMax};
            debugWords[(26+i*4)*32+:32]={8'd0,lastMarkers[i].yMin,8'd0,lastMarkers[i].yMax};
        end
        debugWords[(DEBUG_TAIL_BASE+0)*32+:32]={8'd0,activeRequest};
        debugWords[(DEBUG_TAIL_BASE+1)*32+:32]={lastSampleFrameId,3'd0,lastSampleChecks,4'd0,sampleCount};
        debugWords[(DEBUG_TAIL_BASE+2)*32+:32]={15'd0,queryBusy,lastCalibrationReferenceQuality,lastCalibrationReferenceIndex,lastCalibrationReferenceValid,
            haveConsumedEvent&&!userEventValid,targetReportValid,userEventValid};
        debugWords[(DEBUG_TAIL_BASE+3)*32+:32]={31'd0,lastFrameGood};
        // Schema7 high byte1 identifies a total shared pool, not per-colour
        // capacity. Counts and each marker's explicit isBlue remain separate.
        debugWords[(DEBUG_TAIL_BASE+5)*32+:32]={8'd1,8'(OUTPUT_CAPACITY),8'(ACTIVE_CAPACITY),lastPeakBlue,lastPeakRed};
        debugWords[(DEBUG_TAIL_BASE+6)*32+:32]={completionDiscardCount,12'd0,transportFault,lastCandidateFaults};
        debugWords[(DEBUG_TAIL_BASE+7)*32+:32]={8'd3,8'd9,8'(WHITE_LUMA_QUARTER),8'd64};
    end
endmodule
