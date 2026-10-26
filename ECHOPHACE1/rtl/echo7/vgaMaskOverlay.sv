// ECHO-7 Phase 1 | Owner: MTRX3700 ECHO-7 team (human review required).
// AI-assisted implementation: OpenAI Codex; see OWNERS.md and AI_STATEMENT.md.
module vgaMaskOverlay (
    input logic clk, reset,
    input logic [29:0] in_data,
    input logic [1:0] in_mask,
    input logic in_overlay, in_sop, in_eop, in_valid,
    output logic in_ready,
    output logic [29:0] out_data,
    output logic out_sop, out_eop, out_valid,
    input logic out_ready
);
    // One elastic output register. Preserve the course's RGB8 + 2 zero bits format.
    assign in_ready = (!out_valid || out_ready) && !reset;
    always_ff @(posedge clk) begin
        if (reset) begin
            out_valid <= 1'b0; out_data <= '0; out_sop <= 1'b0; out_eop <= 1'b0;
        end else if (in_ready) begin
            out_valid <= in_valid;
            out_sop <= in_valid && in_sop;
            out_eop <= in_valid && in_eop;
            out_data <= in_data;
            if (in_valid && in_overlay) begin
                case (in_mask)
                    2'b01: out_data <= {8'hff, 2'b00, 8'h00, 2'b00, 8'h00, 2'b00};
                    2'b10: out_data <= {8'h00, 2'b00, 8'h00, 2'b00, 8'hff, 2'b00};
                    default: out_data <= in_data; // Background or reserved mask: original pixel
                endcase
            end
        end
    end
endmodule
