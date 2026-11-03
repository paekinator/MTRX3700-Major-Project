// VGA-clock packet switch between the existing processed display and the exact
// camera_display stream. rawModeRequested is already synchronised to this clock.
// Select a mode while holding a new SOP; it cannot change until that packet's
// output EOP is accepted. A processed packet is fully drained before raw video
// starts, including when its EOP is stalled. No RGB bits or sidebands are changed
// in raw mode, and SW0/SW1 cannot add any overlays to that path.
module memberBVgaModeSwitch #(
    parameter int MAX_HOLD_FRAMES=10,
    parameter bit ENABLE_DIAGNOSTICS=1,
    parameter int BLUE_HUE_UPPER=260,
    parameter int DEFAULT_BLUE_MINIMUM=20
) (
    input logic clk, reset,
    input logic [perception_pkg::DEBUG_WORD_COUNT*32-1:0] debugWords,
    input logic showCandidates, showCentre,
    input logic rawModeRequested,
    output logic rawModeActive,
    input logic [29:0] inData,
    input logic inSop, inEop, inValid,
    output logic inReady,
    output logic [29:0] outData,
    output logic outSop, outEop, outValid,
    input logic outReady
);
    typedef enum logic [1:0] {WAIT_PACKET, STREAM_PACKET, DRAIN_PACKET} modeState_t;
    modeState_t modeState;
    logic overlayReset, overlayInValid, overlayInReady, overlayOutReady;
    logic [29:0] overlayOutData;
    logic overlayOutSop, overlayOutEop, overlayOutValid;

    // Keep normal-to-normal state: diagnostic RGB/HSV values intentionally
    // describe the previous completed display scan. Resetting between normal
    // packets would discard them. Raw mode clears/holds the entire overlay idle.
    assign overlayReset=reset || rawModeActive;
    memberBVgaOverlay #(
        .MAX_HOLD_FRAMES(MAX_HOLD_FRAMES), .ENABLE_DIAGNOSTICS(ENABLE_DIAGNOSTICS),
        .BLUE_HUE_UPPER(BLUE_HUE_UPPER), .DEFAULT_BLUE_MINIMUM(DEFAULT_BLUE_MINIMUM)
    ) overlay (
        .clk(clk), .reset(overlayReset), .debugWords(debugWords),
        .showCandidates(showCandidates&&!rawModeActive), .showCentre(showCentre&&!rawModeActive),
        .inData(rawModeActive?30'd0:inData), .inSop(inSop&&!rawModeActive),
        .inEop(inEop&&!rawModeActive), .inValid(overlayInValid),
        .inReady(overlayInReady), .outData(overlayOutData),
        .outSop(overlayOutSop), .outEop(overlayOutEop),
        .outValid(overlayOutValid), .outReady(overlayOutReady)
    );

    always_comb begin
        inReady=0;
        outData=0; outSop=0; outEop=0; outValid=0;
        overlayInValid=0; overlayOutReady=0;
        if(!reset && modeState!=WAIT_PACKET) begin
            if(rawModeActive) begin
                // The source owns payload stability while backpressured.
                // Mode/FSM state cannot change before the accepted raw EOP.
                if(modeState==STREAM_PACKET) begin
                    inReady=outReady;
                    outData=inData; outSop=inSop; outEop=inEop; outValid=inValid;
                end
            end else begin
                if(modeState==STREAM_PACKET) begin
                    overlayInValid=inValid;
                    inReady=overlayInReady;
                end
                outData=overlayOutData; outSop=overlayOutSop;
                outEop=overlayOutEop; outValid=overlayOutValid;
                overlayOutReady=outReady;
            end
        end
    end

    always_ff @(posedge clk) begin
        if(reset) begin
            modeState<=WAIT_PACKET;
            rawModeActive<=0;
        end else begin
            case(modeState)
                WAIT_PACKET: begin
                    // No handshake here: upstream retains this SOP for the
                    // next clock, after mode selection and overlay reset settle.
                    if(inValid && inSop) begin
                        rawModeActive<=rawModeRequested;
                        modeState<=STREAM_PACKET;
                    end
                end
                STREAM_PACKET: begin
                    if(inValid && inReady && inEop) begin
                        if(rawModeActive || (outValid && outReady && outEop))
                            modeState<=WAIT_PACKET;
                        else modeState<=DRAIN_PACKET;
                    end
                end
                DRAIN_PACKET: begin
                    if(outValid && outReady && outEop)modeState<=WAIT_PACKET;
                end
                default: modeState<=WAIT_PACKET;
            endcase
        end
    end
endmodule
