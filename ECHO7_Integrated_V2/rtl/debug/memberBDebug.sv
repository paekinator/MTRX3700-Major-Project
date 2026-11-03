// Versioned B-only JTAG interface. The host writes a complete source word and
// holds its command/toggle until probe acknowledgement. snapshot_probes supplies
// metastability filtering; the additional whole-word stability check and held
// command/acknowledgement transaction provide a coherent payload boundary.
// A source address change with the same toggle selects another frozen word.
module memberBDebug #(
    parameter logic [31:0] BUILD_ID = 32'd0,
    parameter bit ALLOW_TARGET_COMMANDS = 1
) (
    input logic clk, reset,
    input logic [perception_pkg::DEBUG_WORD_COUNT*32-1:0] debugWords,
    output logic commandValid,
    input logic commandReady,
    output perception_pkg::targetOperation_t commandOperation,
    output perception_pkg::markerType_t commandMarkerType,
    output logic [3:0] commandDigit,
    input perception_pkg::queryResult_t queryResult,
    input logic queryResultValid,
    output logic queryResultReady,
    // Includes a query accepted into Csim but not yet handed to the core.
    input logic queryBusy,
    output logic calibrateArm, speechArm,
    input logic interactionArmReady,
    output logic [1:0] orientationProfile,
    output logic autoCycle
);
    logic [31:0] sourceWord, previousSource, stableSource;
    logic [1:0] stableCount;
    logic ackToggle, pendingToggle, commandError,haveBaseline;
    logic [1:0] rejectionReason; // 0 accepted, 1 invalid opcode/ID, 2 busy/disabled
    logic queryBusyAtAction;
    logic [perception_pkg::DEBUG_WORD_COUNT*32-1:0] frozenWords;
    logic queryFrozen;
    logic [31:0] selectedWord, metaWord;
    logic [127:0] probeWord;
    snapshot_probes #(.ID("BCTL"),.SW(32),.PW(128)) probes (
        .clk(clk),.source(sourceWord),.probe(probeWord));

    always_comb begin
        selectedWord=32'd0;
        // QRP3 defines only eight words. Mask its zero tail on this32-bit
        // read port rather than adding a query clear input to88 stored words.
        if(stableSource[15:8]<8'(perception_pkg::DEBUG_WORD_COUNT)&&
           (!queryFrozen||stableSource[15:8]<8'd8))
            selectedWord=frozenWords[stableSource[15:8]*32+:32];
        metaWord={8'(perception_pkg::DEBUG_SCHEMA_VERSION),8'(perception_pkg::PERCEPTION_CONTRACT_VERSION),
            ackToggle,commandError,rejectionReason,3'd0,queryBusyAtAction,8'(perception_pkg::DEBUG_WORD_COUNT)};
        probeWord={32'h42444247,BUILD_ID,metaWord,selectedWord};
    end

    always_ff @(posedge clk) begin
        if(reset) begin
            previousSource<=0;stableSource<=0;stableCount<=0;
            ackToggle<=0;pendingToggle<=0;commandError<=0;frozenWords<=0;haveBaseline<=0;
            queryFrozen<=0;
            commandValid<=0;commandOperation<=perception_pkg::TARGET_CLEAR;
            commandMarkerType<=perception_pkg::MARKER_NONE;commandDigit<=4'hf;
            queryResultReady<=0;queryBusyAtAction<=0;
            calibrateArm<=0;speechArm<=0;orientationProfile<=0;autoCycle<=0;
            rejectionReason<=0;
        end else begin
            calibrateArm<=0;speechArm<=0;
            // Resolve an arm command on the same edge the interaction FSM
            // sees its valid pulse. Checking readiness when decoding the JTAG
            // word one clock earlier races an automatic red-card transition.
            // Busy requests finish with an explicit rejection; they are never
            // queued across COMMIT, silently dropped, or acknowledged early.
            if(calibrateArm||speechArm) begin
                ackToggle<=pendingToggle;
                commandError<=!interactionArmReady;
                rejectionReason<=interactionArmReady?2'd0:2'd2;
            end
            if(commandValid && commandReady) begin
                commandValid<=0;
                ackToggle<=pendingToggle;
                queryBusyAtAction<=queryBusy;
            end
            if(queryResultValid && queryResultReady) begin
                // This is the actual public ready/valid transfer. Reuse the
                // existing frozen bank, then acknowledge exactly this item.
                // Address-only reads never consume another query result.
                queryResultReady<=0;
                queryFrozen<=1;
                frozenWords[0+:32]<=32'h51525033;
                frozenWords[32+:160]<={19'd0,queryResult};
                frozenWords[192+:32]<=BUILD_ID;
                frozenWords[224+:32]<=32'h00000308;
                ackToggle<=pendingToggle;
                queryBusyAtAction<=queryBusy;
            end
            if(sourceWord!=previousSource) begin
                previousSource<=sourceWord;
                stableCount<=1;
            end else begin
                if(stableCount<3) stableCount<=stableCount+2'd1;
                // Three successive equal complete words are required. The host
                // must not issue another toggle while the command remains busy.
                if(stableCount>=2) begin
                    stableSource<=sourceWord;
                    // After KEY/reset, consume the stable pre-existing JTAG
                    // source as the baseline so an old SELECT cannot replay.
                    // The host reads acknowledgement before issuing a command.
                    if(!haveBaseline) begin
                        haveBaseline<=1;ackToggle<=sourceWord[31];
                    end else if(!commandValid && !queryResultReady && !calibrateArm && !speechArm && sourceWord[31]!=ackToggle) begin
                        pendingToggle<=sourceWord[31];
                        commandError<=0;
                        rejectionReason<=0;
                        queryBusyAtAction<=queryBusy;
                        // Keep new B debug storage; C is the only integrated request owner.
                        if(!ALLOW_TARGET_COMMANDS && (sourceWord[27:24]==1 || sourceWord[27:24]==2 ||
                           sourceWord[27:24]==7 || sourceWord[27:24]==8 || sourceWord[27:24]==9)) begin
                            commandError<=1;rejectionReason<=2;ackToggle<=sourceWord[31];
                        end else case(sourceWord[27:24])
                            4'd1: if(perception_pkg::markerEnabled(perception_pkg::markerType_t'(sourceWord[5:4]),sourceWord[3:0])) begin
                                commandValid<=1;commandOperation<=perception_pkg::TARGET_SELECT;
                                commandMarkerType<=perception_pkg::markerType_t'(sourceWord[5:4]);commandDigit<=sourceWord[3:0];
                            end else begin commandError<=1;rejectionReason<=1;ackToggle<=sourceWord[31];end
                            4'd2: begin commandValid<=1;commandOperation<=perception_pkg::TARGET_CLEAR;
                                commandMarkerType<=perception_pkg::MARKER_NONE;commandDigit<=4'hf;end
                            4'd3: calibrateArm<=1;
                            4'd4: speechArm<=1;
                            4'd5: begin frozenWords<=debugWords;queryFrozen<=0;ackToggle<=sourceWord[31];end
                            4'd6: begin orientationProfile<=sourceWord[1:0];ackToggle<=sourceWord[31];end
                            4'd7: begin autoCycle<=sourceWord[0];ackToggle<=sourceWord[31];end
                            4'd8,4'd9: begin
                                if(queryBusy) begin commandError<=1;rejectionReason<=2;ackToggle<=sourceWord[31];end
                                else if(sourceWord[27:24]==9 && !perception_pkg::markerEnabled(
                                        perception_pkg::markerType_t'(sourceWord[5:4]),sourceWord[3:0])) begin
                                    commandError<=1;rejectionReason<=1;ackToggle<=sourceWord[31];
                                end else begin
                                    commandValid<=1;
                                    commandOperation<=sourceWord[27:24]==8?perception_pkg::TARGET_LIST:perception_pkg::TARGET_GET;
                                    commandMarkerType<=sourceWord[27:24]==8?perception_pkg::MARKER_NONE:perception_pkg::markerType_t'(sourceWord[5:4]);
                                    commandDigit<=sourceWord[27:24]==8?4'hf:sourceWord[3:0];
                                end
                            end
                            4'd10: begin
                                if(queryResultValid) queryResultReady<=1;
                                else begin commandError<=1;rejectionReason<=2;ackToggle<=sourceWord[31];end
                            end
                            default: begin commandError<=1;rejectionReason<=1;ackToggle<=sourceWord[31];end
                        endcase
                    end
                end
            end
        end
    end
endmodule
