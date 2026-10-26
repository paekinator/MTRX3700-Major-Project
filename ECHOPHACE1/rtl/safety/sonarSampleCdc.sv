// ECHO-7 team; AI-assisted by OpenAI Codex. Bundled-data toggle transfer.
// Source updates are >=100 ms apart; held data settles for two destination clocks.
module sonarSampleCdc (
    input logic src_clk,src_reset,src_valid,
    input logic [11:0] src_distance_mm,
    input logic dst_clk,dst_reset,
    output logic [11:0] distance_mm,
    output logic valid,update
);
    logic [11:0] held;
    logic toggle=0;
    (* async_reg="true" *) logic [2:0] sync_toggle=0;
    always_ff @(posedge src_clk) begin
        if(src_reset) begin held<=0; toggle<=0; end
        else if(src_valid) begin held<=src_distance_mm; toggle<=~toggle; end
    end
    always_ff @(posedge dst_clk) begin
        if(dst_reset) begin sync_toggle<=0; distance_mm<=0; valid<=0; update<=0; end
        else begin
            sync_toggle<={sync_toggle[1:0],toggle};
            update<=sync_toggle[2]^sync_toggle[1];
            if(sync_toggle[2]^sync_toggle[1]) begin
                distance_mm<=held;
                // 4000 is the course driver's measurement-window limit, not a verified clear path.
                valid<=held>0 && held<4000;
            end
        end
    end
endmodule
