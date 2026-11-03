// Public v3 LIST/GET snapshots. All ports are CLOCK_50 synchronous with the
// shared active-high reset and microsecond timebase. No camera backpressure.
// Three 16x64 descriptor banks allow a stalled reader, latest complete frame
// and current writer to coexist. Only the small headers/ownership are reset;
// data is synchronous RAM, never a combinational 16:1 marker-array read port.
module markerQueryStore #(
    parameter logic [31:0] MAX_AGE_US=32'd150000
) (
    input logic clk,reset,
    input logic [31:0] timeUs,
    input logic [15:0] activeConfigVersion,
    input logic perceptionReady,

    input logic beginFrame,
    input logic [15:0] inputFrameId,
    input logic [31:0] inputCaptureStartUs,
    input logic [15:0] inputConfigVersion,
    input logic inputFrameGood,
    input logic writeValid,
    input logic [3:0] writeIndex,
    input logic writeAccepted,
    input perception_pkg::markerType_t writeType,
    input logic [3:0] writeDigit,
    input logic [7:0] writeQuality,
    input logic [8:0] writeXMin,writeXMax,
    input logic [7:0] writeYMin,writeYMax,
    input logic commitFrame,cancelFrame,

    input logic publishBad,
    input logic [15:0] badFrameId,
    input logic [31:0] badCaptureStartUs,
    input logic [15:0] badConfigVersion,

    input perception_pkg::targetRequest_t queryRequest,
    input logic queryRequestValid,
    output logic queryRequestReady,
    output perception_pkg::queryResult_t queryResult,
    output logic queryResultValid,
    input logic queryResultReady,
    output logic queryBusy
);
    import perception_pkg::*;
    typedef struct packed {
        logic valid;
        markerType_t markerType;
        logic [3:0] digit;
        logic [7:0] quality;
        logic [8:0] xMin,xMax;
        logic [7:0] yMin,yMax;
    } descriptor_t; // 49bits; upper15 RAM bits are padding.
    typedef struct packed {
        logic [15:0] frameId;
        logic [31:0] captureStartUs;
        logic [15:0] configVersion;
        logic frameGood;
    } frameHeader_t;
    frameHeader_t headers[0:2];
    logic haveLatest,haveWriting,haveReading;
    logic [1:0] latestBank,writingBank,readingBank;
    logic [15:0] writtenMask;

    typedef enum logic [2:0] {
        Q_IDLE,Q_SCAN_ISSUE,Q_SCAN_RESULT,Q_FIND,Q_ITEM_ISSUE,Q_ITEM_RESULT,Q_HOLD
    } queryState_t;
    queryState_t state;
    logic listQuery;
    markerType_t requestedType;
    logic [3:0] requestedDigit,scanIndex,emitSlot,emitIndex;
    logic [15:0] matchBits;
    logic [4:0] matchCount,countWithCurrent;
    queryReason_t acceptReason,itemReason;
    logic queryAccept,reserveLatest,entryMatches;
    logic acceptBad,keepNewerWriter;
    logic freeFound,badBankFound;
    logic [1:0] freeBank,badBank;

    (* ramstyle="M10K, no_rw_check" *) logic [63:0] descriptorRam[0:47];
    logic [63:0] ramReadData,ramWriteData;
    logic [5:0] ramReadAddress,ramWriteAddress;
    logic ramReadEnable,ramWriteEnable;
    descriptor_t inputDescriptor,readDescriptor;
    logic [15:0] committedMask;
    logic [8:0] sumY,widthY;
    logic [9:0] sumPublicV,heightX;

    // No RAM reset and no asynchronous data output. Bank ownership prohibits
    // read/write collisions, including a query accepting the pre-edge latest
    // bank on the very edge where a newer frame is published.
    always_ff @(posedge clk) begin
        if(ramWriteEnable) descriptorRam[ramWriteAddress]<=ramWriteData;
        if(ramReadEnable) ramReadData<=descriptorRam[ramReadAddress];
    end

    always_comb begin
        queryRequestReady=!reset&&(state==Q_IDLE);
        queryBusy=state!=Q_IDLE;
        queryAccept=queryRequestValid&&queryRequestReady;
        acceptReason=QUERY_OK;
        if((queryRequest.operation!=TARGET_LIST&&queryRequest.operation!=TARGET_GET)||
           (queryRequest.operation==TARGET_GET&&!markerEnabled(queryRequest.markerType,queryRequest.digit)))
            acceptReason=QUERY_INVALID_REQUEST;
        else if(!perceptionReady||!haveLatest) acceptReason=QUERY_NOT_READY;
        else if(!headers[latestBank].frameGood) acceptReason=QUERY_FRAME_BAD;
        else if(headers[latestBank].configVersion!=activeConfigVersion||
                !freshTime(timeUs,headers[latestBank].captureStartUs,MAX_AGE_US))
            acceptReason=QUERY_STALE;
        reserveLatest=queryAccept&&(acceptReason==QUERY_OK);

        // A duplicate bad publication may conservatively invalidate that same
        // frame. Good commits must be strictly newer and can never resurrect it.
        acceptBad=publishBad&&(!haveLatest||badFrameId==headers[latestBank].frameId||
                              newerSequence(badFrameId,headers[latestBank].frameId));
        keepNewerWriter=haveWriting&&newerSequence(headers[writingBank].frameId,badFrameId);
        freeFound=0;freeBank=0;
        for(integer bank=0;bank<3;bank++) begin
            if(!freeFound&&(!haveLatest||latestBank!=2'(bank))&&
               (!haveReading||readingBank!=2'(bank))&&
               (!reserveLatest||latestBank!=2'(bank))) begin
                freeFound=1;freeBank=2'(bank);
            end
        end
        // A bad frame needs only a header. Prefer a spare/cancelled-writer bank.
        // If a newer writer and an older query occupy the other two banks, the
        // unreserved latest bank can become the bad latest without touching RAM.
        badBankFound=0;badBank=0;
        for(integer bank=0;bank<3;bank++) begin
            if(!badBankFound&&(!haveLatest||latestBank!=2'(bank))&&
               (!haveReading||readingBank!=2'(bank))&&
               (!reserveLatest||latestBank!=2'(bank))&&
               (!keepNewerWriter||writingBank!=2'(bank))) begin
                badBankFound=1;badBank=2'(bank);
            end
        end
        if(!badBankFound&&haveLatest&&(!haveReading||readingBank!=latestBank)&&
           !reserveLatest&&(!keepNewerWriter||writingBank!=latestBank)) begin
            badBankFound=1;badBank=latestBank;
        end

        inputDescriptor='0;
        inputDescriptor.valid=writeAccepted&&(writeQuality!=0)&&markerEnabled(writeType,writeDigit)&&
            writeXMin<=writeXMax&&writeXMax<9'd320&&writeYMin<=writeYMax&&writeYMax<8'd240;
        inputDescriptor.markerType=writeType;inputDescriptor.digit=writeDigit;
        inputDescriptor.quality=writeQuality;
        inputDescriptor.xMin=writeXMin;inputDescriptor.xMax=writeXMax;
        inputDescriptor.yMin=writeYMin;inputDescriptor.yMax=writeYMax;
        ramWriteData={15'd0,inputDescriptor};
        ramWriteAddress={writingBank,writeIndex};
        ramWriteEnable=!reset&&haveWriting&&writeValid&&!beginFrame&&!cancelFrame&&
            (!acceptBad||keepNewerWriter);
        committedMask=writtenMask;
        if(ramWriteEnable) committedMask[writeIndex]=1'b1;

        ramReadEnable=!reset&&(state==Q_SCAN_ISSUE||state==Q_ITEM_ISSUE);
        ramReadAddress={readingBank,(state==Q_SCAN_ISSUE?scanIndex:emitSlot)};
        readDescriptor=descriptor_t'(ramReadData[48:0]);
        entryMatches=readDescriptor.valid&&(listQuery||
            (readDescriptor.markerType==requestedType&&readDescriptor.digit==requestedDigit));
        countWithCurrent=matchCount+(entryMatches?5'd1:5'd0);
        sumY={1'b0,readDescriptor.yMin}+{1'b0,readDescriptor.yMax};
        sumPublicV=(10'd319-{1'b0,readDescriptor.xMax})+(10'd319-{1'b0,readDescriptor.xMin});
        widthY={1'b0,readDescriptor.yMax}-{1'b0,readDescriptor.yMin}+9'd1;
        heightX={1'b0,readDescriptor.xMax}-{1'b0,readDescriptor.xMin}+10'd1;
    end

    always_ff @(posedge clk) begin
        if(reset) begin
            haveLatest<=0;haveWriting<=0;latestBank<=0;writingBank<=0;writtenMask<=0;
            for(integer bank=0;bank<3;bank++) headers[bank]<='0;
        end else begin
            if(acceptBad) begin
                if(badBankFound) begin
                    headers[badBank].frameId<=badFrameId;
                    headers[badBank].captureStartUs<=badCaptureStartUs;
                    headers[badBank].configVersion<=badConfigVersion;
                    headers[badBank].frameGood<=0;
                    latestBank<=badBank;haveLatest<=1;
                end
                if(!keepNewerWriter||cancelFrame) begin haveWriting<=0;writtenMask<=0;end
                else if(commitFrame) begin
                    // A delayed bad capture must not discard a newer complete
                    // writer, including its final same-edge descriptor write.
                    headers[writingBank].frameGood<=headers[writingBank].frameGood&&(&committedMask);
                    latestBank<=writingBank;haveLatest<=1;
                    haveWriting<=0;writtenMask<=0;
                end else if(ramWriteEnable) writtenMask[writeIndex]<=1'b1;
            end else if(cancelFrame) begin
                haveWriting<=0;writtenMask<=0;
            end else if(commitFrame&&haveWriting) begin
                if(!haveLatest||newerSequence(headers[writingBank].frameId,headers[latestBank].frameId)) begin
                    headers[writingBank].frameGood<=headers[writingBank].frameGood&&(&committedMask);
                    latestBank<=writingBank;haveLatest<=1;
                end
                haveWriting<=0;writtenMask<=0;
            end else if(beginFrame&&freeFound) begin
                writingBank<=freeBank;haveWriting<=1;writtenMask<=0;
                headers[freeBank].frameId<=inputFrameId;
                headers[freeBank].captureStartUs<=inputCaptureStartUs;
                headers[freeBank].configVersion<=inputConfigVersion;
                headers[freeBank].frameGood<=inputFrameGood;
            end else if(ramWriteEnable) writtenMask[writeIndex]<=1'b1;
        end
    end

    always_ff @(posedge clk) begin
        if(reset) begin
            state<=Q_IDLE;haveReading<=0;readingBank<=0;
            queryResult<='0;queryResultValid<=0;
            listQuery<=0;requestedType<=MARKER_NONE;requestedDigit<=4'hf;
            scanIndex<=0;emitSlot<=0;emitIndex<=0;matchBits<=0;matchCount<=0;itemReason<=QUERY_OK;
        end else case(state)
            Q_IDLE: if(queryAccept) begin
                // Header is copied before any simultaneous publication updates
                // the bank table. The output register retains it for this entire
                // query, even if configuration/readiness/age change while held.
                queryResult<='0;
                queryResult.requestTag<=queryRequest.requestTag;
                queryResult.frameId<=haveLatest?headers[latestBank].frameId:16'd0;
                queryResult.captureStartUs<=haveLatest?headers[latestBank].captureStartUs:32'd0;
                queryResult.configVersion<=haveLatest?headers[latestBank].configVersion:activeConfigVersion;
                queryResult.markerType<=MARKER_NONE;queryResult.digit<=4'hf;
                queryResult.last<=1;queryResult.reason<=acceptReason;
                if(acceptReason!=QUERY_OK) begin queryResultValid<=1;state<=Q_HOLD;end
                else begin
                    readingBank<=latestBank;haveReading<=1;
                    listQuery<=queryRequest.operation==TARGET_LIST;
                    requestedType<=queryRequest.markerType;requestedDigit<=queryRequest.digit;
                    scanIndex<=0;matchBits<=0;matchCount<=0;state<=Q_SCAN_ISSUE;
                end
            end
            Q_SCAN_ISSUE: state<=Q_SCAN_RESULT;
            Q_SCAN_RESULT: begin
                matchBits[scanIndex]<=entryMatches;matchCount<=countWithCurrent;
                if(scanIndex==4'd15) begin
                    if(countWithCurrent==0) begin
                        queryResult.reason<=QUERY_NOT_FOUND;queryResultValid<=1;state<=Q_HOLD;
                    end else begin
                        itemReason<=!listQuery&&countWithCurrent>1?QUERY_MULTIPLE:QUERY_OK;
                        emitSlot<=0;emitIndex<=0;state<=Q_FIND;
                    end
                end else begin scanIndex<=scanIndex+4'd1;state<=Q_SCAN_ISSUE;end
            end
            Q_FIND: begin
                if(matchBits[emitSlot]) state<=Q_ITEM_ISSUE;
                else emitSlot<=emitSlot+4'd1;
            end
            Q_ITEM_ISSUE: state<=Q_ITEM_RESULT;
            Q_ITEM_RESULT: begin
                queryResult.reason<=itemReason;queryResult.count<=matchCount;
                queryResult.index<=emitIndex;
                queryResult.last<=({1'b0,emitIndex}+5'd1)==matchCount;
                queryResult.markerType<=readDescriptor.markerType;queryResult.digit<=readDescriptor.digit;
                queryResult.centreU<=sumY[8:1];queryResult.centreV<=sumPublicV[9:1];
                queryResult.boxWidth<=widthY[7:0];queryResult.boxHeight<=heightX[8:0];
                queryResult.quality<=readDescriptor.quality;
                queryResultValid<=1;state<=Q_HOLD;
            end
            Q_HOLD: if(queryResultValid&&queryResultReady) begin
                queryResultValid<=0;
                if(queryResult.last) begin haveReading<=0;state<=Q_IDLE;end
                else begin emitSlot<=emitSlot+4'd1;emitIndex<=emitIndex+4'd1;state<=Q_FIND;end
            end
            default: begin state<=Q_IDLE;queryResultValid<=0;haveReading<=0;end
        endcase
    end

    // synthesis translate_off
    initial begin
        assert($bits(targetRequest_t)==24&&$bits(queryResult_t)==141&&$bits(descriptor_t)==49)
            else $fatal(1,"markerQueryStore requires the public v3 layouts");
        assert(MAX_AGE_US<32'h80000000) else $fatal(1,"Query age budget must be below half the time range");
    end
    always @(posedge clk) if(!reset) begin
        assert(!beginFrame||acceptBad||cancelFrame||commitFrame||freeFound)
            else $fatal(1,"Three query banks failed to provide a writer");
        assert(!acceptBad||badBankFound) else $fatal(1,"No bank for a bad latest header");
        assert(!ramWriteEnable||!haveReading||writingBank!=readingBank)
            else $fatal(1,"Query writer overwrote the reserved reader bank");
        assert(!ramWriteEnable||!reserveLatest||writingBank!=latestBank)
            else $fatal(1,"Query acceptance raced a write into the pre-edge latest bank");
    end
    // synthesis translate_on
endmodule
