// ECHO-7 team | AI-assisted by OpenAI Codex; human review pending.
`timescale 1ns/1ps
module colourRegionStats_tb;
    import echo7_diag_pkg::*;
    import echo7_diag_ref_pkg::*;
    import echo7_ref_pkg::*;
    logic clk=0; always #20 clk=~clk;
    logic reset=1,ce=0,in_valid=0,in_sop=0,in_eop=0;
    logic [29:0] in_data=0;
    logic [1:0] in_mask=0,in_mode=0;
    wire [9:0] pixel_x;
    wire [8:0] pixel_y;
    wire pixel_tracked,frame_done,frame_error;
    wire [1:0] frame_mode;
    wire [15:0] frame_id;
    region_acc_t red_stats,blue_stats;
    colourRegionStats #(.H_RES(16),.V_RES(12),.MIN_AREA(3)) dut(
        .clk,.reset,.ce,.in_valid,.in_sop,.in_eop,.in_data,.in_mask,.in_mode,
        .pixel_x,.pixel_y,.pixel_tracked,.frame_done,.frame_error,.frame_mode,.frame_id,.red_stats,.blue_stats,
        .red_xmin(),.red_xmax(),.red_ymin(),.red_ymax(),.red_area(),.red_valid(),
        .blue_xmin(),.blue_xmax(),.blue_ymin(),.blue_ymax(),.blue_area(),.blue_valid());
    logic big_valid=0,big_sop=0,big_eop=0;
    wire big_done,big_error;
    region_acc_t big_red,big_blue;
    colourRegionStats big(.clk,.reset,.ce(1'b1),.in_valid(big_valid),.in_sop(big_sop),.in_eop(big_eop),
        .in_data({8'hff,2'b00,8'hff,2'b00,8'hff,2'b00}),.in_mask(2'b01),.in_mode(2'b00),
        .pixel_x(),.pixel_y(),.pixel_tracked(),.frame_done(big_done),.frame_error(big_error),.frame_mode(),.frame_id(),
        .red_stats(big_red),.blue_stats(big_blue),
        .red_xmin(),.red_xmax(),.red_ymin(),.red_ymax(),.red_area(),.red_valid(),
        .blue_xmin(),.blue_xmax(),.blue_ymin(),.blue_ymax(),.blue_area(),.blue_valid());
    function automatic logic [1:0] shape(input int scene,x,y);
        case(scene)
            0: return (x>=3 && x<=8 && y>=2 && y<=6) ? 1:0;
            1: return (x>=9 && x<=14 && y>=4 && y<=10) ? 2:0;
            2: return x<5 && y<5 ? 1 : (x>9 && y>5 ? 2:0);
            3: return (x-5)*(x-5)+(y-5)*(y-5)<=9 ? 1 : (x>=10 && y>=x-9 && y<=8 ? 2:0);
            4: return x>=11 && x<=12 && y>=1 && y<=2 ? 1:0;
            5: return 0;
            6: return x==4 && y==7 ? 1 : (x==14 && y==2 ? 2:0);
            7: return (x<2 && y<2) || (x>12 && y>8) ? 1:0;
            8: return x==0 || y==0 ? 1 : (x==15 || y==11 ? 2:0);
            9: return 1;
            default: return 3;
        endcase
    endfunction
    task automatic scan(input int scene,input bit missing_eop=0,input bit mode_change=0);
        region_acc_t er,eb;
        er='0; eb='0;
        for(int y=0;y<12;y++) for(int x=0;x<16;x++) begin
            @(negedge clk);
            in_valid=1; in_sop=(x==0 && y==0); in_eop=(x==15 && y==11 && !missing_eop);
            in_mode=(mode_change && y>5) ? 2'b10 : 2'b00;
            in_mask=shape(scene,x,y); in_data=video({5'(16+x),6'(y*5),5'(x+y)}); ce=0;
            if((x+y*16)%19==0) repeat(3) @(negedge clk);
            ce=1;
            if(in_mask==1) er=collect(er,x,y,in_data);
            if(in_mask==2) eb=collect(eb,x,y,in_data);
            @(posedge clk); #1;
            if(x==15 && y==11) begin
                er.valid=(er.area>=3 && !missing_eop && !mode_change);
                eb.valid=(eb.area>=3 && !missing_eop && !mode_change);
                if(!frame_done || frame_error!==(missing_eop || mode_change)) $fatal(1,"Frame completion/error mismatch");
                if(red_stats!==er || blue_stats!==eb) $fatal(1,"Stats mismatch scene=%0d red_area=%0d expected=%0d",scene,red_stats.area,er.area);
            end
            if((x+y*16)%23==0) begin
                @(negedge clk); in_valid=0; in_mask=1; in_sop=0; in_eop=0;
                repeat(2) @(negedge clk);
            end
        end
        @(negedge clk); in_valid=0; ce=0;
    endtask
    initial begin
        repeat(3) @(negedge clk); reset=0;
        for(int scene=0;scene<11;scene++) scan(scene);
        scan(2,1,0); scan(2,0,1); scan(0);
        @(negedge clk); ce=1; in_valid=1; in_sop=1; in_eop=1; in_mask=1;
        @(posedge clk); #1;
        if(!frame_done || !frame_error || red_stats.valid) $fatal(1,"Short frame must be rejected");
        @(negedge clk); in_sop=1; in_eop=0;
        @(negedge clk); reset=1; in_valid=0;
        @(negedge clk); if(red_stats.valid || blue_stats.valid || frame_done) $fatal(1,"Stats reset");
        reset=0; scan(4);
        // Full default-resolution accumulation proves the maximum area/sums do not wrap.
        @(negedge clk); ce=0; in_valid=0;
        for(int p=0;p<307200;p++) begin
            @(negedge clk); big_valid=1; big_sop=(p==0); big_eop=(p==307199);
        end
        @(posedge clk); #1;
        if(!big_done || big_error || !big_red.valid || big_red.overflow || big_red.area!=307200 ||
           big_red.sum_r!=78336000 || big_red.sum_g!=78336000 || big_red.sum_b!=78336000 ||
           big_red.xmin!=0 || big_red.ymin!=0 || big_red.xmax!=639 || big_red.ymax!=479)
            $fatal(1,"Maximum frame counter/sum/extents mismatch");
        $display("PASS colourRegionStats_tb: red/blue/both, circle/triangle, movement/shrink, empty/noise, aggregate, edges, CE/invalid, packets/reset, full-frame counter limits");
        $finish;
    end
    initial begin #30ms; $fatal(1,"Stats timeout"); end
endmodule
