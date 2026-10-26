// ECHO-7 team; AI-assisted by OpenAI Codex.
// update pulses refresh age; valid is measurement quality, not an assumed clear path.
// Conservative policy: stop all directions until sensor orientation is established.
module ultrasonicSafety #(
    parameter int STOP_MM=200, RELEASE_MM=230, STALE_CLKS=15_000_000
) (
    input logic clk, reset, enable,
    input logic [11:0] sonar1_distance_mm, sonar2_distance_mm,
    input logic sonar1_valid, sonar2_valid, sonar1_update, sonar2_update,
    output logic blocked, fault, danger
);
    localparam int W=$clog2(STALE_CLKS+1);
    logic [W-1:0] age1,age2;
    logic seen1,seen2,near1,near2,good1,good2;
    always_ff @(posedge clk) begin
        if (reset) begin
            age1<='0; age2<='0; seen1<=0; seen2<=0;
            near1<=0; near2<=0; good1<=0; good2<=0;
        end else begin
            if (age1<W'(STALE_CLKS)) age1<=age1+1'b1;
            if (age2<W'(STALE_CLKS)) age2<=age2+1'b1;
            if (sonar1_update) begin
                age1<='0; seen1<=1; good1<=sonar1_valid;
                if (sonar1_valid && sonar1_distance_mm<=STOP_MM) near1<=1;
                else if (sonar1_valid && sonar1_distance_mm>=RELEASE_MM) near1<=0;
            end
            if (sonar2_update) begin
                age2<='0; seen2<=1; good2<=sonar2_valid;
                if (sonar2_valid && sonar2_distance_mm<=STOP_MM) near2<=1;
                else if (sonar2_valid && sonar2_distance_mm>=RELEASE_MM) near2<=0;
            end
        end
    end
    assign fault=enable && (!seen1 || !seen2 || !good1 || !good2 ||
                 !sonar1_valid || !sonar2_valid || age1>=STALE_CLKS || age2>=STALE_CLKS);
    assign danger=enable && (near1 || near2 ||
        (sonar1_update && sonar1_valid && sonar1_distance_mm<=STOP_MM) ||
        (sonar2_update && sonar2_valid && sonar2_distance_mm<=STOP_MM));
    assign blocked=fault || danger;
endmodule
