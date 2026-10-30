`timescale 1ns/1ps
// ECHO-7 Part A | Human owner: Member A (name/SID pending).
// AI-assisted by OpenAI Codex; independent hand-calculated rectangular scenes.
// V2: EPA2/N78, reclaimed-label row budgets and real two-PCLK RGB565 cadence.
// Colours/coordinates are native capture coordinates, not rotated VGA pixels.
// Run with Verilator so the course snapshot RAM/probes use their simulation models.
module partACapturePipeline_tb;
    parameter int RATIO_RED_MIN_VALUE=64, RATIO_BLUE_MIN_VALUE=32;
    localparam int N=78, W=320, H=240, CAP=8, ROW_IDLE_REQUIRED=W+CAP;
    // Deliberately omit extra horizontal/vertical blanking. The skipped odd
    // sensor row ALONE must provide enough time for row sealing/publication.
    localparam int HBLANK=0, VBLANK=0;
    localparam int PIX0=7+2*N, CRC_ADDR=PIX0+W*H;
    logic pclk=0;
    always #25 pclk=~pclk; // 20 MHz sensor PCLK; a RGB565 word takes two clocks.
    logic reset=1, camera_frame_start=0, px_valid=0, trigger=0;
    logic [15:0] pixel=0;
    logic [9:0] px_x=0;
    logic [8:0] px_y=0;
    logic [3:0] control_async=0;
    logic [N*32-1:0] snapshot_results, first_packet;
    wire snap_busy,snap_ready;
    int checks=0;
    longint cycles=0, last_clean_edge=-1, last_clean_eop=-1, last_sensor_eop=-1;
    longint min_row_idle=64'h7fff_ffff_ffff_ffff;
    longint min_eop_to_boundary=64'h7fff_ffff_ffff_ffff;
    longint min_sensor_eop_to_boundary=64'h7fff_ffff_ffff_ffff;
    int previous_clean_x=-1, previous_clean_y=-1, measured_rows=0, measured_boundaries=0;

    partACapturePipeline #(.W(W),.H(H),.CAP(CAP),.MIN_AREA(32),.CONTROL_STABLE_CYCLES(4),
        .RATIO_RED_MIN_VALUE(RATIO_RED_MIN_VALUE),.RATIO_BLUE_MIN_VALUE(RATIO_BLUE_MIN_VALUE)) dut(.*);
    frame_snap #(.MODE(0),.N_RESULTS(N)) snap_u (
        .pclk, .reset, .frame_start(camera_frame_start), .px_valid, .pixel,
        .x(px_x), .y(px_y), .results(snapshot_results), .trigger,
        .busy(snap_busy), .ready(snap_ready));

    // Observe the actual inputs consumed by CCL, before sequential NBA updates.
    // The row gap counts INVALID clocks, while EOP-to-boundary counts edge distance.
    always @(posedge pclk) begin
        cycles<=cycles+1;
        if(reset)begin
            last_clean_edge=-1;last_clean_eop=-1;last_sensor_eop=-1;
            previous_clean_x=-1;previous_clean_y=-1;
        end else begin
            if(dut.native_eop)last_sensor_eop=cycles;
            if(dut.clean_valid)begin
                if(dut.clean_x==0 && dut.clean_y>0 && previous_clean_x==W-1 &&
                   int'(dut.clean_y)==previous_clean_y+1)begin
                    if(cycles-last_clean_edge-1<min_row_idle)min_row_idle=cycles-last_clean_edge-1;
                    measured_rows++;
                    if(cycles-last_clean_edge-1<ROW_IDLE_REQUIRED)
                        $fatal(1,"FAIL native row idle budget %0d below %0d",cycles-last_clean_edge-1,ROW_IDLE_REQUIRED);
                end
                last_clean_edge=cycles;
                previous_clean_x=int'(dut.clean_x);previous_clean_y=int'(dut.clean_y);
                if(dut.clean_eop)last_clean_eop=cycles;
            end
            if(camera_frame_start && last_clean_eop>=0)begin
                if(cycles-last_clean_eop<min_eop_to_boundary)min_eop_to_boundary=cycles-last_clean_eop;
                measured_boundaries++;
                if(cycles-last_clean_eop<ROW_IDLE_REQUIRED+2)
                    $fatal(1,"FAIL native EOP-to-boundary budget %0d",cycles-last_clean_eop);
                last_clean_eop=-1;
            end
            if(camera_frame_start && last_sensor_eop>=0)begin
                if(cycles-last_sensor_eop<min_sensor_eop_to_boundary)
                    min_sensor_eop_to_boundary=cycles-last_sensor_eop;
                last_sensor_eop=-1;
            end
        end
    end

    function automatic logic [31:0] word_at(input int index);
        return snapshot_results[32*(N-1-index)+:32];
    endfunction
    task automatic expect_word(input int index,input logic [31:0] value,input string reason);
        checks++;
        if(word_at(index)!==value)
            $fatal(1,"FAIL %s word%0d got%08x expected%08x",reason,index,word_at(index),value);
    endtask
    task automatic idle(input int n);
        for(int i=0;i<n;i++)begin
            @(negedge pclk);px_valid=0;camera_frame_start=0;
            // Invalid-cycle coordinate/data noise must not enter the classifier.
            px_x=1023;px_y=511;pixel=16'hf800;
            @(posedge pclk);#1;
        end
    endtask
    task automatic boundary;
        @(negedge pclk);px_valid=0;camera_frame_start=1;
        @(posedge pclk);#1;
        @(negedge pclk);camera_frame_start=0;
    endtask
    // Native frame1 is black except three disjoint 8x8 rectangles. Dark red is
    // below FixedRGB's160 minimum but above RatioRGB's80 minimum: R=123,G=B=0.
    // Frame2+ uses grey background, so snapshot memory proves which frame was kept.
    function automatic logic [15:0] scene(input int x,input int y,input int frame_n);
        if(x>=10 && x<=17 && y>=20 && y<=27)return 16'hf800;
        if(x>=100 && x<=107 && y>=80 && y<=87)return 16'h001f;
        if(x>=50 && x<=57 && y>=40 && y<=47)return 16'h7800;
        // A fifth frame verifies the independently calibrated blue floor.
        // B=33 passes the calibrated blue32 floor; B=24 remains rejected.
        if(frame_n==5 && x>=150 && x<=157 && y>=120 && y<=127)return 16'h0004;
        if(frame_n==5 && x>=200 && x<=207 && y>=150 && y<=157)return 16'h0003;
        // R=66 passes red64; R=57 remains rejected. All use exact RGB565 widening.
        if(frame_n==5 && x>=200 && x<=207 && y>=160 && y<=167)return 16'h4000;
        if(frame_n==5 && x>=240 && x<=247 && y>=180 && y<=187)return 16'h3800;
        return frame_n==1 ? 16'h0000 : 16'h39e7;
    endfunction
    task automatic send_sensor_frame(input int frame_n,input bit malformed,
                                      input bit change_mode,input bit check_latch);
        logic [15:0] value;
        bit dropped;
        for(int y=0;y<480;y++)begin
            for(int x=0;x<640;x++)begin
                // Deliberately coloured discarded sensor pixels detect bad decimation.
                if((x%2)!=0 || (y%2)!=0)value=((x+y)%3)==0?16'hf800:16'h001f;
                else value=scene(x/2,y/2,frame_n);
                dropped=malformed && x==40 && y==0; // one background kept pixel omitted
                @(negedge pclk);
                px_valid=!dropped;pixel=value;px_x=10'(x);px_y=9'(y);
                if(change_mode && x==0 && y==60)control_async=4'b0001;
                @(posedge pclk);#1;
                if(check_latch && x==0 && y==0)begin
                    checks++;
                    if(snap_u.results_q!==first_packet)
                        $fatal(1,"FAIL FrameGrab did not latch prior-frame packet at next first pixel");
                end
                idle(1); // The other RGB565 byte: no second word is accepted.
                if(frame_n==2 && y%37==0 && x%31==30)idle(1);
            end
            idle(HBLANK);
        end
        idle(VBLANK);
    endtask
    task automatic expect_candidate(input int slot,input bit blue,input int xmin,input int xmax,
                                     input int ymin,input int ymax,input int cx,input int cy);
        int base;
        base=(blue?45:13)+4*slot;
        // Removing only the causal top-left corner of an8x8 rectangle leaves63.
        expect_word(base,32'h8000003f,"candidate valid/area");
        expect_word(base+1,{16'(xmin),16'(xmax)},"candidate x bounds");
        expect_word(base+2,{16'(ymin),16'(ymax)},"candidate y bounds");
        expect_word(base+3,{16'(cx),16'(cy)},"candidate bbox midpoint");
    endtask
    task automatic check_packet(input int frame_n,input int mode,input bit valid_frame);
        int red_n,blue_n;
        red_n=mode==0?1:(frame_n==5?3:2);
        blue_n=frame_n==5?2:1;
        expect_word(0,32'h45504132,"EPA2 magic");expect_word(1,2,"schema version");
        expect_word(77,{8'(RATIO_RED_MIN_VALUE),8'(RATIO_BLUE_MIN_VALUE),8'd3,8'd2},"calibrated ratio metadata");
        expect_word(2,32'(frame_n),"native SOP id");
        expect_word(3,32'(frame_n),"raw SOP id");expect_word(4,32'(frame_n),"candidate SOP id");
        // same-frame/seen/IDs can be true on malformed frames; validity remains separate.
        // Dropping one native word leaves V2's accepted-pixel counter behind.
        // Row close is consequently reached on the next row's x0; later words
        // overlap CANON/RETIRE and legitimately add candidate_overrun bit9.
        // Valid streams remain strictly error/overrun-free; frame4 must recover.
        expect_word(5,valid_frame?32'h0000e09f:32'h0000832f,"publication flags");
        expect_word(6,{16'd320,16'd240},"native geometry");
        expect_word(7,32'h00002080|32'(mode),"frame-qualified configuration");
        expect_word(8,32'(red_n*64),"raw red area");expect_word(10,32'(blue_n*64),"raw blue area");
        if(valid_frame)begin
            expect_word(9,mode==0?{16'd13,16'd23}:(frame_n==5?{16'd90,16'd76}:{16'd33,16'd33}),"raw red exact centroid floor");
            expect_word(11,frame_n==5?{16'd128,16'd103}:{16'd103,16'd83},"raw blue exact centroid floor");
            expect_word(12,32'(blue_n<<4)|32'(red_n),"candidate counts");
            expect_candidate(0,0,10,17,20,27,13,23);
            if(mode!=0)expect_candidate(1,0,50,57,40,47,53,43);
            if(frame_n==5)expect_candidate(2,0,200,207,160,167,203,163);
            expect_candidate(0,1,100,107,80,87,103,83);
            if(frame_n==5)expect_candidate(1,1,150,157,120,127,153,123);
        end else expect_word(12,0,"malformed candidate counts suppressed");
        for(int i=0;i<8;i++)begin
            if(!valid_frame || i>=red_n)begin
                checks++;
                if(word_at(13+4*i)&32'h80000000)$fatal(1,"FAIL unexpected valid red candidate%0d",i);
            end
            if(!valid_frame || i>=blue_n)begin
                checks++;
                if(word_at(45+4*i)&32'h80000000)$fatal(1,"FAIL unexpected valid blue candidate%0d",i);
            end
        end
    endtask
    // Bit-by-bit CRC over complete16bit words, independent of frame_snap's
    // byte-folding function. CRC-16/CCITT-FALSE polynomial1021, initialffff.
    function automatic logic [15:0] crc_word(input logic [15:0] previous,input logic [15:0] data);
        logic [15:0] crc;
        logic feedback;
        crc=previous;
        for(int bit_n=15;bit_n>=0;bit_n--)begin
            feedback=crc[15]^data[bit_n];
            crc={crc[14:0],1'b0};
            if(feedback)crc=crc^16'h1021;
        end
        return crc;
    endfunction
    task automatic check_snapshot;
        logic [15:0] crc;
        logic [31:0] saved_word;
        if(!snap_ready || snap_busy)$fatal(1,"FAIL snapshot not ready after following full frame");
        if(snap_u.ram_u.mem[0]!==16'h4752 || snap_u.ram_u.mem[1]!==16'h4142 ||
           snap_u.ram_u.mem[2]!==16'd1 || snap_u.ram_u.mem[3]!==16'd320 ||
           snap_u.ram_u.mem[4]!==16'd240 || snap_u.ram_u.mem[5]!==16'd1 ||
           snap_u.ram_u.mem[6]!==16'(N))$fatal(1,"FAIL FrameGrab header");
        checks+=7;
        for(int i=0;i<N;i++)begin
            saved_word={snap_u.ram_u.mem[7+2*i],snap_u.ram_u.mem[8+2*i]};
            checks++;
            if(saved_word!==first_packet[32*(N-1-i)+:32])$fatal(1,"FAIL snapshot resultword%0d",i);
        end
        for(int y=0;y<240;y++)for(int x=0;x<320;x++)begin
            checks++;
            if(snap_u.ram_u.mem[PIX0+y*320+x]!==scene(x,y,1))
                $fatal(1,"FAIL captured native RGB565 x%0d y%0d (odd-pixel contamination or wrong frame)",x,y);
        end
        crc=16'hffff;
        for(int i=0;i<CRC_ADDR;i++)crc=crc_word(crc,snap_u.ram_u.mem[i]);
        checks++;
        if(snap_u.ram_u.mem[CRC_ADDR]!==crc)$fatal(1,"FAIL snapshot CRC got%04x expected%04x",snap_u.ram_u.mem[CRC_ADDR],crc);
    endtask
    initial begin
        if(RATIO_RED_MIN_VALUE!=64 || RATIO_BLUE_MIN_VALUE!=32)
            $fatal(1,"FAIL hand fixtures require the frozen ratio profile red64/blue32");
        idle(3);@(negedge pclk);reset=0;
        trigger=1;idle(10);trigger=0;idle(10);
        boundary();
        if(word_at(5)&1)$fatal(1,"FAIL startup stale packet qualified same-frame");
        send_sensor_frame(1,0,1,0);boundary();check_packet(1,0,1);
        first_packet=snapshot_results;
        send_sensor_frame(2,0,0,1);check_snapshot();boundary();check_packet(2,1,1);
        send_sensor_frame(3,1,0,0);boundary();check_packet(3,1,0);
        send_sensor_frame(4,0,0,0);boundary();check_packet(4,1,1);
        send_sensor_frame(5,0,0,0);boundary();check_packet(5,1,1);
        if(measured_rows<5*(H-1) || measured_boundaries!=5)$fatal(1,"FAIL cadence measurements missing");
        $display("INFO native cadence: 20MHz PCLK; RGB565 word spacing2; HBLANK%0d; VBLANK%0d",HBLANK,VBLANK);
        $display("INFO native budget: minimum interrow INVALID clocks=%0d (required%0d); minimum clean EOP-to-boundary clocks=%0d (publication needs%0d plus wrapper edge)",
                 min_row_idle,ROW_IDLE_REQUIRED,min_eop_to_boundary,ROW_IDLE_REQUIRED+1);
        $display("INFO skipped-odd-row proof: native row last-to-next-first edge interval=%0d; sensor EOP-to-boundary=%0d clocks; zero extra H/V blanking",
                 min_row_idle+1,min_sensor_eop_to_boundary);
        $display("PASS partACapturePipeline: %0d checks; five full640x480 sensor streams, native geometry, ignored odd pixels, switch frame qualification, malformed recovery, low-blue thresholds, same-frame78word EPA2 snapshot and independentCRC",checks);
        $finish;
    end
    initial begin #300ms;$fatal(1,"FAIL partACapturePipeline watchdog");end
endmodule
