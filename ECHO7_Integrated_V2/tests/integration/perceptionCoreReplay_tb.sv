`timescale 1ns/1ps
// Synthetic RGB565 by default, or explicitly selected recorded-camera pixels,
// replayed at the post-capture pixel interface. The 320x240
// fixture is expanded to even 640x480 coordinates with sensor-like idle cycles.
// This does not exercise a live OV7670 byte stream or microphone chain.
module perceptionCoreReplay_tb;
    // CLOCK_50 is 20 ns; PCLK is 50 ns. The post-capture source emits only
    // retained even rows. A real 640x480 sensor also spends time on discarded
    // odd rows: normal source SOFs are therefore explicitly 40 ms apart. The
    // old 343218-PCLK cadence remains an intentional 17.1609 ms overload test.
    localparam integer NORMAL_FRAME_PCLK=800000, OVERLOAD_FRAME_PCLK=343218;
    localparam integer SOURCE_BODY_PCLK=343210;
    localparam integer PROCESSING_BUDGET_CYCLES=2000000; // 40 ms, not an observed latency claim.
    localparam integer MAX_REPLAY_FRAMES=43;
    localparam time GLOBAL_TIMEOUT_NS=MAX_REPLAY_FRAMES*(40000000+40000000)+100000000;
    logic bypassPerspective=0;
    logic processingEnable=1;
    import perception_pkg::*;
    logic clk=0,pclk=0,reset=1,resetPclk=1;
    always #10 clk=~clk;
    initial begin #7;forever #25 pclk=~pclk;end
    logic cameraFrameStart=0,cameraPixelValid=0;
    logic [15:0] cameraPixel=0;
    logic [9:0] cameraX=0;
    logic [8:0] cameraY=0;
    logic [31:0] timeUs=0;
    logic interactionEnable=1,interactionPermit=1,debugCalArm=0,debugSpeechArm=0;
    logic [1:0] orientationProfile=0;
    targetRequest_t targetRequest;
    logic targetRequestValid=0,targetRequestReady;
    targetReport_t targetReport,lastReport;
    logic targetReportValid,targetReportReady=1;
    userEvent_t userEvent;
    userEvent_t consumedEvent;
    logic userEventValid,userEventReady=1;
    perceptionStatus_t status;
    logic [DEBUG_WORD_COUNT*32-1:0] debugWords;
    logic completedFrame;
    logic [15:0] completedFrameId;
    logic [15:0] pixels[0:76799];
    logic [7:0] normalU[1:6];
    logic [8:0] normalV[1:6];
    integer microDivider=0,reportCount=0,frameNumber=0,eventCount=0;
    integer expectedReportCount,expectedBufferDrops=0;
    logic continuousMode=0,overloadMode=0,haveStalledHead=0;
    targetReport_t stalledHead;
    candidate_pkg::candidate_t expectedBlueBoxes[0:1],continuousExpectedBox;
    logic [68:0] continuousCandidateWords[0:15];
    logic [31:0] continuousExpectedWords[0:15];
    logic continuousCandidateColours[0:15];
    integer continuousObserved=0,overlapCycles=0,totalCycles=0,continuousStart=0;
    integer sourceFrameCount=0,sourceDropCount=0,badObservationCount=0,staleObservationCount=0;
    integer recoveryFirstFrame=0,recoveryObservations=0,maximumProcessingCycles=0;
    logic sourceDropped[1:16],sourceCandidatesDone[1:16],sourceObserved[1:16];
    integer sourceWrites[1:16],sourceReaderStarts[1:16],readerStartCycle[1:16];
    targetRequest_t sourceRequest[1:16];
    logic [31:0] sourceCaptureUs[1:16];
    integer bankOwner[0:1];
    time previousSourceSof=0;
    integer previousSourcePeriod=0;
    frameObservation_t collisionGood,collisionDrop;
    string vectorDir,sceneFile;
    logic debugInteractionArmReady;
    queryResult_t queryResult;
    logic queryResultValid,queryResultReady=1,queryBusy;
    perceptionCore dut(.*);
    always @(posedge clk) begin
        if(reset) begin microDivider<=0;timeUs<=0;end
        else begin
            totalCycles++;
            if(microDivider==49)begin microDivider<=0;timeUs<=timeUs+1;end
            else microDivider<=microDivider+1;
            if(targetReportValid&&targetReportReady)begin
                lastReport=targetReport;reportCount++;
                $display("CORE_FRAME id=%0d tag=%0d cfg=%0d good=%0d observed=%0d locked=%0d reason=%0d centre=%0d,%0d samples=%0d state=%0d",
                    targetReport.frameId,targetReport.requestTag,targetReport.configVersion,targetReport.frameGood,
                    targetReport.observed,targetReport.locked,targetReport.reason,targetReport.centreU,targetReport.centreV,
                    dut.sampleCount,status.state);
            end
            if(userEventValid&&userEventReady)begin
                consumedEvent=userEvent;
                eventCount++;
                if(userEvent.eventType!=EVENT_CALIBRATION_DONE)
                    $fatal(1,"full sheet calibration failed event=%0d reason=%0d samples=%0d",userEvent.eventType,userEvent.reason,dut.sampleCount);
            end
            if(continuousMode)begin
                // Admission is decided once at SOF. A busy pool must discard
                // the complete frame, even when a bank becomes free mid-frame.
                if(dut.sof)begin
                    integer id;
                    id=int'(dut.streamData[49:34]);sourceFrameCount++;
                    if(id!=sourceFrameCount||id>16)$fatal(1,"Unexpected source identity id=%0d",id);
                    sourceRequest[id]=targetRequest_t'(dut.streamData[50+:$bits(targetRequest_t)]);
                    sourceCaptureUs[id]=dut.streamData[33:2];
                    sourceDropped[id]=dut.bankState[0]!=dut.FREE&&dut.bankState[1]!=dut.FREE;
                    if(sourceDropped[id])sourceDropCount++;
                    else bankOwner[dut.bankState[0]==dut.FREE?0:1]=id;
                    $display("SOURCE_SOF id=%0d timeUs=%0d states=%0d,%0d rejected=%0d readerBusy=%0d",
                        id,timeUs,dut.bankState[0],dut.bankState[1],sourceDropped[id],dut.readerBusy);
                end
                if(dut.glyphMemory.writeEnable)begin
                    integer id;
                    id=int'(dut.captureMeta.frameId);
                    if(id<1||id>sourceFrameCount||sourceDropped[id]||
                       dut.bankState[dut.writeBank]!=dut.WRITING||bankOwner[dut.writeBank]!=id)
                        $fatal(1,"Write without complete-frame ownership id=%0d",id);
                    if(dut.glyphMemory.writeAddress!=sourceWrites[id])
                        $fatal(1,"Skipped/duplicate glyph write id=%0d address=%0d expected=%0d",id,dut.glyphMemory.writeAddress,sourceWrites[id]);
                    sourceWrites[id]++;
                end
                if(dut.candidateValid)begin
                    integer id;
                    id=int'(dut.captureMeta.frameId);
                    if(sourceCandidatesDone[id]||sourceWrites[id]!=(sourceDropped[id]?0:76800))
                        $fatal(1,"Frame was partly written or candidate completion duplicated id=%0d writes=%0d",id,sourceWrites[id]);
                    sourceCandidatesDone[id]=1;
                    if(dut.candidateOverflow||dut.candidateOverrun||!dut.candidateGood||dut.transportFault)
                        $fatal(1,"Overload source exceeded row/transport capacity instead of only bank capacity");
                end
                if(dut.readerStart)begin
                    integer id;
                    id=int'(dut.bankMeta[dut.readBank].frameId);
                    if(sourceDropped[id]||!sourceCandidatesDone[id]||sourceWrites[id]!=76800||
                       dut.bankState[dut.readBank]!=dut.READING||bankOwner[dut.readBank]!=id)
                        $fatal(1,"Reader started on unowned/incomplete/dropped frame id=%0d",id);
                    sourceReaderStarts[id]++;readerStartCycle[id]=totalCycles;
                    if(sourceReaderStarts[id]!=1)$fatal(1,"Reader started twice on frame %0d",id);
                end
                if((dut.readerBusy||dut.aggregateState!=0)&&dut.haveWriteBank)begin
                    overlapCycles++;
                    if(dut.readBank==dut.writeBank)$fatal(1,"Reading bank overwritten by the next captured frame");
                end
                if(targetReportValid&&!targetReportReady)begin
                    if(!haveStalledHead)begin stalledHead=targetReport;haveStalledHead=1;end
                    else if(targetReport!==stalledHead)$fatal(1,"Presented report changed during continuous capture stall");
                end
                if(dut.observationValid)begin
                    integer id,processingCycles;
                    id=int'(dut.observation.frameId);
                    continuousObserved++;
                    if(id<1||id>sourceFrameCount||sourceObserved[id]||!sourceCandidatesDone[id]||
                       dut.observation.boundRequest!==sourceRequest[id]||dut.observation.captureStartUs!=sourceCaptureUs[id]||
                       dut.observation.configVersion!=0||dut.observation.resourceDrop!=sourceDropped[id])
                        $fatal(1,"Continuous source/observation identity mismatch id=%0d",id);
                    sourceObserved[id]=1;
                    if(!overloadMode&&(id!=continuousObserved||!dut.observation.frameGood||sourceDropped[id]))
                        $fatal(1,"Normal 40 ms source must not drop/reorder frames id=%0d",id);
                    if(sourceDropped[id])begin
                        badObservationCount++;
                        if(dut.observation.frameGood||dut.observation.matchCount||sourceReaderStarts[id]||
                           dut.tracker.newReport.reason!=REPORT_RESOURCE_DROP)
                            $fatal(1,"Rejected whole frame became a valid observation id=%0d",id);
                    end else begin
                        processingCycles=totalCycles-readerStartCycle[id];
                        if(processingCycles>PROCESSING_BUDGET_CYCLES)
                            $fatal(1,"Reader/aggregation processing exceeded explicit 40 ms budget id=%0d cycles=%0d",id,processingCycles);
                        if(processingCycles>maximumProcessingCycles)maximumProcessingCycles=processingCycles;
                        if(!dut.observation.frameGood||dut.observation.matchCount!=1||sourceReaderStarts[id]!=1)
                            $fatal(1,"Accepted frame did not produce one real blue1 observation id=%0d",id);
                        continuousExpectedBox=expectedBlueBoxes[id%2?0:1];
                        if({dut.observation.xMin,dut.observation.xMax,dut.observation.yMin,dut.observation.yMax}!==
                           {continuousExpectedBox.xmin,continuousExpectedBox.xmax,continuousExpectedBox.ymin,continuousExpectedBox.ymax})
                            $fatal(1,"Same-frame glyph bank mismatch id=%0d",id);
                    end
                    // The tracker also rejects an older completed bank after a
                    // newer dropped frame. It must never expose old geometry as
                    // a current observation or count it towards confirmation.
                    if(!dut.tracker.newReport.frameGood||!dut.tracker.newReport.observed)begin
                        if(dut.tracker.newReport.observed||dut.tracker.newReport.locked||
                           dut.tracker.newReport.centreU||dut.tracker.newReport.centreV||
                           dut.tracker.newReport.boxWidth||dut.tracker.newReport.boxHeight||dut.tracker.newReport.quality)
                            $fatal(1,"Invalid/stale frame exposed public measurement id=%0d",id);
                        if(!sourceDropped[id]&&!dut.tracker.newSequence)staleObservationCount++;
                    end
                    if(recoveryFirstFrame!=0&&id>=recoveryFirstFrame)begin
                        recoveryObservations++;
                        if(id!=recoveryFirstFrame+recoveryObservations-1||sourceDropped[id]||
                           dut.observation.boundRequest.requestTag!=2||!dut.tracker.newReport.observed||
                           dut.tracker.newReport.locked!=(recoveryObservations==3))
                            $fatal(1,"Recovery must confirm three distinct new frames id=%0d n=%0d",id,recoveryObservations);
                    end
                    $display("SOURCE_RESULT id=%0d good=%0d drop=%0d publicObserved=%0d locked=%0d reason=%0d writes=%0d",
                        id,dut.observation.frameGood,sourceDropped[id],dut.tracker.newReport.observed,
                        dut.tracker.newReport.locked,dut.tracker.newReport.reason,sourceWrites[id]);
                end
            end
        end
    end
    task automatic selectBay(input integer bay,input integer tag);
        @(negedge clk);targetRequest.operation=TARGET_SELECT;targetRequest.markerType=MARKER_BAY;targetRequest.digit=bay;
        targetRequest.requestTag=tag;targetRequestValid=1;
        do @(posedge clk);while(!targetRequestReady);
        @(negedge clk);targetRequestValid=0;
        // Settle the held-word request CDC before the next actual source SOF.
        repeat(20)@(negedge pclk);
    endtask
    task automatic frame;
        integer timeoutCount;
        expectedReportCount=reportCount+1;frameNumber++;
        @(negedge pclk);cameraFrameStart=1;
        @(negedge pclk);cameraFrameStart=0;
        repeat(8)@(negedge pclk);
        for(int py=0;py<240;py++)begin
            for(int px=0;px<320;px++)begin
                cameraX=px*2;cameraY=py*2;cameraPixel=pixels[py*320+px];cameraPixelValid=1;
                @(negedge pclk);cameraPixelValid=0;
                repeat(3)@(negedge pclk);
            end
            // Explicit horizontal idle budget, larger than active-CAP15's 335 CLOCK_50
            // maintenance clocks; continuous zero-gap fake pixels are not used.
            repeat(150)@(negedge pclk);
        end
        timeoutCount=0;
        while((reportCount<expectedReportCount||lastReport.frameId!=frameNumber)&&timeoutCount<PROCESSING_BUDGET_CYCLES)begin
            @(negedge clk);timeoutCount++;
        end
        if(reportCount<expectedReportCount)$fatal(1,"core completed-frame timeout frame=%0d",frameNumber);
        if(lastReport.frameId!=frameNumber)$fatal(1,"candidate/glyph frame identity drift");
        if(!lastReport.frameGood)$fatal(1,"synthetic transport/candidate failure flags=%h",status.faultFlags);
        if(dut.bufferDropCount!=expectedBufferDrops||dut.candidateOverflow||dut.candidateOverrun||dut.transportFault)
            $fatal(1,"unexpected full-sheet capacity/transport fault");
    endtask
    task automatic truncatedFrame;
        // Deliberately end after a short first-row prefix. The following SOF must
        // report its loss and reuse its WRITING bank without touching a reader.
        frameNumber++;
        @(negedge pclk);cameraFrameStart=1;
        @(negedge pclk);cameraFrameStart=0;
        repeat(8)@(negedge pclk);
        for(int px=0;px<4;px++)begin
            cameraX=2*px;cameraY=0;cameraPixel=pixels[px];cameraPixelValid=1;
            @(negedge pclk);cameraPixelValid=0;repeat(3)@(negedge pclk);
        end
        repeat(200)@(negedge clk);
    endtask
    task automatic continuousSourceFrame(input integer periodPclk);
        frameNumber++;
        @(negedge pclk);cameraFrameStart=1;
        if(previousSourceSof!=0&&$time-previousSourceSof!=time'(previousSourcePeriod)*50)
            $fatal(1,"Source SOF period changed independently of configured cadence");
        previousSourceSof=$time;previousSourcePeriod=periodPclk;
        @(negedge pclk);cameraFrameStart=0;
        repeat(8)@(negedge pclk);
        for(int py=0;py<240;py++)begin
            for(int px=0;px<320;px++)begin
                cameraX=px*2;cameraY=py*2;cameraPixel=pixels[py*320+px];cameraPixelValid=1;
                @(negedge pclk);cameraPixelValid=0;repeat(3)@(negedge pclk);
            end
            repeat(150)@(negedge pclk);
        end
        // No wait for reader, completedFrame or report. Normal timing models
        // omitted odd sensor rows as end-of-frame idle; the overload variant
        // intentionally removes this time while preserving every row budget.
        if(periodPclk<SOURCE_BODY_PCLK)$fatal(1,"Source period shorter than explicit pixel/row stimulus");
        repeat(periodPclk-SOURCE_BODY_PCLK)@(negedge pclk);
    endtask
    // Deliberate protocol fault injection, separate from every pixel replay mode.
    // It controls the exact completion/drop edge without claiming visual input
    // recognition. Normal core replay independently validates the pixel path.
    task automatic prepareInjectedGood(input integer id);
        collisionGood='0;
        collisionGood.boundRequest=targetRequest;
        collisionGood.frameId=16'(id);collisionGood.captureStartUs=timeUs;
        collisionGood.configVersion=0;collisionGood.frameGood=1;
        collisionGood.matchCount=1;collisionGood.xMin=100;collisionGood.xMax=130;
        collisionGood.yMin=40;collisionGood.yMax=90;collisionGood.quality=192;
    endtask
    task automatic awaitInjectedReport(input integer wantedCount);
        integer waitCycles;
        begin
            waitCycles=0;
            while(reportCount<wantedCount&&waitCycles<20)begin @(negedge clk);waitCycles++;end
            if(reportCount!=wantedCount)$fatal(1,"Protocol injection report missing/duplicated");
        end
    endtask
    task automatic injectGoodCompletion(input integer id,input bit shouldLock);
        integer wantedCount;
        begin
            wantedCount=reportCount+1;
            @(negedge clk);prepareInjectedGood(id);
            dut.bankState[0]=dut.READING;
            force dut.aggregateDone=1'b1;
            @(negedge clk);force dut.aggregateDone=1'b0;
            awaitInjectedReport(wantedCount);
            if(lastReport.frameId!=id||!lastReport.observed||lastReport.locked!=shouldLock)
                $fatal(1,"Protocol injection confirmation sequence id=%0d expectedLock=%0d",id,shouldLock);
        end
    endtask
    task automatic injectCompletionDropCollision(input integer oldId,input bit truncated,input integer discarded);
        integer wantedCount;
        logic [15:0] previouslyCompleted;
        logic [DEBUG_WORD_COUNT*32-1:0] previousDebug;
        begin
            wantedCount=reportCount+1;previouslyCompleted=completedFrameId;previousDebug=debugWords;
            @(negedge clk);prepareInjectedGood(oldId);
            collisionDrop=collisionGood;collisionDrop.frameId=16'(oldId+1);
            dut.bankState[0]=dut.READING;
            if(truncated)begin
                dut.bankState[1]=dut.WRITING;
                force dut.haveWriteBank=1'b1;
                force dut.sof=1'b1;
            end else begin
                force dut.haveWriteBank=1'b0;
                force dut.candidateValid=1'b1;
            end
            force dut.aggregateDone=1'b1;
            @(posedge clk);#1;
            if(completedFrame||completedFrameId!=previouslyCompleted||dut.bankState[0]!=dut.FREE)
                $fatal(1,"Discarded completion published or did not release READING bank");
            if(debugWords[3*32+:32]!==previousDebug[3*32+:32]||
               debugWords[24*32+:2048]!==previousDebug[24*32+:2048])
                $fatal(1,"Discarded completion replaced snapshot frame identity/marker words");
            if(dut.completionDiscardCount!=discarded||debugWords[(DEBUG_TAIL_BASE+6)*32+16+:16]!=discarded)
                $fatal(1,"Completion-discard diagnostic missing");
            @(negedge clk);
            force dut.aggregateDone=1'b0;force dut.sof=1'b0;
            force dut.candidateValid=1'b0;force dut.haveWriteBank=1'b0;
            dut.bankState[1]=dut.FREE;
            awaitInjectedReport(wantedCount);
            if(lastReport.frameId!=oldId+1||lastReport.reason!=REPORT_RESOURCE_DROP||
               lastReport.frameGood||lastReport.observed||lastReport.locked||
               lastReport.centreU||lastReport.centreV||lastReport.boxWidth||lastReport.boxHeight||lastReport.quality)
                $fatal(1,"New drop did not immediately replace old good completion with cleared measurement");
            repeat(3)@(negedge clk);
            if(reportCount!=wantedCount)$fatal(1,"Old completion escaped after drop arbitration");
        end
    endtask
    task automatic collisionRegression;
        begin
            interactionEnable=0;selectBay(3,1);
            force dut.processedObservation=collisionGood;
            force dut.captureMeta=collisionDrop;
            force dut.aggregateDone=1'b0;force dut.sof=1'b0;force dut.candidateValid=1'b0;
            force dut.readBank=1'b0;force dut.writeBank=1'b1;force dut.haveWriteBank=1'b0;
            injectGoodCompletion(1,0);injectGoodCompletion(2,0);injectGoodCompletion(3,1);
            injectCompletionDropCollision(4,1,1);
            injectGoodCompletion(6,0);injectGoodCompletion(7,0);injectGoodCompletion(8,1);
            injectCompletionDropCollision(9,0,2);
            injectGoodCompletion(11,0);injectGoodCompletion(12,0);injectGoodCompletion(13,1);
            if(reportCount!=11||dut.completionDiscardCount!=2||dut.bufferDropCount!=1)
                $fatal(1,"Collision regression accounting mismatch");
            $display("PASS perceptionCoreCollision_tb collisions=2 reports=11 source=PROTOCOL_FAULT_INJECTION");
        end
    endtask
    initial begin
        targetRequest='0;lastReport='0;
        bankOwner[0]=0;bankOwner[1]=0;
        for(int id=1;id<=16;id++)begin
            sourceDropped[id]=0;sourceCandidatesDone[id]=0;sourceObserved[id]=0;
            sourceWrites[id]=0;sourceReaderStarts[id]=0;readerStartCycle[id]=0;
            sourceRequest[id]='0;sourceCaptureUs[id]=0;
        end
        if(!$value$plusargs("VECTOR_DIR=%s",vectorDir))vectorDir="vectors";
        if(!$test$plusargs("COLLISION_ONLY"))begin
            if($test$plusargs("CONTINUOUS"))$readmemh({vectorDir,"/continuous_0_rgb565.hex"},pixels);
            else $readmemh({vectorDir,"/vision_0_rgb565.hex"},pixels);
            if($value$plusargs("SCENE_FILE=%s",sceneFile))$readmemh(sceneFile,pixels);
            else if($test$plusargs("REAL_FRAME_REPEAT"))
                $fatal(1,"Recorded replay requires an explicitly bound SCENE_FILE");
        end
        repeat(10)@(negedge pclk);reset=0;resetPclk=0;
        if($test$plusargs("COLLISION_ONLY"))begin collisionRegression();$finish;end
        if($test$plusargs("CONTINUOUS"))begin
            interactionEnable=0;targetReportReady=0;
            expectedBlueBoxes[0]='0;expectedBlueBoxes[1]='0;
            // Each independent projective fixture includes the actual HSV +
            // horizontal-run + causal-cleanup candidate oracle. The older
            // vision vectors contain uncleaned, axis-aligned classifier boxes.
            // Read blue 1 separately from each image's pixel-derived expected
            // result; do not assume swapping glyphs preserves the other bbox.
            for(int fixture=0;fixture<2;fixture++)begin
                integer blueOneCount;
                blueOneCount=0;
                $readmemh($sformatf("%s/continuous_%0d_candidates.hex",vectorDir,fixture),continuousCandidateWords);
                $readmemh($sformatf("%s/continuous_%0d_expected.hex",vectorDir,fixture),continuousExpectedWords);
                $readmemh($sformatf("%s/continuous_%0d_candidate_colours.hex",vectorDir,fixture),continuousCandidateColours);
                for(int slot=0;slot<16;slot++)if(continuousCandidateColours[slot]&&continuousExpectedWords[slot][24]&&continuousExpectedWords[slot][19:16]==1)begin
                    expectedBlueBoxes[fixture]=continuousCandidateWords[slot];blueOneCount++;
                end
                if(blueOneCount!=1||!expectedBlueBoxes[fixture].valid)
                    $fatal(1,"Expected exactly one independent blue1 bbox in projective fixture %0d",fixture);
            end
            if(expectedBlueBoxes[0].xmin==expectedBlueBoxes[1].xmin&&
               expectedBlueBoxes[0].xmax==expectedBlueBoxes[1].xmax&&
               expectedBlueBoxes[0].ymin==expectedBlueBoxes[1].ymin&&
               expectedBlueBoxes[0].ymax==expectedBlueBoxes[1].ymax)
                $fatal(1,"Continuous fixtures must place blue1 at different pixel-derived positions");
            selectBay(1,1);continuousMode=1;continuousStart=totalCycles;
            overloadMode=$test$plusargs("OVERLOAD");
            for(int n=1;n<=6;n++)begin
                if(n%2)$readmemh({vectorDir,"/continuous_0_rgb565.hex"},pixels);
                else $readmemh({vectorDir,"/continuous_1_rgb565.hex"},pixels);
                continuousSourceFrame(overloadMode?OVERLOAD_FRAME_PCLK:NORMAL_FRAME_PCLK);
            end
            if(overloadMode)begin
                // Resume a 40 ms source immediately, without draining banks or
                // waiting for a report. Two ordinary source periods allow the
                // one-reader/one-ready backlog to finish within its 40 ms bound.
                // The held frame1 report remains stalled throughout this phase.
                for(int n=7;n<=8;n++)begin
                    if(n%2)$readmemh({vectorDir,"/continuous_0_rgb565.hex"},pixels);
                    else $readmemh({vectorDir,"/continuous_1_rgb565.hex"},pixels);
                    continuousSourceFrame(NORMAL_FRAME_PCLK);
                end
                // A real request transaction starts a separately scored three-
                // frame confirmation. Only request CDC settlement adds a short,
                // explicit pause; no reader/report signal controls source SOF.
                selectBay(1,2);previousSourceSof=0;recoveryFirstFrame=9;
                for(int n=9;n<=11;n++)begin
                    if(n%2)$readmemh({vectorDir,"/continuous_0_rgb565.hex"},pixels);
                    else $readmemh({vectorDir,"/continuous_1_rgb565.hex"},pixels);
                    continuousSourceFrame(NORMAL_FRAME_PCLK);
                end
            end
            cyclesWait:for(int n=0;n<PROCESSING_BUDGET_CYCLES;n++)begin
                if(continuousObserved==frameNumber)break;
                @(negedge clk);
            end
            repeat(5)@(negedge clk);
            if(continuousObserved!=frameNumber||sourceFrameCount!=frameNumber||overlapCycles==0||dut.transportFault||
               dut.bufferDropCount!=sourceDropCount||dut.completionDiscardCount)
                $fatal(1,"Continuous capture accounting/overlap failed results=%0d frames=%0d overlap=%0d dropped=%0d/%0d",
                    continuousObserved,frameNumber,overlapCycles,dut.bufferDropCount,sourceDropCount);
            for(int id=1;id<=frameNumber;id++)
                if(!sourceObserved[id]||!sourceCandidatesDone[id]||sourceWrites[id]!=(sourceDropped[id]?0:76800))
                    $fatal(1,"Missing complete-frame disposition id=%0d",id);
            if(overloadMode)begin
                if(sourceDropCount==0||badObservationCount!=sourceDropCount||staleObservationCount==0||
                   !status.faultFlags[FAULT_MASK_BUFFER_OVERRUN]||recoveryObservations!=3)
                    $fatal(1,"Overload must exercise whole-frame loss, stale completion rejection and three-frame recovery");
            end else if(sourceDropCount||status.faultFlags)
                $fatal(1,"Normal 40 ms source unexpectedly lost a frame or raised a fault");
            if(!haveStalledHead||!targetReportValid||targetReport.frameId!=1||
               dut.reportDropCount!=frameNumber-2||reportCount!=0)
                $fatal(1,"Continuous report queue expected held1/latest%0d/drop%0d got drop=%0d",frameNumber,frameNumber-2,dut.reportDropCount);
            targetReportReady=1;
            repeat(4)@(negedge clk);
            if(reportCount!=2||lastReport.frameId!=frameNumber||!lastReport.locked||!lastReport.observed||targetReportValid)
                $fatal(1,"Continuous report drain must deliver frame1 then the latest locked frame once each");
            if(overloadMode)
                $display("PASS perceptionCoreOverload_tb frames=11 fastPeriodNs=17160900 recoveryPeriodNs=40000000 wholeFrameDrops=%0d staleCompletions=%0d recoveryFrames=3 overlapCycles=%0d maximumProcessingCycles=%0d reportDropCount=9 source=ALTERNATING_SYNTHETIC_RGB565",
                    sourceDropCount,staleObservationCount,overlapCycles,maximumProcessingCycles);
            else
                $display("PASS perceptionCoreContinuous_tb frames=6 sourcePeriodNs=40000000 overlapCycles=%0d elapsedCycles=%0d maximumProcessingCycles=%0d reportDropCount=4 source=ALTERNATING_SYNTHETIC_RGB565",
                    overlapCycles,totalCycles-continuousStart,maximumProcessingCycles);
            $finish;
        end
        selectBay(3,1);
        if($test$plusargs("RECOVERY_ONLY"))begin
            interactionEnable=0;
            frame();frame();frame();
            if(!lastReport.locked)$fatal(1,"initial lock before truncation");
            normalU[3]=lastReport.centreU;normalV[3]=lastReport.centreV;
            truncatedFrame();truncatedFrame();truncatedFrame();
            expectedBufferDrops=3;
            for(int n=1;n<=3;n++)begin
                frame();
                if(!lastReport.observed||lastReport.locked!=(n==3)||lastReport.centreU!=normalU[3]||lastReport.centreV!=normalV[3])
                    $fatal(1,"truncated-frame bank recovery/relock n=%0d",n);
            end
            $display("PASS perceptionCoreRecovery_tb frames=%0d source=SYNTHETIC_RGB565_POST_CAPTURE",frameNumber);
            $finish;
        end
        // Three recognition frames, eight sample frames, next SOF commit, then
        // three new-configuration red-2 recognition frames arm the idle entry.
        for(int n=1;n<=15;n++)begin
            frame();
            if(!lastReport.observed)$fatal(1,"printed blue3 not read from pixels frame=%0d accepted=%0d",n,dut.acceptedCount);
        end
        if(!status.calibrated||!status.speechArmed||status.interactionBusy||eventCount!=1||status.activeCfgVersion!=1)
            $fatal(1,"fixed unfolded sheet did not calibrate once then arm: cfg=%0d calibrated=%0d armed=%0d events=%0d",
                status.activeCfgVersion,status.calibrated,status.speechArmed,eventCount);
        if(userEventValid||!debugWords[(DEBUG_TAIL_BASE+2)*32+2]||debugWords[18*32+:104]!==consumedEvent)
            $fatal(1,"Consumed terminal event was not retained for JTAG diagnosis");
        for(int bay=1;bay<=6;bay++)begin
            selectBay(bay,10+bay);
            for(int n=1;n<=3;n++)begin
                frame();
                if(!lastReport.observed||lastReport.digit!=bay||lastReport.requestTag!=10+bay||lastReport.locked!=(n==3))
                    $fatal(1,"pixel-to-report select bay=%0d n=%0d",bay,n);
            end
            normalU[bay]=lastReport.centreU;normalV[bay]=lastReport.centreV;
        end
        if($test$plusargs("REAL_FRAME_REPEAT"))begin
            $display("PASS perceptionCoreRecordedReplay_tb frames=%0d source=ONE_RECORDED_FRAME_REPEATED_IN_RTL",frameNumber);
            $finish;
        end
        // Swap only the digits between blue1 and blue2: output must follow the
        // glyph pixels to the other location, never the known sheet-cell answer.
        $readmemh({vectorDir,"/vision_1_rgb565.hex"},pixels);
        selectBay(1,30);
        frame();frame();frame();
        if(!lastReport.locked||lastReport.centreU!=normalU[2]||lastReport.centreV!=normalV[2])
            $fatal(1,"counterfactual glyph swap did not move target1 to target2 location");
        $readmemh({vectorDir,"/vision_14_rgb565.hex"},pixels);
        frame();
        if(lastReport.observed||lastReport.locked||lastReport.centreU||lastReport.centreV||lastReport.quality)
            $fatal(1,"blank current image reused historical measurement");
        if(!status.calibrated||!status.speechArmed||eventCount!=1)$fatal(1,"red absence reset persistent interaction state");
        $readmemh({vectorDir,"/vision_0_rgb565.hex"},pixels);
        truncatedFrame();truncatedFrame();truncatedFrame();
        expectedBufferDrops=3;
        for(int n=1;n<=3;n++)begin
            frame();
            if(!lastReport.observed||lastReport.locked!=(n==3)||lastReport.centreU!=normalU[1]||lastReport.centreV!=normalV[1])
                $fatal(1,"truncated-frame bank recovery/relock n=%0d",n);
        end
        if(!status.faultFlags[FAULT_CAMERA_TRANSPORT])$fatal(1,"truncated frame missing sticky diagnostic");
        $display("PASS perceptionCoreReplay_tb frames=%0d source=SYNTHETIC_RGB565_POST_CAPTURE",frameNumber);
        $finish;
    end
    // 43 full regression frame slots, each bounded by 40 ms capture plus
    // 40 ms processing, with 100 ms for reset/request/truncated-frame overhead.
    initial begin #(GLOBAL_TIMEOUT_NS);$fatal(1,"timeout perceptionCoreReplay_tb budgetNs=%0t",GLOBAL_TIMEOUT_NS);end
endmodule
