// ECHO-7 team | AI-assisted by OpenAI Codex; human review pending.
// Synthetic test stimuli only; hardware always uses live framebuffer pixels.
`timescale 1ns/1ps
module echo7_diagnostics_tb;
    import echo7_diag_pkg::*;
    import echo7_diag_ref_pkg::*;
    import echo7_ref_pkg::*;
    logic clk=0,wr_clk=0; always #20 clk=~clk; always #12.5 wr_clk=~wr_clk;
    logic reset=1,wr_valid=0;
    logic [9:0] wr_x=0; logic [8:0] wr_y=0; logic [15:0] wr_pixel=0;
    wire [8:0] rd_x; wire [7:0] rd_y; wire [15:0] rd_pixel;
    wire [29:0] in_data,seg_data,out_data;
    wire in_sop,in_eop,in_valid,in_ready,seg_sop,seg_eop,seg_valid,seg_ready,seg_overlay;
    wire out_sop,out_eop,out_valid; logic out_ready=0;
    wire [1:0] seg_mask,seg_mode;
    logic [2:0] control_async=0;
    region_result_t display_red,display_blue;
    wire [15:0] display_frame_id;
    frame_buffer fb(.wr_clk,.wr_frame_start(1'b0),.wr_valid,.wr_x,.wr_y,.wr_pixel,
        .rd_clk(clk),.rd_x,.rd_y,.rd_pixel);
    camera_display source_u(.clk,.reset,.hold_enable(1'b1),.rd_x,.rd_y,.rd_pixel,
        .data(in_data),.startofpacket(in_sop),.endofpacket(in_eop),.valid(in_valid),.ready(in_ready));
    segmentationSelector #(.STABLE_CYCLES(4)) selector_u(.clk,.reset,.control_async,
        .in_data,.in_sop,.in_eop,.in_valid,.in_ready,
        .out_data(seg_data),.out_sop(seg_sop),.out_eop(seg_eop),.out_valid(seg_valid),.out_ready(seg_ready),
        .out_mask(seg_mask),.out_overlay(seg_overlay),.out_mode(seg_mode));
    colourDiagnostics diagnostics_u(.clk,.reset,.in_data(seg_data),.in_mask(seg_mask),.in_mode(seg_mode),.in_overlay(seg_overlay),
        .in_sop(seg_sop),.in_eop(seg_eop),.in_valid(seg_valid),.in_ready(seg_ready),
        .out_data,.out_sop,.out_eop,.out_valid,.out_ready,.display_red,.display_blue,.display_frame_id);
    function automatic logic [15:0] scene(input int x,y,phase);
        if(phase==2) return 16'h5b0b; // Empty/no-target frame.
        if(phase==1) begin
            if(x>110 && x<125 && y>110 && y<120) return 16'hd124;
            if(x>270 && y>210) return 16'h211a;
        end else begin
            if((x-65)*(x-65)+(y-60)*(y-60)<600 || (x>140 && x<150 && y>10 && y<25)) return 16'hc924;
            if((x-210)*(x-210)+(y-160)*(y-160)<900) return 16'h211a;
        end
        return 16'h5b0b;
    endfunction
    function automatic logic [2:0] config_for(input int f);
        case(f)
            0: return 3'b000;
            1,2: return 3'b100;
            3,4: return 3'b101;
            5,6: return 3'b110;
            7: return 3'b010; // Overlay off while retaining HSV selection.
            8,9: return 3'b111;
            default: return 3'b100;
        endcase
    endfunction
    transaction source_q[$],output_q[$],t,u;
    region_acc_t er_acc='0,eb_acc='0;
    region_result_t previous_red='0,previous_blue='0,draw_red='0,draw_blue='0;
    logic [1:0] previous_mode=0;
    logic [2:0] cfg;
    logic [30:0] graphics;
    int sx=0,sy=0,sframe=0,dx=0,dy=0,dframe=0,outputs=0;
    int beam=0,beam_frames=0,wait_cycles=0,max_wait=0;
    bit beam_enabled=0,random_pause=0,held=0,check_snapshot=0;
    logic [31:0] held_payload;
    always @(negedge clk) begin
        random_pause=(beam_frames>=4 && $urandom_range(0,7)==0);
        out_ready=beam_enabled && beam%800<640 && beam/800<480 && !random_pause;
        if(!reset && sx>=100 && sy==0) control_async=config_for(sframe+1);
        if(check_snapshot) begin
            if(display_red!==draw_red || display_blue!==draw_blue) $fatal(1,"Atomic frame snapshot mismatch");
            check_snapshot=0;
        end
    end
    always @(posedge clk) begin
        if(!reset) begin
            // Free-running 800x525 timing during the first four frames: any valid
            // gap in active video is an underflow. Later frames add random stalls.
            if(beam_enabled) begin
                if(out_ready && !out_valid) $fatal(1,"VGA active-video underflow frame=%0d beam=%0d",beam_frames,beam);
                if(out_ready && out_valid && (out_sop!==(beam==0) || out_eop!==(beam==479*800+639)))
                    $fatal(1,"SOP/EOP not aligned with the free-running VGA raster");
                if(!(random_pause && beam%800<640 && beam/800<480)) begin
                    if(beam==419999) begin beam=0; beam_frames++; end else beam++;
                end
            end
            if(in_valid && in_ready) begin
                if(sframe<3 && in_data!==video(scene(sx/2,sy/2,0))) $fatal(1,"Framebuffer 2x scaling mismatch");
                cfg=config_for(sframe);
                t.data=in_data; t.sop=in_sop; t.eop=in_eop; t.enable=cfg[2];
                t.mask=classify({in_data[29:25],in_data[19:14],in_data[9:5]},int'(cfg[1:0]));
                source_q.push_back(t);
                if(sx==639) begin sx=0; if(sy==479) begin sy=0;sframe++;end else sy++;end else sx++;
            end
            if(seg_valid && seg_ready) begin
                if(source_q.size()==0) $fatal(1,"Selector extra pixel");
                u=source_q.pop_front(); cfg=config_for(dframe);
                if({seg_data,seg_sop,seg_eop,seg_mask,seg_overlay,seg_mode} !== {u.data,u.sop,u.eop,u.mask,u.enable,cfg[1:0]})
                    $fatal(1,"Selector mode/data mismatch frame=%0d",dframe);
                if(seg_sop) begin
                    if(dx!=0 || dy!=0) $fatal(1,"Unexpected SOP");
                    er_acc='0; eb_acc='0; draw_red='0; draw_blue='0;
                    if(dframe>0 && previous_mode==seg_mode) begin draw_red=previous_red; draw_blue=previous_blue; end
                    check_snapshot=1;
                end
                if(seg_mask==1) er_acc=collect(er_acc,dx,dy,seg_data);
                if(seg_mask==2) eb_acc=collect(eb_acc,dx,dy,seg_data);
                graphics=reference_graphics(dx,dy,draw_red,draw_blue,seg_mode==2);
                t=u; t.data=(seg_overlay && graphics[30]) ? graphics[29:0] : overlay(seg_data,seg_mask,seg_overlay);
                output_q.push_back(t);
                if(seg_eop) begin
                    if(dx!=639 || dy!=479) $fatal(1,"Unexpected EOP");
                    er_acc.valid=er_acc.area>=32; eb_acc.valid=eb_acc.area>=32;
                    previous_red=finish_region(er_acc); previous_blue=finish_region(eb_acc); previous_mode=seg_mode;
                    dframe++;
                end
                if(dx==639) begin dx=0; if(dy==479) dy=0; else dy++;end else dx++;
            end
            if(diagnostics_u.frame_wait) begin wait_cycles++; if(wait_cycles>310) $fatal(1,"Frame arithmetic exceeded blanking budget"); end
            else begin if(wait_cycles>max_wait) max_wait=wait_cycles; wait_cycles=0; end
            if(held && {out_valid,out_data,out_sop,out_eop} !== {1'b1,held_payload}) $fatal(1,"Diagnostics output changed under backpressure");
            held=out_valid && !out_ready; held_payload={out_data,out_sop,out_eop};
            if(out_valid && out_ready) begin
                if(output_q.size()==0) $fatal(1,"Diagnostics extra pixel");
                u=output_q.pop_front();
                if({out_data,out_sop,out_eop} !== {u.data,u.sop,u.eop})
                    $fatal(1,"Diagnostics pixel/mask/box/text/SOP/EOP mismatch pixel=%0d",outputs);
                if(out_sop !== (outputs%307200==0) || out_eop !== (outputs%307200==307199)) $fatal(1,"Output packet alignment");
                outputs++;
                if(outputs==10*307200) begin
                    $display("PASS echo7_diagnostics_tb: 10 complete frames, framebuffer/dual clocks/2x scale, exact boxes and text, original/overlay, all modes, frame tags, continuous VGA timing, random backpressure, live movement/empty; max boundary wait=%0d",max_wait);
                    $finish;
                end
            end
        end
    end
    task automatic write_scene(input int phase);
        for(int j=0;j<240;j++) for(int i=0;i<320;i++) begin
            @(negedge wr_clk); wr_valid=1; wr_x=10'(2*i); wr_y=9'(2*j); wr_pixel=scene(i,j,phase);
        end
        @(negedge wr_clk); wr_valid=0;
    endtask
    initial begin
        repeat(4) @(negedge wr_clk); write_scene(0);
        repeat(4) @(negedge clk); reset=0;
        repeat(20) @(posedge clk); #1; beam_enabled=1;
        wait(sframe>=3); write_scene(1);
        wait(sframe>=6); write_scene(2);
        wait(sframe>=8); write_scene(0);
    end
    initial begin #300ms; $fatal(1,"Diagnostics integration timeout"); end
endmodule
