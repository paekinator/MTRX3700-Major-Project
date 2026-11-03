// Atomic latest-value mailbox. The sender holds the complete payload from request
// until acknowledgement; the receiver samples only after the toggle synchroniser.
// A changing source is coalesced while busy, never sampled bit by bit as a word.
module heldBusCdc #(parameter int WIDTH=22) (
    input logic sourceClk, sourceReset,
    input logic [WIDTH-1:0] sourceData,
    input logic destinationClk, destinationReset,
    output logic [WIDTH-1:0] destinationData,
    output logic destinationValid
);
    logic [WIDTH-1:0] heldData;
    logic requestToggle, acknowledgeToggle;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS; -name DONT_MERGE_REGISTER ON; -name PRESERVE_REGISTER ON" *) logic [1:0] requestSync, acknowledgeSync;
    always_ff @(posedge sourceClk) begin
        if(sourceReset) begin
            heldData<='0; requestToggle<=0; acknowledgeSync<=0;
        end else begin
            acknowledgeSync<={acknowledgeSync[0],acknowledgeToggle};
            if(acknowledgeSync[1]==requestToggle && sourceData!=heldData) begin
                heldData<=sourceData; requestToggle<=~requestToggle;
            end
        end
    end
    always_ff @(posedge destinationClk) begin
        if(destinationReset) begin
            destinationData<='0; destinationValid<=0;
            requestSync<=0; acknowledgeToggle<=0;
        end else begin
            requestSync<={requestSync[0],requestToggle};
            destinationValid<=0;
            if(requestSync[1]!=acknowledgeToggle) begin
                destinationData<=heldData; destinationValid<=1;
                acknowledgeToggle<=requestSync[1];
            end
        end
    end
endmodule
