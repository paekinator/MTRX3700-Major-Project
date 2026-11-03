// CLOCK_50 domain only. The camera is never stalled by the C report channel.
// Completed frames have immutable SOF metadata; control changes cannot relabel them.
module targetTracker (
    input logic clk, reset,
    input logic [31:0] timeUs,
    input logic [15:0] activeCfgVersion,
    input logic perceptionReady,
    input perception_pkg::targetRequest_t targetRequest,
    input logic targetRequestValid,
    output logic targetRequestReady,
    input perception_pkg::frameObservation_t frameObservation,
    input logic frameValid,
    output perception_pkg::targetReport_t targetReport,
    output logic targetReportValid,
    input logic targetReportReady,
    output perception_pkg::targetRequest_t activeRequest,
    output logic [15:0] reportDropCount,
    output logic requestInvalidFault
);
    import perception_pkg::*;
    targetReport_t newReport, pendingReport;
    logic pendingValid, haveFrame;
    logic [15:0] lastFrameId, lastConfigVersion, lastRequestTag;
    logic [1:0] confirmationCount, nextCount;
    logic requestAccepted, validSelection, currentRequest, currentConfig;
    logic newSequence, adjacentFrame, goodGeometry;
    logic [15:0] frameDelta;
    logic [8:0] vMin, vMax;
    logic [8:0] sumU;
    logic [9:0] sumV;

    always_comb begin
        // Queries are routed away by perceptionCore. Keep this guard so a
        // direct integration cannot replace the selected target with LIST/GET.
        requestAccepted = targetRequestValid && targetRequestReady &&
            (targetRequest.operation == TARGET_SELECT || targetRequest.operation == TARGET_CLEAR);
        validSelection = frameObservation.boundRequest.operation == TARGET_SELECT &&
            markerEnabled(frameObservation.boundRequest.markerType, frameObservation.boundRequest.digit);
        currentRequest = frameObservation.boundRequest == activeRequest;
        currentConfig = frameObservation.configVersion == activeCfgVersion;
        frameDelta = frameObservation.frameId - lastFrameId;
        newSequence = !haveFrame || (frameDelta != 0 && !frameDelta[15]);
        adjacentFrame = haveFrame && frameDelta == 16'd1 &&
            lastConfigVersion == frameObservation.configVersion &&
            lastRequestTag == frameObservation.boundRequest.requestTag;
        goodGeometry = frameObservation.xMin <= frameObservation.xMax &&
            frameObservation.xMax < 320 && frameObservation.yMin <= frameObservation.yMax &&
            frameObservation.yMax < 240 && frameObservation.quality != 0;
        // Rotate inclusive bbox before truncating its centre, avoiding odd/even bias.
        vMin = 9'd319 - frameObservation.xMax;
        vMax = 9'd319 - frameObservation.xMin;
        sumU = {1'b0,frameObservation.yMin} + {1'b0,frameObservation.yMax};
        sumV = {1'b0,vMin} + {1'b0,vMax};
        newReport = '0;
        newReport.requestTag = frameObservation.boundRequest.requestTag;
        newReport.frameId = frameObservation.frameId;
        newReport.captureStartUs = frameObservation.captureStartUs;
        newReport.configVersion = frameObservation.configVersion;
        newReport.markerType = validSelection ? frameObservation.boundRequest.markerType : MARKER_NONE;
        newReport.digit = validSelection ? frameObservation.boundRequest.digit : INVALID_BAY_ID;
        newReport.targetSelected = validSelection;
        newReport.frameGood = frameObservation.frameGood && !frameObservation.resourceDrop && newSequence;
        newReport.reason = REPORT_NOT_FOUND;
        nextCount = 0;
        if (frameObservation.resourceDrop)
            newReport.reason = REPORT_RESOURCE_DROP;
        else if (!newReport.frameGood)
            newReport.reason = REPORT_FRAME_BAD;
        else if (!perceptionReady)
            newReport.reason = REPORT_PIPELINE_NOT_READY;
        else if (!currentRequest || requestAccepted)
            newReport.reason = REPORT_REQUEST_CHANGED;
        else if (!currentConfig)
            newReport.reason = REPORT_CONFIG_CHANGED;
        else if (frameObservation.boundRequest.operation == TARGET_CLEAR)
            newReport.reason = REPORT_NO_SELECTION;
        else if (!validSelection)
            newReport.reason = REPORT_INVALID_REQUEST;
        else if (frameObservation.matchCount > 1) begin
            newReport.ambiguous = 1;
            newReport.reason = REPORT_DUPLICATE_ID;
        end else if (frameObservation.matchCount == 1) begin
            if (!goodGeometry)
                newReport.reason = REPORT_LOW_QUALITY;
            else begin
                nextCount = adjacentFrame ? ((confirmationCount < 3) ? confirmationCount + 2'd1 : 2'd3) : 2'd1;
                newReport.observed = 1;
                newReport.locked = nextCount == 3;
                newReport.centreU = sumU[8:1];
                newReport.centreV = sumV[9:1];
                newReport.boxWidth = frameObservation.yMax - frameObservation.yMin + 8'd1;
                newReport.boxHeight = frameObservation.xMax - frameObservation.xMin + 9'd1;
                newReport.quality = frameObservation.quality;
                newReport.reason = newReport.locked ? REPORT_OK : REPORT_ACQUIRING;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            targetRequestReady <= 0;
            activeRequest <= '0;
            activeRequest.digit <= INVALID_BAY_ID;
            targetReport <= '0;
            targetReportValid <= 0;
            pendingReport <= '0;
            pendingValid <= 0;
            reportDropCount <= 0;
            requestInvalidFault <= 0;
            haveFrame <= 0;
            lastFrameId <= 0;
            lastConfigVersion <= 0;
            lastRequestTag <= 0;
            confirmationCount <= 0;
        end else begin
            targetRequestReady <= 1;
            if (frameValid) begin
                confirmationCount <= nextCount;
                if (newSequence) begin
                    haveFrame <= 1;
                    lastFrameId <= frameObservation.frameId;
                    lastConfigVersion <= frameObservation.configVersion;
                    lastRequestTag <= frameObservation.boundRequest.requestTag;
                end
            end
            if (requestAccepted) begin
                activeRequest <= targetRequest;
                confirmationCount <= 0;
                if (targetRequest.operation != TARGET_CLEAR &&
                    !(targetRequest.operation == TARGET_SELECT && markerEnabled(targetRequest.markerType,targetRequest.digit)))
                    requestInvalidFault <= 1;
            end
            if (!perceptionReady || (!frameValid && lastConfigVersion != activeCfgVersion))
                confirmationCount <= 0;
            // A displayed record is immutable until accepted. One additional slot
            // keeps the newest not-yet-presented frame; replacement is counted.
            if (!targetReportValid || targetReportReady) begin
                if (pendingValid) begin
                    targetReport <= pendingReport;
                    targetReportValid <= 1;
                    pendingValid <= frameValid;
                    if (frameValid) pendingReport <= newReport;
                end else begin
                    targetReportValid <= frameValid;
                    if (frameValid) targetReport <= newReport;
                end
            end else if (frameValid) begin
                pendingReport <= newReport;
                pendingValid <= 1;
                if (pendingValid && reportDropCount != 16'hffff)
                    reportDropCount <= reportDropCount + 16'd1;
            end
        end
    end
endmodule
