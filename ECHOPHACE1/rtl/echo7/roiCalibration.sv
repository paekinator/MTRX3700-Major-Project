// ECHO-7 team | AI-assisted by OpenAI Codex; human review required.
// One elastic output stage. All counters advance only on accepted display pixels.
module roiCalibration #(parameter int unsigned MIN_DETECT_PIXELS=32) (
    input logic clk, reset,
    input logic [29:0] in_data,
    input logic [1:0] in_mask, in_mode,
    input logic in_calibration, in_overlay, in_sop, in_eop, in_valid,
    output wire in_ready,
    output logic [29:0] out_data,
    output logic out_sop, out_eop, out_valid, out_calibration,
    input logic out_ready,
    output echo7_diag_pkg::region_result_t display_measurement,
    output logic display_detected
);
    import echo7_diag_pkg::*;
    wire [9:0] x;
    wire [8:0] y;
    wire tracked, stats_done, stats_error, metrics_done;
    wire [1:0] stats_mode, result_mode;
    wire [15:0] stats_id;
    region_acc_t sample_stats;
    region_result_t result_sample, draw_sample;
    logic frame_wait, available, detected_snapshot, draw_detected;
    logic [15:0] detect_count, next_count;
    wire sample_pixel=x>=310 && x<=329 && y>=230 && y<=249;
    wire roi_pixel=x>=220 && x<=419 && y>=160 && y<=319;
    wire advance=!out_valid || out_ready;
    wire accept=in_valid && in_ready;
    wire ending=in_eop || (x==639 && y==479);
    wire graphics_hit;
    wire [29:0] graphics_data;
    logic [29:0] masked_data;
    assign in_ready=advance && !frame_wait && !reset;
    colourRegionStats #(.MIN_AREA(1)) sample_u(
        .clk,.reset,.ce(in_ready),.in_valid,.in_sop,.in_eop,.in_data,
        .in_mask(sample_pixel ? 2'b01 : 2'b00),.in_mode,
        .pixel_x(x),.pixel_y(y),.pixel_tracked(tracked),.frame_done(stats_done),.frame_error(stats_error),
        .frame_mode(stats_mode),.frame_id(stats_id),.red_stats(sample_stats),.blue_stats(),
        .red_xmin(),.red_xmax(),.red_ymin(),.red_ymax(),.red_area(),.red_valid(),
        .blue_xmin(),.blue_xmax(),.blue_ymin(),.blue_ymax(),.blue_area(),.blue_valid());
    colourMeanHsv mean_u(.clk,.reset,.start(stats_done),.red_stats(sample_stats),.blue_stats(region_acc_t'('0)),
        .in_mode(stats_mode),.in_frame_id(stats_id),.busy(),.done(metrics_done),
        .out_mode(result_mode),.out_frame_id(),.red_result(result_sample),.blue_result());
    always_comb begin
        // Apply SW3 only inside the ROI. Statistics above always use original RGB.
        masked_data=in_data;
        if(in_overlay && tracked && roi_pixel) begin
            case(in_mask)
                2'b01: masked_data={8'hff,2'b00,8'h00,2'b00,8'h00,2'b00};
                2'b10: masked_data={8'h00,2'b00,8'h00,2'b00,8'hff,2'b00};
                default: begin end
            endcase
        end
        next_count=in_sop ? 16'd0 : detect_count;
        if(tracked && roi_pixel && (in_mask==1 || in_mask==2) && next_count<32000)
            next_count=next_count+16'd1;
        draw_sample=display_measurement; draw_detected=display_detected;
        if(in_sop) begin
            draw_sample='0; draw_detected=0;
            if(available && result_mode==in_mode) begin
                draw_sample=result_sample;
                draw_detected=result_sample.valid && detected_snapshot;
            end
        end
    end
    roiCalibrationRenderer renderer_u(.x,.y,.mode(in_mode),.detected(draw_detected),
        .measurement(draw_sample),.hit(graphics_hit),.data(graphics_data));
    always_ff @(posedge clk) begin
        if(reset) begin
            frame_wait<=0; available<=0; detect_count<=0; detected_snapshot<=0;
            display_measurement<='0; display_detected<=0;
            out_data<=0; out_sop<=0; out_eop<=0; out_valid<=0; out_calibration<=0;
        end else begin
            if(metrics_done) begin frame_wait<=0; available<=1; end
            if(accept) begin
                if(tracked) detect_count<=next_count;
                if(tracked && ending) begin
                    frame_wait<=1;
                    detected_snapshot<=next_count>=MIN_DETECT_PIXELS;
                end
                if(in_sop) begin display_measurement<=draw_sample; display_detected<=draw_detected; end
            end
            if(advance) begin
                out_valid<=accept;
                out_sop<=accept && in_sop; out_eop<=accept && in_eop;
                if(accept) begin
                    // Fixed red border and diagnostic text take priority over masks.
                    out_data<=graphics_hit ? graphics_data : masked_data;
                    out_calibration<=in_calibration;
                end
            end
        end
    end
`ifndef SYNTHESIS
    initial assert(MIN_DETECT_PIXELS>0 && MIN_DETECT_PIXELS<=32000)
        else $fatal(1,"MIN_DETECT_PIXELS must be 1..32000");
`endif
endmodule
