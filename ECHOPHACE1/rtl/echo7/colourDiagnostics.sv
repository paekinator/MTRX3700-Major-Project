// ECHO-7 Phase 1.5 | Owner: MTRX3700 ECHO-7 team; human review pending.
// AI-assisted implementation: OpenAI Codex. See OWNERS.md and AI_STATEMENT.md.
module colourDiagnostics #(
    parameter int H_RES=640, V_RES=480,
    parameter int unsigned MIN_AREA=32
) (
    input logic clk, reset,
    input logic [29:0] in_data,
    input logic [1:0] in_mask, in_mode,
    input logic in_overlay, in_sop, in_eop, in_valid,
    output logic in_ready,
    output wire [29:0] out_data,
    output wire out_sop, out_eop, out_valid,
    input logic out_ready,
    output echo7_diag_pkg::region_result_t display_red, display_blue,
    output logic [15:0] display_frame_id
);
    import echo7_diag_pkg::*;
    region_acc_t red_stats, blue_stats;
    region_result_t result_red, result_blue, draw_red, draw_blue;
    logic [9:0] x;
    logic [8:0] y;
    logic stats_done, stats_error, metrics_busy, metrics_done;
    logic [1:0] stats_mode, result_mode;
    logic [15:0] stats_id, result_id;
    logic frame_wait, result_available, overlay_ready, accept, graphics_hit, pixel_tracked;
    logic [29:0] graphics_data, composed_data;
    logic [1:0] composed_mask;
    assign in_ready=overlay_ready && !frame_wait && !reset;
    assign accept=in_valid && in_ready;
    colourRegionStats #(.H_RES(H_RES),.V_RES(V_RES),.MIN_AREA(MIN_AREA)) stats_u(
        .clk,.reset,.ce(in_ready),.in_valid,.in_sop,.in_eop,.in_data,.in_mask,.in_mode,
        .pixel_x(x),.pixel_y(y),.pixel_tracked,.frame_done(stats_done),.frame_error(stats_error),
        .frame_mode(stats_mode),.frame_id(stats_id),.red_stats,.blue_stats,
        .red_xmin(),.red_xmax(),.red_ymin(),.red_ymax(),.red_area(),.red_valid(),
        .blue_xmin(),.blue_xmax(),.blue_ymin(),.blue_ymax(),.blue_area(),.blue_valid());
    colourMeanHsv metrics_u(.clk,.reset,.start(stats_done),.red_stats,.blue_stats,
        .in_mode(stats_mode),.in_frame_id(stats_id),.busy(metrics_busy),.done(metrics_done),
        .out_mode(result_mode),.out_frame_id(result_id),.red_result(result_red),.blue_result(result_blue));

    always_ff @(posedge clk) begin
        if(reset) begin
            frame_wait<=0; result_available<=0; display_red<='0; display_blue<='0; display_frame_id<=0;
        end else begin
            // Hold the next SOP until both colours' divisions have completed.
            // The <=310 clock boundary gap fits inside VGA's 36000-clock vertical blank.
            if(accept && pixel_tracked && (in_eop || (x==H_RES-1 && y==V_RES-1))) frame_wait<=1;
            if(metrics_done) begin frame_wait<=0; result_available<=1; end
            if(accept && in_sop) begin
                display_red<=draw_red; display_blue<=draw_blue;
                display_frame_id<=result_available ? result_id : 16'd0;
            end
        end
    end
    always_comb begin
        draw_red=display_red; draw_blue=display_blue;
        if(in_sop) begin
            draw_red='0; draw_blue='0;
            if(result_available && result_mode==in_mode) begin draw_red=result_red; draw_blue=result_blue; end
        end
        composed_data=in_data; composed_mask=in_mask;
        if(in_overlay && graphics_hit) begin composed_data=graphics_data; composed_mask=0; end
    end
    diagnosticRenderer #(.H_RES(H_RES),.V_RES(V_RES)) renderer_u(
        .x,.y,.hsv_mode(in_mode==2'b10),.red_region(draw_red),.blue_region(draw_blue),
        .hit(graphics_hit),.data(graphics_data),.red_label_x(),.red_label_y(),.blue_label_x(),.blue_label_y());
    // Keep the original elastic mask stage. Statistics always see the original RGB.
    vgaMaskOverlay mask_u(.clk,.reset,.in_data(composed_data),.in_mask(composed_mask),.in_overlay,
        .in_sop,.in_eop,.in_valid(in_valid && !frame_wait),.in_ready(overlay_ready),
        .out_data,.out_sop,.out_eop,.out_valid,.out_ready);
endmodule
