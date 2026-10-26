// ECHO-7 team | AI-assisted self-checking test; human review required.
`timescale 1ns/1ps
module roiCalibration_tb;
    import echo7_diag_pkg::*;
    import echo7_ref_pkg::*;
    import echo7_diag_ref_pkg::*;
    logic clk=0; always #20 clk=~clk;
    logic reset=1, iv=0, sop=0, eop=0, ready=1;
    logic [3:0] controls=0;
    logic [29:0] pixel=0;
    wire ir,sv,sr,ss,se,so,sc,ov,os,oe;
    wire [1:0] sm,mode;
    wire [29:0] sd,od;
    segmentationSelector #(.CONTROL_WIDTH(4),.STABLE_CYCLES(2)) selector_u(
        .clk,.reset,.control_async(controls),.in_data(pixel),.in_sop(sop),.in_eop(eop),.in_valid(iv),.in_ready(ir),
        .out_data(sd),.out_sop(ss),.out_eop(se),.out_valid(sv),.out_ready(sr),
        .out_mask(sm),.out_overlay(so),.out_mode(mode),.out_calibration(sc));
    videoDiagnostics dut(.clk,.reset,.in_data(sd),.in_sop(ss),.in_eop(se),.in_valid(sv),.in_ready(sr),
        .in_mask(sm),.in_mode(mode),.in_overlay(so),.in_calibration(sc),
        .out_data(od),.out_sop(os),.out_eop(oe),.out_valid(ov),.out_ready(ready));
    transaction queue[$], t, u;
    region_acc_t sample_acc,red_acc,blue_acc;
    region_result_t previous_sample,previous_red,previous_blue,draw_sample,draw_red,draw_blue;
    int px=0,py=0,count=0,previous_count=0,previous_mode=-1,frames=0,outputs=0;
    bit held=0, force_stall=0, random_stall=1;
    logic [31:0] held_payload;
    logic [3:0] expected_control=0;
    logic [30:0] graphics;
    logic [15:0] original565;

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
    always @(negedge clk) ready=!force_stall && (!random_stall || $urandom_range(0,4)!=0);
    always @(posedge clk) begin
        if(reset) begin
            queue.delete(); held=0; px=0;py=0;count=0;previous_count=0;previous_mode=-1;
            previous_sample='0;previous_red='0;previous_blue='0;
            draw_sample='0;draw_red='0;draw_blue='0;
            sample_acc='0;red_acc='0;blue_acc='0;
        end else begin
            if(sv && sr) begin
                if({sc,so,mode}!==expected_control) $fatal(1,"Switch tags not frame coherent");
                original565={sd[29:25],sd[19:14],sd[9:5]};
                if(sm!==classify(original565,mode)) $fatal(1,"Selected algorithm mismatch");
                if(ss) begin
                    px=0;py=0;count=0;sample_acc='0;red_acc='0;blue_acc='0;
                    draw_sample='0;draw_red='0;draw_blue='0;
                    if(previous_mode==int'(mode)) begin
                        draw_sample=previous_sample; draw_red=previous_red; draw_blue=previous_blue;
                    end
                end
                if(sc) graphics=calibration_graphics(px,py,mode,draw_sample,previous_count>=32);
                else graphics=so ? reference_graphics(px,py,draw_red,draw_blue,mode==2) : 31'd0;
                t.data=sc ? overlay(sd,sm,so && px>=220 && px<=419 && py>=160 && py<=319)
                          : overlay(sd,sm,so);
                if(graphics[30]) t.data=graphics[29:0];
                t.sop=ss;t.eop=se;t.mask=0;t.enable=0;queue.push_back(t);
                if(px>=310 && px<=329 && py>=230 && py<=249) sample_acc=collect(sample_acc,px,py,sd);
                if(px>=220 && px<=419 && py>=160 && py<=319 && sm!=0) count++;
                if(sm==1) red_acc=collect(red_acc,px,py,sd);
                if(sm==2) blue_acc=collect(blue_acc,px,py,sd);
                if(se) begin
                    if(px!=639 || py!=479) $fatal(1,"EOP coordinate mismatch");
                    sample_acc.valid=1;red_acc.valid=red_acc.area>=32;blue_acc.valid=blue_acc.area>=32;
                    previous_sample=finish_region(sample_acc);previous_red=finish_region(red_acc);previous_blue=finish_region(blue_acc);
                    previous_mode=int'(mode);previous_count=count;frames++;
                end
                if(px==639) begin px=0;py++;end else px++;
            end
            if(held && {ov,od,os,oe}!=={1'b1,held_payload}) $fatal(1,"Backpressure changed payload");
            held=ov&&!ready;held_payload={od,os,oe};
            if(ov && ready) begin
                if(queue.size()==0) $fatal(1,"Unsolicited output");
                u=queue.pop_front();
                if({od,os,oe}!=={u.data,u.sop,u.eop})
                    $fatal(1,"Output mismatch beat=%0d got=%h expected=%h frame=%0d",outputs,{od,os,oe},{u.data,u.sop,u.eop},frames);
                outputs++;
            end
        end
    end
    function automatic logic [15:0] scene(input int n,x,y);
        logic [15:0] p;
        p=16'h4208;
        // Outside distractors must never make ROI DETECT true.
        if(x<80 && y<80) p=16'hc924;
        if(x>550 && y<100) p=16'h2119;
        if(n==0 || n==1) begin
            if(x>=310 && x<=329 && y>=230 && y<=249) p=(x&1) ? 16'h0000 : 16'hffff;
        end
        if(n==2 || n==3) begin
            if(x>=220 && x<220+(n==2 ? 31 : 32) && y==160) p=16'hf800;
            if(x>=310 && x<=329 && y>=230 && y<=249) p=16'h0800;
        end
        if(n==4 || n==5) begin
            if(x>=310 && x<=329 && y>=230 && y<=249) p=16'hb9a5;
            if(x>=390 && x<=419 && y>=300 && y<=319) p=16'h001f;
        end
        if(n==6 || n==7) begin
            // One framebuffer noise sample expands to four displayed pixels.
            if(x>=418 && x<=419 && y>=318 && y<=319) p=16'h001f;
            if(x>=310 && x<=329 && y>=230 && y<=249) p=16'h0000;
        end
        if(n>=8) begin
            if(x>=310 && x<=329 && y>=230 && y<=249) p=16'hc924;
            if(x>=250 && x<280 && y>=180 && y<210) p=16'h2119;
            // Cross all four edges: coloured pixels outside must remain original.
            if(x>=218 && x<=421 && y>=158 && y<=321 &&
               (x<=221 || x>=418 || y<=161 || y>=318)) p=16'h2119;
        end
        return p;
    endfunction
    task automatic send_frame(input int n,input logic [3:0] control);
        wait(queue.size()==0 && !ov && !sv);
        @(negedge clk);controls=control;expected_control=control;
        repeat(12) @(negedge clk);
        for(int p=0;p<640*480;p++) begin
            pixel=video(scene(n,p%640,p/640));iv=1;sop=p==0;eop=p==640*480-1;
            // Mid-frame switch activity cannot affect the current frame.
            if(p==1000) controls=~control;
            if(p==1100) controls=control;
            @(posedge clk);while(!ir) @(posedge clk);
            @(negedge clk);
        end
        iv=0;sop=0;eop=0;
        wait(queue.size()==0 && !sv && !ov);
        repeat(350) @(negedge clk);
        if(dut.calibration_u.result_sample!==previous_sample)
            $fatal(1,"Measured RGB/HSV/BCD differs from independent arithmetic reference");
        if(dut.calibration_u.detected_snapshot!==(previous_count>=32)) $fatal(1,"DETECT threshold mismatch");
        if(n==0 || n==1 || n==2 || n==6 || n==7)
            if(previous_count>=32) $fatal(1,"Outside/noise/no-target fixture unexpectedly detected");
        if(n==3 && previous_count!=32) $fatal(1,"Exact threshold fixture must contain 32 hits");
    endtask
    initial begin
        repeat(4) @(negedge clk);reset=0;
        send_frame(0,4'b1000);send_frame(1,4'b1000);
        send_frame(2,4'b1001);send_frame(3,4'b1001);
        send_frame(4,4'b1010);send_frame(5,4'b1010);
        send_frame(6,4'b1100);send_frame(7,4'b1100);
        send_frame(8,4'b0100);send_frame(9,4'b0100); // Dynamic boxes regression.
        send_frame(10,4'b0000); // Raw dynamic view.
        send_frame(11,4'b1111);send_frame(12,4'b1111); // Reserved mode -> Fixed RGB.
        // Same non-primary scene, SW3 off/on in each algorithm. Means must not change.
        send_frame(13,4'b1000);send_frame(13,4'b1100);
        send_frame(13,4'b1001);send_frame(13,4'b1101);
        send_frame(13,4'b1010);send_frame(13,4'b1110);
        // Reset during a held pixel; no stale snapshot may survive.
        force_stall=1; @(negedge clk);iv=1;sop=1;pixel=0;
        @(posedge clk);while(!ir) @(posedge clk);
        @(negedge clk);iv=0;sop=0;repeat(8) @(negedge clk);
        reset=1;repeat(4) @(negedge clk);
        if(ov || dut.calibration_u.display_measurement.valid || dut.calibration_u.display_detected)
            $fatal(1,"Reset retained state");
        force_stall=0;reset=0;
        send_frame(0,4'b1000);send_frame(1,4'b1000);
        $display("PASS roiCalibration_tb: %0d full frames, %0d checked pixels, ROI edges, sample means, HSV, 31/32 threshold, outside distractors, noise, switches, dynamic/raw regression, reset, randomized backpressure",frames,outputs);
        $finish;
    end
    initial begin #1000000000; $fatal(1,"Timeout"); end
endmodule
