// Member B/C contract v3. All public fields are unsigned and sampled on CLOCK_50.
// Layout follows the root README.md B/C contract, most significant field first.
package perception_pkg;
    localparam int unsigned PERCEPTION_CONTRACT_VERSION = 3;
    // Private schema8 retains the shared16 status layout, but versions the typed
    // public request/report and the separate, on-demand query-result transaction.
    localparam int unsigned DEBUG_SCHEMA_VERSION = 8;
    localparam int unsigned DEBUG_WORD_COUNT = 96;
    localparam int unsigned DEBUG_MARKER_COUNT = 16;
    localparam int unsigned DEBUG_TAIL_BASE = 88;
    localparam logic [9:0] DEFAULT_ACTIVE_BAY_MASK = 10'h07e;
    localparam logic [3:0] INVALID_BAY_ID = 4'hf;
    typedef enum logic [1:0] {
        TARGET_CLEAR=2'd0, TARGET_SELECT=2'd1, TARGET_LIST=2'd2, TARGET_GET=2'd3
    } targetOperation_t;
    typedef enum logic [1:0] {
        MARKER_NONE=2'd0, MARKER_BAY=2'd1,
        MARKER_FUNCTION=2'd2, MARKER_REFERENCE=2'd3
    } markerType_t;
    typedef enum logic [2:0] {
        QUERY_OK=3'd0, QUERY_MULTIPLE=3'd1, QUERY_NOT_FOUND=3'd2,
        QUERY_FRAME_BAD=3'd3, QUERY_NOT_READY=3'd4,
        QUERY_INVALID_REQUEST=3'd5, QUERY_STALE=3'd6
    } queryReason_t;
    typedef enum logic [1:0] {KIND_NONE=2'd0, KIND_CALIBRATION=2'd1, KIND_SPEECH=2'd2} interactionKind_t;
    typedef enum logic [3:0] {
        INTERACTION_IDLE=4'd0, INTERACTION_WAIT_PERMIT=4'd1, INTERACTION_CAL_COLLECT=4'd2,
        INTERACTION_CAL_VALIDATE=4'd3, INTERACTION_CAL_COMMIT=4'd4, INTERACTION_LISTEN=4'd5,
        INTERACTION_CLASSIFY=4'd6, INTERACTION_RESULT_QUEUE=4'd7, INTERACTION_REARM=4'd8,
        INTERACTION_SPEECH_ARMED=4'd9
    } interactionState_t;
    typedef enum logic [7:0] {
        REPORT_OK=8'd0, REPORT_NO_SELECTION=8'd1, REPORT_ACQUIRING=8'd2, REPORT_NOT_FOUND=8'd3,
        REPORT_DUPLICATE_ID=8'd4, REPORT_FRAME_BAD=8'd5, REPORT_CONFIG_CHANGED=8'd6,
        REPORT_REQUEST_CHANGED=8'd7, REPORT_PIPELINE_NOT_READY=8'd8,
        REPORT_INVALID_REQUEST=8'd9, REPORT_LOW_QUALITY=8'd10, REPORT_RESOURCE_DROP=8'd11
    } reportReason_t;
    typedef enum logic [3:0] {
        EVENT_NONE=4'd0, EVENT_SPEECH_BAY_REQUEST=4'd1, EVENT_CALIBRATION_DONE=4'd2,
        EVENT_CALIBRATION_FAILED=4'd3, EVENT_INPUT_REJECTED=4'd4,
        EVENT_INTERACTION_CANCELLED=4'd5, EVENT_INTERACTION_TIMEOUT=4'd6
    } eventType_t;
    typedef enum logic [7:0] {
        REASON_OK=8'd0, REASON_LOW_CONFIDENCE=8'd1, REASON_BAY_DISABLED=8'd2,
        REASON_NO_SPEECH=8'd3, REASON_AUDIO_UNAVAILABLE=8'd4, REASON_CAL_CARD_INVALID=8'd5,
        REASON_CAL_SAMPLES_INVALID=8'd6, REASON_PERMIT_REVOKED=8'd7,
        REASON_ENABLE_REVOKED=8'd8, REASON_WAIT_TIMEOUT=8'd9,
        REASON_CAPTURE_TIMEOUT=8'd10, REASON_INTERNAL_ERROR=8'd11
    } eventReason_t;
    localparam int FAULT_CAMERA_TRANSPORT=0, FAULT_CANDIDATE_OVERFLOW=1,
        FAULT_MASK_BUFFER_OVERRUN=2, FAULT_CONFIG_REJECTED=3,
        FAULT_AUDIO_CAPTURE=4, FAULT_REQUEST_INVALID=5, FAULT_INTERNAL_PROTOCOL=6;
    typedef struct packed {
        targetOperation_t operation;
        logic [15:0] requestTag;
        markerType_t markerType;
        logic [3:0] digit;
    } targetRequest_t;
    typedef struct packed {
        logic [15:0] requestTag;
        logic [15:0] frameId;
        logic [31:0] captureStartUs;
        logic [15:0] configVersion;
        markerType_t markerType;
        logic [3:0] digit;
        logic frameGood, observed, locked, ambiguous, targetSelected;
        logic [7:0] centreU;
        logic [8:0] centreV;
        logic [7:0] boxWidth;
        logic [8:0] boxHeight;
        logic [7:0] quality;
        reportReason_t reason;
    } targetReport_t;
    // One query has one immutable source frame. LIST/GET return count items,
    // index0..count-1; an empty/error response is count0,index0,last1 with zero
    // measurement. Querying never changes the independently tracked request.
    typedef struct packed {
        logic [15:0] requestTag;
        logic [15:0] frameId;
        logic [31:0] captureStartUs;
        logic [15:0] configVersion;
        queryReason_t reason;
        logic [4:0] count;
        logic [3:0] index;
        logic last;
        markerType_t markerType;
        logic [3:0] digit;
        logic [7:0] centreU;
        logic [8:0] centreV;
        logic [7:0] boxWidth;
        logic [8:0] boxHeight;
        logic [7:0] quality;
    } queryResult_t;
    typedef struct packed {
        logic [15:0] eventId;
        eventType_t eventType;
        logic [3:0] bayId;
        logic [7:0] quality;
        logic [31:0] issuedAtUs;
        logic [15:0] configVersion;
        eventReason_t reason;
        logic [15:0] interactionId;
    } userEvent_t;
    typedef struct packed {
        logic interactionBusy;
        interactionKind_t kind;
        interactionState_t state;
        logic calibrated, audioReady, perceptionReady;
        logic [15:0] activeCfgVersion;
        logic [15:0] reportDropCount;
        logic eventOverflow;
        logic [15:0] faultFlags;
        logic [15:0] interactionId;
        logic speechArmed;
    } perceptionStatus_t;

    // Private completed-frame input to targetTracker. boundRequest MUST be latched
    // at camera SOF together with the timestamp, version and glyph-bank ownership.
    // matchCount counts accepted observations of the exact bound type/digit.
    // REFERENCE is supplied only by the unique same-frame red1/reference pair.
    typedef struct packed {
        targetRequest_t boundRequest;
        logic [15:0] frameId;
        logic [31:0] captureStartUs;
        logic [15:0] configVersion;
        logic frameGood, resourceDrop;
        logic [4:0] matchCount;
        logic [8:0] xMin, xMax;
        logic [7:0] yMin, yMax;
        logic [7:0] quality;
    } frameObservation_t;

    function automatic logic bayEnabled(input logic [3:0] bayId);
        bayEnabled = (bayId >= 1 && bayId <= 6);
    endfunction
    function automatic logic markerEnabled(input markerType_t markerType,
                                           input logic [3:0] digit);
        case(markerType)
            MARKER_BAY: markerEnabled=bayEnabled(digit);
            MARKER_FUNCTION: markerEnabled=(digit==1 || digit==2);
            MARKER_REFERENCE: markerEnabled=(digit==4'hf);
            default: markerEnabled=1'b0;
        endcase
    endfunction
    function automatic logic freshTime(input logic [31:0] nowUs,
            input logic [31:0] stampUs, input logic [31:0] maxAgeUs);
        logic [31:0] ageUs;
        begin
            ageUs = nowUs - stampUs;
            freshTime = !ageUs[31] && ageUs <= maxAgeUs;
        end
    endfunction
    function automatic logic newerSequence(input logic [15:0] nextId,
            input logic [15:0] previousId);
        logic [15:0] delta;
        begin
            delta = nextId - previousId;
            newerSequence = delta != 0 && !delta[15];
        end
    endfunction
endpackage
