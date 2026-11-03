// ECHO-7 Part A | Human owner: Member A (name/SID pending).
// AI-assisted implementation; human review required before submission.
module causalMaskCleanup #(
    parameter int WIDTH = 320
) (
    input logic clk, reset,
    input logic in_valid, in_sop, in_eop,
    input logic [8:0] in_x,
    input logic [7:0] in_y,
    input logic [1:0] in_mask,
    output logic out_valid, out_sop, out_eop,
    output logic [8:0] out_x,
    output logic [7:0] out_y,
    output logic [1:0] out_mask
);
    // Causal speck filter: retain a foreground pixel when its RAW left or
    // RAW upper neighbour has the same colour. One clock of latency, no stalls.
    // This is deliberately not called an opening or a full 3x3 majority filter.
    logic [1:0] previous_row [0:WIDTH-1];
    logic [1:0] raw_left;
    wire foreground = in_mask == 2'b01 || in_mask == 2'b10;
    wire left_match = !in_sop && in_x != 0 && raw_left == in_mask;
    // Row zero ignores stale RAM, so reset need not clear the whole line memory.
    wire above_match = !in_sop && in_y != 0 && in_x < WIDTH &&
                       previous_row[in_x] == in_mask;
    always_ff @(posedge clk) begin
        if (reset) begin
            raw_left <= 0;
            out_valid <= 0; out_sop <= 0; out_eop <= 0;
            out_x <= 0; out_y <= 0; out_mask <= 0;
        end else begin
            out_valid <= in_valid;
            out_sop <= in_valid && in_sop;
            out_eop <= in_valid && in_eop;
            out_mask <= 0;
            if (in_valid) begin
                out_x <= in_x; out_y <= in_y;
                if (foreground && (left_match || above_match)) out_mask <= in_mask;
                raw_left <= foreground ? in_mask : 2'b00;
                if (in_x < WIDTH) previous_row[in_x] <= foreground ? in_mask : 2'b00;
            end
        end
    end
endmodule
