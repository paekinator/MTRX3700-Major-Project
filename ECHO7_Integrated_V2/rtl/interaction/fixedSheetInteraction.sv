// Fixed unfolded sheet interaction, CLOCK_50 only. Recognition is supplied by
// real pixel processing; no command injects a successful marker or calibration.
// Audio is deliberately deferred: red 2 can arm the entry, but never emits a
// speech proposal. Idle armed state is not busy and consumes no event FIFO slot.
module fixedSheetInteraction #(
    parameter logic [31:0] WAIT_TIMEOUT_US=32'd2000000,
    parameter logic [31:0] SAMPLE_TIMEOUT_US=32'd3000000,
    parameter logic [31:0] COMMIT_TIMEOUT_US=32'd1000000,
    parameter logic [31:0] RETRY_DELAY_US=32'd1000000,
    parameter int SAMPLE_FRAMES=8
) (
    input logic clk, reset,
    input logic [31:0] timeUs,
    input logic enable, permit, debugCalArm, debugSpeechArm,
    input logic frameValid, frameGood,
    input logic [15:0] frameId, configVersion, activeCfgVersion,
    input logic red1Paired, red2Seen,
    input logic sampleResultValid, sampleGood,
    input logic commitAck,
    input logic [15:0] commitVersion,
    output logic collectEnable, commitRequest, calibrationAttempt,
    output logic [3:0] sampleCount,
    output logic calibrated, speechArmed, busy,
    output perception_pkg::interactionKind_t kind,
    output perception_pkg::interactionState_t state,
    output logic [15:0] interactionId,
    output perception_pkg::userEvent_t userEvent,
    output logic userEventValid,
    input logic userEventReady,
    output logic eventOverflow
);
    import perception_pkg::*;
    logic attemptAllowed, haveFrame, haveSample;
    // Only the initial, reset-started session retries automatically. A debug
    // command takes ownership of a single explicit attempt; a successful
    // session never recalibrates just because its red card remains visible.
    logic automaticInitialisation, initialRetry, retryPending;
    logic [31:0] retryStartUs;
    logic haveAutoFailure;
    eventType_t lastAutoFailureType;
    eventReason_t lastAutoFailureReason;
    logic [1:0] red1Count, red2Count;
    logic [15:0] lastFrame, lastFrameConfig, lastSampleFrame;
    // A collection window belongs to exactly one segmentation/orientation/
    // bypass configuration. A later mode change cancels it, including the
    // edge after its eighth sample; it must never commit old samples in a new
    // mode. A commit already acknowledged by the commit domain remains final.
    logic [15:0] attemptCfgVersion;
    logic [31:0] stateStartUs;
    logic [31:0] elapsedUs;
    logic frameCurrent, adjacentFrame, nextRed1Confirmed, nextRed2Confirmed;
    userEvent_t terminalEvent;
    userEvent_t eventFifo [0:3];
    logic [1:0] readPointer, writePointer;
    logic [2:0] eventCount;
    logic [15:0] eventSerial;
    logic pushEvent, popEvent;
    always_comb begin
        frameCurrent = frameGood && configVersion==activeCfgVersion;
        adjacentFrame = haveFrame && frameId==lastFrame+16'd1 && configVersion==lastFrameConfig;
        nextRed1Confirmed = frameValid && frameCurrent && red1Paired && adjacentFrame && red1Count>=2;
        nextRed2Confirmed = frameValid && frameCurrent && red2Seen && adjacentFrame && red2Count>=2;
        elapsedUs=timeUs-stateStartUs;
        busy = state==INTERACTION_WAIT_PERMIT || state==INTERACTION_CAL_COLLECT ||
            state==INTERACTION_CAL_VALIDATE || state==INTERACTION_CAL_COMMIT || state==INTERACTION_RESULT_QUEUE;
        kind = busy ? KIND_CALIBRATION : KIND_NONE;
        // Permit remains a continuous condition; revoke takes priority before a
        // new same-domain SOF commit. A previously asserted commitAck is final.
        collectEnable=state==INTERACTION_CAL_COLLECT && enable && permit && activeCfgVersion==attemptCfgVersion;
        commitRequest=state==INTERACTION_CAL_COMMIT && enable && permit && activeCfgVersion==attemptCfgVersion;
        userEventValid=eventCount!=0 && !reset;
        userEvent=eventCount!=0 ? eventFifo[readPointer] : userEvent_t'('0);
        popEvent=userEventValid && userEventReady;
        pushEvent=state==INTERACTION_RESULT_QUEUE && eventCount<4;
    end

    // Build one terminal record. It is immutable while waiting for FIFO enqueue.
    task automatic finishInteraction(input eventType_t eventType,
                                     input eventReason_t reason,
                                     input logic [15:0] version);
        logic automaticFailure, mergeRepeatedFailure;
        begin
            automaticFailure=automaticInitialisation && !calibrated &&
                eventType!=EVENT_CALIBRATION_DONE;
            // Repeated automatic failures of exactly the same type/reason
            // form one diagnostic episode. Its first failure is queued; later
            // repetitions are coalesced before enqueue, never by overwriting
            // an event already presented to C. interactionId still increments
            // on every retry and sampleCount/state remain readable. A changed
            // failure, cancellation and eventual success are always queued.
            mergeRepeatedFailure=automaticFailure && haveAutoFailure &&
                eventType!=EVENT_INTERACTION_CANCELLED &&
                eventType==lastAutoFailureType && reason==lastAutoFailureReason;
            if(automaticFailure) begin
                initialRetry<=1;retryPending<=1;retryStartUs<=timeUs;
                attemptAllowed<=0;red1Count<=0;haveFrame<=0;
                haveAutoFailure<=eventType!=EVENT_INTERACTION_CANCELLED;
                lastAutoFailureType<=eventType;lastAutoFailureReason<=reason;
            end
            if(mergeRepeatedFailure) state<=INTERACTION_IDLE;
            else begin
                terminalEvent.eventId<=0; // assigned once, on actual FIFO insertion
                terminalEvent.eventType<=eventType;
                terminalEvent.bayId<=INVALID_BAY_ID;
                terminalEvent.quality<=0;
                terminalEvent.issuedAtUs<=timeUs;
                terminalEvent.configVersion<=version;
                terminalEvent.reason<=reason;
                terminalEvent.interactionId<=interactionId;
                state<=INTERACTION_RESULT_QUEUE;
            end
        end
    endtask

    always_ff @(posedge clk) begin
        if(reset) begin
            state<=INTERACTION_IDLE;calibrated<=0;speechArmed<=0;
            attemptAllowed<=1;haveFrame<=0;haveSample<=0;
            automaticInitialisation<=1;initialRetry<=0;retryPending<=0;retryStartUs<=0;
            haveAutoFailure<=0;lastAutoFailureType<=EVENT_CALIBRATION_FAILED;
            lastAutoFailureReason<=REASON_OK;
            lastFrame<=0;lastFrameConfig<=0;lastSampleFrame<=0;
            attemptCfgVersion<=0;
            red1Count<=0;red2Count<=0;sampleCount<=0;
            stateStartUs<=0;interactionId<=0;calibrationAttempt<=0;
            eventOverflow<=0;readPointer<=0;writePointer<=0;eventCount<=0;
            eventSerial<=0;terminalEvent<='0;
        end else begin
            calibrationAttempt<=0;
            if(popEvent) readPointer<=readPointer+2'd1;
            if(pushEvent) begin
                eventFifo[writePointer]<=terminalEvent;
                eventFifo[writePointer].eventId<=eventSerial+16'd1;
                writePointer<=writePointer+2'd1;
                eventSerial<=eventSerial+16'd1;
            end
            case({pushEvent,popEvent})
                2'b10:eventCount<=eventCount+3'd1;
                2'b01:eventCount<=eventCount-3'd1;
                default:;
            endcase
            if(frameValid) begin
                haveFrame<=1;lastFrame<=frameId;lastFrameConfig<=configVersion;
                if(!enable || !frameCurrent || !red1Paired) red1Count<=0;
                else if(!adjacentFrame) red1Count<=1;
                else if(red1Count<3) red1Count<=red1Count+2'd1;
                if(!enable || !frameCurrent || !red2Seen || !calibrated || busy) red2Count<=0;
                else if(!adjacentFrame) red2Count<=1;
                else if(red2Count<3) red2Count<=red2Count+2'd1;
            end
            if(!enable) begin speechArmed<=0;red1Count<=0;red2Count<=0;end
            // Unsigned subtraction permits timeUs wrap. Cooldown is idle, so
            // it does not block visual observations or claim calibration busy.
            // Discard all pre-cooldown/pre-permit red-card history: reopening
            // requires three new consecutive, good frames of one configuration.
            if(retryPending || (initialRetry && !permit)) begin
                red1Count<=0;haveFrame<=0;
            end
            if(retryPending && state==INTERACTION_IDLE && enable && permit &&
               timeUs-retryStartUs>=RETRY_DELAY_US) begin
                retryPending<=0;attemptAllowed<=1;
            end
            case(state)
                INTERACTION_IDLE,INTERACTION_SPEECH_ARMED:begin
                    if(enable && attemptAllowed && (!initialRetry || permit) &&
                       nextRed1Confirmed && !debugCalArm && !debugSpeechArm) begin
                        if(eventCount<4) begin
                            attemptAllowed<=0;interactionId<=interactionId+16'd1;
                            calibrationAttempt<=1;sampleCount<=0;haveSample<=0;
                            attemptCfgVersion<=activeCfgVersion;
                            speechArmed<=0;red2Count<=0;stateStartUs<=timeUs;
                            state<=permit ? INTERACTION_CAL_COLLECT : INTERACTION_WAIT_PERMIT;
                        end else eventOverflow<=1;
                    end else if(enable && calibrated && nextRed2Confirmed && !debugCalArm && !debugSpeechArm) begin
                        speechArmed<=1;state<=INTERACTION_SPEECH_ARMED;
                    end else if(!enable) state<=INTERACTION_IDLE;
                    // Explicit debug commands reopen only the real recognition
                    // workflow and never supply a marker identity or sample value.
                    if(debugCalArm) begin
                        attemptAllowed<=1;speechArmed<=0;red1Count<=0;red2Count<=0;
                        automaticInitialisation<=0;initialRetry<=0;retryPending<=0;
                        haveAutoFailure<=0;haveFrame<=0;
                        state<=INTERACTION_IDLE;
                    end else if(debugSpeechArm) begin
                        speechArmed<=0;red2Count<=0;state<=INTERACTION_IDLE;
                    end
                end
                INTERACTION_WAIT_PERMIT:begin
                    if(!enable) finishInteraction(EVENT_INTERACTION_CANCELLED,REASON_ENABLE_REVOKED,activeCfgVersion);
                    else if(activeCfgVersion!=attemptCfgVersion)
                        finishInteraction(EVENT_CALIBRATION_FAILED,REASON_CAL_SAMPLES_INVALID,activeCfgVersion);
                    else if(permit) begin state<=INTERACTION_CAL_COLLECT;stateStartUs<=timeUs;end
                    else if(elapsedUs>=WAIT_TIMEOUT_US)
                        finishInteraction(EVENT_INTERACTION_TIMEOUT,REASON_WAIT_TIMEOUT,activeCfgVersion);
                end
                INTERACTION_CAL_COLLECT:begin
                    if(!enable || !permit)
                        finishInteraction(EVENT_INTERACTION_CANCELLED,
                            !enable ? REASON_ENABLE_REVOKED : REASON_PERMIT_REVOKED,activeCfgVersion);
                    else if(activeCfgVersion!=attemptCfgVersion)
                        finishInteraction(EVENT_CALIBRATION_FAILED,REASON_CAL_SAMPLES_INVALID,activeCfgVersion);
                    else if(sampleResultValid) begin
                        if(!sampleGood || configVersion!=activeCfgVersion ||
                           (haveSample && frameId!=lastSampleFrame+16'd1))
                            finishInteraction(EVENT_CALIBRATION_FAILED,REASON_CAL_SAMPLES_INVALID,activeCfgVersion);
                        else begin
                            sampleCount<=sampleCount+4'd1;haveSample<=1;lastSampleFrame<=frameId;
                            if(sampleCount==SAMPLE_FRAMES-1) state<=INTERACTION_CAL_VALIDATE;
                        end
                    end else if(elapsedUs>=SAMPLE_TIMEOUT_US)
                        finishInteraction(EVENT_INTERACTION_TIMEOUT,REASON_CAPTURE_TIMEOUT,activeCfgVersion);
                end
                INTERACTION_CAL_VALIDATE:begin
                    if(!enable || !permit)
                        finishInteraction(EVENT_INTERACTION_CANCELLED,
                            !enable ? REASON_ENABLE_REVOKED : REASON_PERMIT_REVOKED,activeCfgVersion);
                    else if(activeCfgVersion!=attemptCfgVersion)
                        finishInteraction(EVENT_CALIBRATION_FAILED,REASON_CAL_SAMPLES_INVALID,activeCfgVersion);
                    else begin state<=INTERACTION_CAL_COMMIT;stateStartUs<=timeUs;end
                end
                INTERACTION_CAL_COMMIT:begin
                    if(commitAck) begin
                        calibrated<=1;red2Count<=0;
                        automaticInitialisation<=0;initialRetry<=0;retryPending<=0;
                        finishInteraction(EVENT_CALIBRATION_DONE,REASON_OK,commitVersion);
                    end else if(!enable || !permit)
                        finishInteraction(EVENT_INTERACTION_CANCELLED,
                            !enable ? REASON_ENABLE_REVOKED : REASON_PERMIT_REVOKED,activeCfgVersion);
                    else if(activeCfgVersion!=attemptCfgVersion)
                        finishInteraction(EVENT_CALIBRATION_FAILED,REASON_CAL_SAMPLES_INVALID,activeCfgVersion);
                    else if(elapsedUs>=COMMIT_TIMEOUT_US)
                        finishInteraction(EVENT_INTERACTION_TIMEOUT,REASON_INTERNAL_ERROR,activeCfgVersion);
                end
                INTERACTION_RESULT_QUEUE:begin
                    if(pushEvent) state<=INTERACTION_IDLE;
                end
                default:state<=INTERACTION_IDLE;
            endcase
        end
    end
endmodule
