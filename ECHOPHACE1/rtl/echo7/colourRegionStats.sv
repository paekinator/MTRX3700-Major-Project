// ECHO-7 Phase 1.5 | Owner: MTRX3700 ECHO-7 team; human review pending.
// AI-assisted implementation: OpenAI Codex. See OWNERS.md and AI_STATEMENT.md.
module colourRegionStats #(
    parameter int H_RES=640, V_RES=480,
    parameter int unsigned MIN_AREA=32
) (
    input logic clk, reset,
    input logic ce, in_valid, in_sop, in_eop,
    input logic [29:0] in_data,
    input logic [1:0] in_mask, in_mode,
    output logic [9:0] pixel_x,
    output logic [8:0] pixel_y,
    output wire pixel_tracked,
    output logic frame_done, frame_error,
    output logic [1:0] frame_mode,
    output logic [15:0] frame_id,
    output echo7_diag_pkg::region_acc_t red_stats, blue_stats,
    output wire [9:0] red_xmin, red_xmax, blue_xmin, blue_xmax,
    output wire [8:0] red_ymin, red_ymax, blue_ymin, blue_ymax,
    output wire [18:0] red_area, blue_area,
    output wire red_valid, blue_valid
);
    import echo7_diag_pkg::*;
    localparam int PIXELS=H_RES*V_RES;
    region_acc_t red_acc, blue_acc, red_next, blue_next;
    logic [9:0] next_x;
    logic [8:0] next_y;
    logic active, bad_frame;
    logic [1:0] active_mode;
    logic last_pixel, sample_ok, packet_ok;
    assign pixel_x = in_sop ? 10'd0 : next_x;
    assign pixel_y = in_sop ? 9'd0 : next_y;
    assign last_pixel = (pixel_x==H_RES-1 && pixel_y==V_RES-1);
    assign sample_ok = active || in_sop;
    assign pixel_tracked = sample_ok;
    assign packet_ok = sample_ok && !(in_sop ? 1'b0 : bad_frame) &&
                       (in_sop || in_mode==active_mode) && in_eop && last_pixel;

    function automatic region_acc_t add_pixel(input region_acc_t previous,
        input logic [9:0] x, input logic [8:0] y, input logic [29:0] rgb);
        region_acc_t result;
        result=previous;
        // Saturate and mark the entire result invalid rather than wrapping counters.
        if (previous.area >= PIXELS) result.overflow=1;
        else begin
            if (previous.area==0) begin
                result.xmin=x; result.xmax=x; result.ymin=y; result.ymax=y;
            end else begin
                if(x<previous.xmin) result.xmin=x;
                if(x>previous.xmax) result.xmax=x;
                if(y<previous.ymin) result.ymin=y;
                if(y>previous.ymax) result.ymax=y;
            end
            result.area=previous.area+19'd1;
            result.sum_r=previous.sum_r+27'(rgb[29:22]);
            result.sum_g=previous.sum_g+27'(rgb[19:12]);
            result.sum_b=previous.sum_b+27'(rgb[9:2]);
        end
        return result;
    endfunction

    always_comb begin
        red_next=in_sop ? region_acc_t'('0) : red_acc;
        blue_next=in_sop ? region_acc_t'('0) : blue_acc;
        if (sample_ok) begin
            if(in_mask==2'b01) red_next=add_pixel(red_next,pixel_x,pixel_y,in_data);
            if(in_mask==2'b10) blue_next=add_pixel(blue_next,pixel_x,pixel_y,in_data);
        end
        red_next.valid=packet_ok && !red_next.overflow && red_next.area!=0 && red_next.area>=MIN_AREA;
        blue_next.valid=packet_ok && !blue_next.overflow && blue_next.area!=0 && blue_next.area>=MIN_AREA;
    end
    always_ff @(posedge clk) begin
        if(reset) begin
            red_acc<='0; blue_acc<='0; red_stats<='0; blue_stats<='0;
            next_x<=0; next_y<=0; active<=0; bad_frame<=0;
            active_mode<=0; frame_mode<=0; frame_id<=0; frame_done<=0; frame_error<=0;
        end else begin
            frame_done<=0; frame_error<=0;
            if(ce && in_valid) begin
                if(in_sop) begin active<=1; active_mode<=in_mode; bad_frame<=0; end
                else if(active && in_mode!=active_mode) bad_frame<=1;
                if(sample_ok) begin
                    red_acc<=red_next; blue_acc<=blue_next;
                    if(in_eop || last_pixel) begin
                        // Includes the accepted last pixel in the published sums/extents.
                        red_stats<=red_next; blue_stats<=blue_next;
                        frame_mode<=in_sop ? in_mode : active_mode;
                        frame_done<=1; frame_error<=!packet_ok; frame_id<=frame_id+16'd1;
                        active<=0; next_x<=0; next_y<=0;
                    end else if(pixel_x==H_RES-1) begin next_x<=0; next_y<=pixel_y+9'd1; end
                    else begin next_x<=pixel_x+10'd1; next_y<=pixel_y; end
                end
            end
        end
    end
    assign red_xmin=red_stats.xmin; assign red_xmax=red_stats.xmax;
    assign red_ymin=red_stats.ymin; assign red_ymax=red_stats.ymax;
    assign red_area=red_stats.area; assign red_valid=red_stats.valid;
    assign blue_xmin=blue_stats.xmin; assign blue_xmax=blue_stats.xmax;
    assign blue_ymin=blue_stats.ymin; assign blue_ymax=blue_stats.ymax;
    assign blue_area=blue_stats.area; assign blue_valid=blue_stats.valid;
`ifndef SYNTHESIS
    initial begin
        assert(H_RES>0 && H_RES<=640 && V_RES>0 && V_RES<=480)
            else $fatal(1,"colourRegionStats supports display sizes up to 640x480");
    end
`endif
endmodule
