// ECHO-7 Phase 1 | Owner: MTRX3700 ECHO-7 team; human review required.
// AI-assisted test code: OpenAI Codex. See OWNERS.md and AI_STATEMENT.md.
`timescale 1ns/1ps
module echo7_integration_tb;
    import echo7_ref_pkg::*;
    logic clk=0,wr_clk=0; always #20 clk=~clk; always #12.5 wr_clk=~wr_clk;
    logic reset=1,wr_valid=0;
    logic [9:0] wr_x=0; logic [8:0] wr_y=0; logic [15:0] wr_pixel=0;
    wire [8:0] rd_x; wire [7:0] rd_y; wire [15:0] rd_pixel;
    wire [29:0] in_data,seg_data,out_data;
    wire in_sop,in_eop,in_valid,in_ready,seg_sop,seg_eop,seg_valid,seg_ready,seg_overlay;
    wire out_sop,out_eop,out_valid; logic out_ready=0;
    wire [1:0] seg_mask;
    logic [2:0] control_async=0;
    frame_buffer fb(.wr_clk,.wr_frame_start(1'b0),.wr_valid,.wr_x,.wr_y,.wr_pixel,
        .rd_clk(clk),.rd_x,.rd_y,.rd_pixel);
    camera_display display_u(.clk,.reset,.hold_enable(1'b1),.rd_x,.rd_y,.rd_pixel,
        .data(in_data),.startofpacket(in_sop),.endofpacket(in_eop),.valid(in_valid),.ready(in_ready));
    segmentationSelector #(.STABLE_CYCLES(4)) selector_u(.clk,.reset,.control_async,
        .in_data,.in_sop,.in_eop,.in_valid,.in_ready,
        .out_data(seg_data),.out_sop(seg_sop),.out_eop(seg_eop),.out_valid(seg_valid),.out_ready(seg_ready),
        .out_mask(seg_mask),.out_overlay(seg_overlay));
    vgaMaskOverlay overlay_u(.clk,.reset,.in_data(seg_data),.in_mask(seg_mask),.in_overlay(seg_overlay),
        .in_sop(seg_sop),.in_eop(seg_eop),.in_valid(seg_valid),.in_ready(seg_ready),
        .out_data,.out_sop,.out_eop,.out_valid,.out_ready);
    // Multiple irregular regions and isolated pixels, never a fixed overlay rectangle.
    function automatic logic [15:0] scene(input int x,input int y);
        if(((x-55)*(x-55)+(y-60)*(y-60)<500) || ((x+y)%71==0)) return 16'hc924;
        if(((x-210)*(x-210)+(y-160)*(y-160)<1000) || ((x*3+y)%113==0)) return 16'h211a;
        return {5'(x%20),6'(20+y%30),5'(x%12)};
    endfunction
    function automatic logic [2:0] config_for(input int f);
        case(f)
            0: return 3'b000;
            1: return 3'b100;
            2: return 3'b101;
            3: return 3'b110;
            4: return 3'b111;
            5: return 3'b010;
            default: return 3'b110;
        endcase
    endfunction
    transaction q[$],t,u;
    int x=0,y=0,frame=0,output_count=0,cycle=0;
    logic [2:0] cfg;
    bit held=0; logic [31:0] held_payload;
    always @(negedge clk) begin
        // Model active video, line blanking and occasional longer/random backpressure.
        out_ready=!reset && (cycle%800<640) && (cycle%420000<384000) && ($urandom_range(0,15)!=0);
        if(!reset && x>=100 && y==0) control_async=config_for(frame+1);
    end
    always @(posedge clk) begin
        cycle++;
        if(!reset) begin
            if(in_valid && in_ready) begin
                if(frame<6 && in_data !== video(scene(x/2,y/2))) $fatal(1,"Framebuffer scaling mismatch x=%0d y=%0d",x,y);
                if(in_sop !== (x==0 && y==0) || in_eop !== (x==639 && y==479)) $fatal(1,"Source packet mismatch");
                cfg=config_for(frame);
                t.data=overlay(in_data,classify({in_data[29:25],in_data[19:14],in_data[9:5]},int'(cfg[1:0])),cfg[2]);
                t.sop=in_sop; t.eop=in_eop; t.mask=0; t.enable=0; q.push_back(t);
                if(x==639) begin x=0; if(y==479) begin y=0; frame++; end else y++; end else x++;
            end
            if(held && {out_valid,out_data,out_sop,out_eop} !== {1'b1,held_payload}) $fatal(1,"Integration stall violation");
            held=out_valid&&!out_ready; held_payload={out_data,out_sop,out_eop};
            if(out_valid && out_ready) begin
                if(q.size()==0) $fatal(1,"Unexpected integration output");
                u=q.pop_front();
                if({out_data,out_sop,out_eop} !== {u.data,u.sop,u.eop}) $fatal(1,"Integration mask/pixel/packet mismatch at %0d",output_count);
                output_count++;
                if(output_count==8*640*480) begin
                    $display("PASS echo7_integration_tb: 8 full 640x480 frames, dual clocks, scaling, all modes, irregular regions, stalls, concurrent writes");
                    $finish;
                end
            end
        end
    end
    initial begin
        repeat(4) @(negedge wr_clk);
        for(int j=0;j<240;j++) for(int i=0;i<320;i++) begin
            @(negedge wr_clk); wr_valid=1; wr_x=10'(2*i); wr_y=9'(2*j); wr_pixel=scene(i,j);
        end
        @(negedge wr_clk); wr_valid=0;
        repeat(4) @(negedge wr_clk);
        repeat(4) @(negedge clk); reset=0;
        // After six static frames, exercise live RAM overwrites during display stalls.
        wait(frame>=6);
        forever begin
            for(int j=0;j<240;j++) for(int i=0;i<320;i++) begin
                @(negedge wr_clk); wr_valid=1; wr_x=10'(2*i); wr_y=9'(2*j);
                wr_pixel=16'($urandom);
            end
        end
    end
    initial begin #300ms; $fatal(1,"Integration timeout"); end
endmodule
