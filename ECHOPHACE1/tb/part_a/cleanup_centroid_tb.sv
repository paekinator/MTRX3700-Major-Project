`timescale 1ns/1ps
module cleanup_centroid_tb;
    localparam int W=16,H=12;
    logic clk=0; always #5 clk=~clk;
    logic reset=1,iv=0,sop=0,eop=0;
    logic [8:0] x=0;
    logic [7:0] y=0;
    logic [1:0] mask=0;
    wire ov,os,oe;
    wire [8:0] ox;
    wire [7:0] oy;
    wire [1:0] om;
    causalMaskCleanup #(.WIDTH(W)) cleanup(
        .clk,.reset,.in_valid(iv),.in_sop(sop),.in_eop(eop),.in_x(x),.in_y(y),.in_mask(mask),
        .out_valid(ov),.out_sop(os),.out_eop(oe),.out_x(ox),.out_y(oy),.out_mask(om));
    wire done,fv,fe,overrun,busy,rv,bv;
    wire [15:0] fid;
    wire [16:0] ra,ba;
    wire [8:0] rx,bx;
    wire [7:0] ry,by;
    rawColourCentroid #(.WIDTH(W),.HEIGHT(H),.MIN_AREA(1)) baseline(
        .clk,.reset,.in_valid(iv),.in_sop(sop),.in_eop(eop),.in_x(x),.in_y(y),.in_mask(mask),
        .out_valid(done),.frame_valid(fv),.frame_error(fe),.overrun,.busy,.frame_id(fid),
        .red_valid(rv),.blue_valid(bv),.red_area(ra),.blue_area(ba),
        .red_cx(rx),.red_cy(ry),.blue_cx(bx),.blue_cy(by));
    int image[H][W];
    int cr,cb,sxr,syr,sxb,syb;
    int checks=0;
    task automatic idle(input int clocks);
        for(int i=0;i<clocks;i++) begin
            @(negedge clk); iv=0; sop=0; eop=0;
            @(posedge clk); #1;
            if(ov) $fatal(1,"cleanup invented a valid pixel");
        end
    endtask
    task automatic frame(input int pattern,input bit corrupt);
        int expected;
        cr=0;cb=0;sxr=0;syr=0;sxb=0;syb=0;
        for(int j=0;j<H;j++) for(int i=0;i<W;i++) begin
            case(pattern)
                0: image[j][i]=0;
                1: image[j][i]=1;
                2: image[j][i]=(i<5 && j<4)?1:((i>=10 && j>=7)?2:0);
                // Reserved mask and isolated first/last-pixel foreground included.
                3: image[j][i]=((i==0&&j==0)||(i==W-1&&j==H-1))?1:3;
                default: image[j][i]=((i*13+j*7)%5<2)?1:((i+j)%7==0?2:0);
            endcase
        end
        for(int j=0;j<H;j++) for(int i=0;i<W;i++) begin
            if(image[j][i]==1) begin cr++;sxr+=i;syr+=j;end
            if(image[j][i]==2) begin cb++;sxb+=i;syb+=j;end
            expected=0;
            if(image[j][i]==1 || image[j][i]==2)
                if((i>0 && image[j][i-1]==image[j][i]) ||
                   (j>0 && image[j-1][i]==image[j][i])) expected=image[j][i];
            if((i+j)%11==0) idle(2); // accepted-pixel gaps must not move neighbours
            @(negedge clk);
            iv=1;sop=(i==0&&j==0);eop=(i==W-1&&j==H-1);
            x=9'(i);y=8'(j);mask=2'(image[j][i]);
            if(corrupt && i==7 && j==3) x=9'd8;
            @(posedge clk); #1;
            if(!ov || os!=sop || oe!=eop || ox!=x || oy!=y) $fatal(1,"pixel alignment");
            if(!corrupt && om!=2'(expected)) $fatal(1,"cleanup mismatch (%0d,%0d)",i,j);
            checks++;
        end
        @(negedge clk);iv=0;sop=0;eop=0;
        begin : await_result
            bit got; got=0;
            for(int n=0;n<40;n++) begin
                @(posedge clk);#1;
                if(done) begin got=1;break;end
            end
            if(!got) $fatal(1,"baseline publication timeout");
        end
        if(fv==corrupt || fe!=corrupt || overrun) $fatal(1,"frame validity");
        if(ra!=cr || ba!=cb || rv!=(!corrupt&&cr>0) || bv!=(!corrupt&&cb>0))
            $fatal(1,"baseline areas/valid");
        if(cr>0 && (rx!=sxr/cr || ry!=syr/cr)) $fatal(1,"red centroid arithmetic");
        if(cb>0 && (bx!=sxb/cb || by!=syb/cb)) $fatal(1,"blue centroid arithmetic");
        if(cr==0 && (rx!=0 || ry!=0)) $fatal(1,"empty red must be zero");
        if(cb==0 && (bx!=0 || by!=0)) $fatal(1,"empty blue must be zero");
        idle(2);
    endtask
    initial begin
        repeat(3) @(posedge clk);
        @(negedge clk);reset=0;
        @(negedge clk);iv=1;sop=1;eop=1;x=0;y=0;mask=1;
        @(posedge clk);#1;
        @(negedge clk);iv=0;sop=0;eop=0;
        begin : short_frame
            bit got;got=0;
            for(int i=0;i<40;i++) begin @(posedge clk);#1;if(done) begin got=1;break;end end
            if(!got || fv || !fe || rv || bv || fid!=1) $fatal(1,"short SOP/EOP frame must publish invalid");
        end
        idle(2);
        frame(0,0);frame(1,0);frame(2,0);frame(3,1);frame(4,0);frame(2,1);
        // Partial-frame reset must discard both neighbourhood and accumulation.
        @(negedge clk);iv=1;sop=1;x=0;y=0;mask=1;
        @(posedge clk);#1;
        @(negedge clk);reset=1;iv=0;sop=0;
        repeat(2) @(posedge clk);
        @(negedge clk);reset=0;
        frame(2,0);
        if(fid!=1) $fatal(1,"reset must restart frame sequence");
        $display("PASS cleanup_centroid_tb: %0d pixel checks, empty/full/two-colour/noise/gaps/reset/malformed",checks);
        $finish;
    end
    initial begin #1000000;$fatal(1,"testbench watchdog");end
endmodule
