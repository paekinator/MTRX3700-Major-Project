// ECHO-7 team | AI-assisted by OpenAI Codex; human review required.
`timescale 1ns/1ps
module rotation_tb;
    import echo7_diag_pkg::*;
    import echo7_ref_pkg::*;
    import echo7_diag_ref_pkg::*;
    logic clk=0,wr_clk=0;
    always #20 clk=~clk;
    always #13 wr_clk=~wr_clk;
    logic reset=1,enable=0,wr_valid=0,ready=1;
    logic [9:0] wr_x=0;
    logic [8:0] wr_y=0;
    logic [15:0] wr_pixel=0;
    wire [8:0] rd_x;
    wire [7:0] rd_y;
    wire [15:0] rd_pixel;
    wire [29:0] pixel,sd,od;
    wire valid,sop,eop,ir,sv,sr,ss,se,so,sc,ov,os,oe;
    wire [1:0] sm,mode;
    logic [3:0] controls=4'b1010;
    frame_buffer #(.W(320),.H(240),.DW(16),.DECIMATE(2),.BUFFERS(1),.PACKED(0)) fb(
        .wr_clk,.wr_frame_start(1'b0),.wr_valid,.wr_x,.wr_y,.wr_pixel,
        .rd_clk(clk),.rd_x,.rd_y,.rd_pixel);
    camera_display #(.ROTATE_CCW_90(1)) display_u(.clk,.reset,.hold_enable(1'b1),
        .rd_x,.rd_y,.rd_pixel,.data(pixel),.startofpacket(sop),.endofpacket(eop),.valid,.ready(ir && enable));
    segmentationSelector #(.CONTROL_WIDTH(4),.STABLE_CYCLES(2)) selector_u(
        .clk,.reset,.control_async(controls),.in_data(pixel),.in_sop(sop),.in_eop(eop),.in_valid(valid && enable),.in_ready(ir),
        .out_data(sd),.out_sop(ss),.out_eop(se),.out_valid(sv),.out_ready(sr),
        .out_mask(sm),.out_overlay(so),.out_mode(mode),.out_calibration(sc));
    videoDiagnostics dut(.clk,.reset,.in_data(sd),.in_sop(ss),.in_eop(se),.in_valid(sv),.in_ready(sr),
        .in_mask(sm),.in_mode(mode),.in_overlay(so),.in_calibration(sc),
        .out_data(od),.out_sop(os),.out_eop(oe),.out_valid(ov),.out_ready(ready));
    function automatic logic [15:0] picture(input int x,y);
        // Asymmetric texture detects direction, scaling, row/column and prefetch errors.
        if(x>=120 && x<180 && y>=70 && y<110) return 16'hc924;
        if(x>=150 && x<210 && y>=130 && y<170) return 16'h2119;
        return {5'(x%16),6'(32+y%32),5'((x+3*y)%16)};
    endfunction
    function automatic logic [29:0] screen_pixel(input int x,y);
        int rotated_x,rotated_y;
        if(x<140 || x>=500) return 0;
        // Destination pixel centres rounded toward the preceding source pixel.
        rotated_x=((x-140)*240)/360;
        rotated_y=(y*320)/480;
        return video(picture(319-rotated_y,rotated_x));
    endfunction
    function automatic logic [30:0] calibration_graphics(input int x,y,input int m,
        input region_result_t a,input bit detected);
        string line_text;
        byte c;
        int line_no,ci,col,row;
        logic [34:0] bitmap;
        bit ink;
        if(x>=220 && x<=419 && y>=160 && y<=319 && (x==220 || x==419 || y==160 || y==319))
            return {1'b1,video(16'hf800)};
        if(x<16 || x>=244 || y<408 || y>=472) return 0;
        line_no=(y-408)/16; ci=(x-16)/12; col=((x-16)%12)/2; row=((y-408)%16)/2;
        case(line_no)
            0: case(m)
                1: line_text="MODE: RGB RATIO";
                2: line_text="MODE: HSV";
                default: line_text="MODE: FIXED RGB";
            endcase
            1: line_text=a.valid ? {"RGB: ",decimal_text(a.r),", ",decimal_text(a.g),", ",decimal_text(a.b)} : "RGB: ---, ---, ---";
            2: line_text=a.valid ? {"HSV: ",decimal_text(a.h),", ",decimal_text(a.s),", ",decimal_text(a.v)} : "HSV: ---, ---, ---";
            3: line_text=!a.valid ? "DETECT: ---" : detected ? "DETECT: YES" : "DETECT: NO";
        endcase
        c=ci<line_text.len() ? line_text[ci] : " "; bitmap=reference_font(c);
        ink=(col<5 && row<7) && ((bitmap>>(5*(6-row)+4-col))&1);
        return {1'b1,ink ? video(16'hffff) : 30'd0};
    endfunction

    transaction q[$],t,u;
    region_acc_t sample_acc,red_acc,blue_acc;
    region_result_t previous_sample,previous_red,previous_blue,draw_sample,draw_red,draw_blue;
    int input_index=0,seg_index=0,frames=0,outputs=0,count=0,previous_count=0,previous_mode=-1;
    bit held=0,random_stall=0;
    logic [31:0] held_payload;
    logic [30:0] graphics;
    logic [15:0] raw565;
    int x,y;
    always @(negedge clk) ready=!random_stall || $urandom_range(0,4)!=0;
    always @(posedge clk) begin
        if(reset) begin
            q.delete();held=0;input_index=0;seg_index=0;previous_mode=-1;previous_count=0;count=0;
            previous_sample='0;previous_red='0;previous_blue='0;
            sample_acc='0;red_acc='0;blue_acc='0;
            draw_sample='0;draw_red='0;draw_blue='0;
        end else begin
            if(valid && enable && ir) begin
                if(pixel!==screen_pixel(input_index%640,input_index/640))
                    $fatal(1,"Rotation pixel mismatch at %0d got=%h expected=%h",input_index,pixel,screen_pixel(input_index%640,input_index/640));
                if(sop!==(input_index==0) || eop!==(input_index==307199)) $fatal(1,"Display packet alignment");
                input_index=(input_index+1)%307200;
            end
            if(sv && sr) begin
                x=seg_index%640;y=seg_index/640;
                if(sd!==screen_pixel(x,y) || mode!=2 || sc!==controls[3] || so!==controls[2])
                    $fatal(1,"Selector pixel/control alignment");
                raw565={sd[29:25],sd[19:14],sd[9:5]};
                if(sm!==classify(raw565,2)) $fatal(1,"HSV mismatch");
                if(ss) begin
                    if(seg_index!=0) $fatal(1,"Unexpected SOP");
                    sample_acc='0;red_acc='0;blue_acc='0;count=0;
                    draw_sample='0;draw_red='0;draw_blue='0;
                    if(previous_mode==2) begin draw_sample=previous_sample;draw_red=previous_red;draw_blue=previous_blue;end
                end
                if(sc) graphics=calibration_graphics(x,y,2,draw_sample,previous_count>=32);
                else graphics=so ? reference_graphics(x,y,draw_red,draw_blue,1) : 31'd0;
                t.data=overlay(sd,sm,so && (!sc || (x>=220 && x<=419 && y>=160 && y<=319)));
                if(graphics[30]) t.data=graphics[29:0];
                t.sop=ss;t.eop=se;t.mask=0;t.enable=0;q.push_back(t);
                if(x>=310 && x<=329 && y>=230 && y<=249) sample_acc=collect(sample_acc,x,y,sd);
                if(x>=220 && x<=419 && y>=160 && y<=319 && sm!=0) count++;
                if(sm==1) red_acc=collect(red_acc,x,y,sd);
                if(sm==2) blue_acc=collect(blue_acc,x,y,sd);
                if(se) begin
                    if(seg_index!=307199) $fatal(1,"Unexpected EOP");
                    sample_acc.valid=1;red_acc.valid=red_acc.area>=32;blue_acc.valid=blue_acc.area>=32;
                    previous_sample=finish_region(sample_acc);previous_red=finish_region(red_acc);previous_blue=finish_region(blue_acc);
                    previous_mode=2;previous_count=count;frames++;
                end
                seg_index=(seg_index+1)%307200;
            end
            if(held && {ov,od,os,oe}!=={1'b1,held_payload}) $fatal(1,"Stalled output changed");
            held=ov&&!ready;held_payload={od,os,oe};
            if(ov && ready) begin
                if(q.size()==0) $fatal(1,"Extra output");u=q.pop_front();
                if({od,os,oe}!=={u.data,u.sop,u.eop}) $fatal(1,"Rotated ROI/mask/text mismatch at output %0d",outputs);
                outputs++;
            end
        end
    end
    task automatic frame(input logic [3:0] c,input bit stalls);
        @(negedge clk);controls=c;random_stall=stalls;
        repeat(15) @(negedge clk);enable=1;
        for(int p=0;p<307200;p++) begin
            @(posedge clk);while(!ir) @(posedge clk);
            @(negedge clk);
        end
        enable=0;wait(!sv && !ov && q.size()==0);
        repeat(350) @(negedge clk);
        if(dut.calibration_u.result_sample!==previous_sample) $fatal(1,"Rotated central mean mismatch");
        if(dut.calibration_u.detected_snapshot!==(previous_count>=32)) $fatal(1,"Rotated DETECT mismatch");
    endtask
    initial begin
        for(int yy=0;yy<240;yy++) for(int xx=0;xx<320;xx++) begin
            @(negedge wr_clk);wr_valid=1;wr_x=10'(xx*2);wr_y=9'(yy*2);wr_pixel=picture(xx,yy);
        end
        @(negedge wr_clk);wr_valid=0;
        repeat(4) @(negedge clk);reset=0;
        frame(4'b1010,0);frame(4'b1010,0);
        frame(4'b1110,1);frame(4'b1110,1);
        frame(4'b0110,1);frame(4'b0010,1);
        // Reset at a partially transmitted frame, then verify the raster restarts correctly.
        @(negedge clk);enable=1;
        repeat(1000) @(negedge clk);
        reset=1;enable=0;repeat(4) @(negedge clk);reset=0;
        frame(4'b1110,1);
        $display("PASS rotation_tb: %0d full frames, %0d output pixels, CCW mapping, 360x480 portrait, black bars, all corners, original means, HSV/ROI/masks/dynamic boxes, continuous throughput, random stalls and mid-frame reset",frames,outputs);
        $finish;
    end
    initial begin #1000000000;$fatal(1,"Timeout");end
endmodule
