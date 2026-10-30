`timescale 1ns/1ps
// ECHO-7 Part A | Member A SID/review pending. AI-assisted by OpenAI Codex.
// REAL recorded RGB565 images replayed through EPA2 RTL at native sensor cadence.
// Golden vectors use independent image math and row-prefix BFS, not board outputs.
// Compare metadata/raw fields exactly and candidate valid descriptors as multisets.
// Invalid descriptor diagnostic bits are intentionally outside the public contract.
module partARecordedReplay_tb;
    parameter int CASES=5, MAX_CASES=16, RATIO_RED_MIN_VALUE=64, RATIO_BLUE_MIN_VALUE=32;
    localparam int N=78, W=320, H=240, PIX=W*H, CAP=8;
    logic pclk=0;always #25 pclk=~pclk;
    logic reset=1,camera_frame_start=0,px_valid=0;
    logic [15:0] pixel=0;
    logic [9:0] px_x=0;
    logic [8:0] px_y=0;
    logic [3:0] control_async=0;
    logic [N*32-1:0] snapshot_results;
    logic [15:0] frames[0:MAX_CASES*PIX-1];
    logic [31:0] expected[0:MAX_CASES*N-1];
    logic [1:0] modes[0:MAX_CASES-1];
    string vectors="work/part_a_v2_recorded_vectors";
    int checks=0,matched_frames=0,case_count=CASES;
    longint cycles=0,last_clean=-1,last_eop=-1;
    longint min_row_idle=64'h7fff_ffff_ffff_ffff,min_eop_gap=64'h7fff_ffff_ffff_ffff;
    int previous_x=-1,previous_y=-1;
    partACapturePipeline #(.W(W),.H(H),.CAP(CAP),.MIN_AREA(32),.CONTROL_STABLE_CYCLES(4),
        .RATIO_RED_MIN_VALUE(RATIO_RED_MIN_VALUE),.RATIO_BLUE_MIN_VALUE(RATIO_BLUE_MIN_VALUE)) dut(.*);

    function automatic logic[31:0] word_at(input int n);
        return snapshot_results[32*(N-1-n)+:32];
    endfunction
    always @(posedge pclk)begin
        cycles<=cycles+1;
        if(reset)begin last_clean=-1;last_eop=-1;previous_x=-1;previous_y=-1;end
        else begin
            if(dut.clean_valid)begin
                if(dut.clean_x==0 && dut.clean_y>0 && previous_x==W-1 && int'(dut.clean_y)==previous_y+1)begin
                    if(cycles-last_clean-1<min_row_idle)min_row_idle=cycles-last_clean-1;
                    if(cycles-last_clean-1<W+CAP)$fatal(1,"FAIL replay row housekeeping budget");
                end
                last_clean=cycles;previous_x=int'(dut.clean_x);previous_y=int'(dut.clean_y);
                if(dut.clean_eop)last_eop=cycles;
            end
            if(camera_frame_start && last_eop>=0)begin
                if(cycles-last_eop<min_eop_gap)min_eop_gap=cycles-last_eop;
                if(cycles-last_eop<W+CAP+2)$fatal(1,"FAIL replay finalization budget");
                last_eop=-1;
            end
        end
    end
    task automatic idle(input int clocks);
        repeat(clocks)begin
            @(negedge pclk);px_valid=0;camera_frame_start=0;
            pixel=16'hf800;px_x=1023;px_y=511;
            @(posedge pclk);#1;
        end
    endtask
    task automatic boundary;
        @(negedge pclk);px_valid=0;camera_frame_start=1;
        @(posedge pclk);#1;
        @(negedge pclk);camera_frame_start=0;
    endtask
    task automatic sensor_frame(input int sample);
        for(int y=0;y<480;y++)for(int x=0;x<640;x++)begin
            @(negedge pclk);px_valid=1;px_x=10'(x);px_y=9'(y);
            // Only even-even pixels are recorded input; rejected coordinates
            // carry deliberately coloured noise to test decimation boundaries.
            pixel=(!x[0] && !y[0])?frames[sample*PIX+(y/2)*W+x/2]:
                  (((x+y)%3)==0?16'hf800:16'h001f);
            @(posedge pclk);#1;
            idle(1); // RGB565 two-byte word cadence; no extra H/V blanking.
            if(sample==1 && y%43==0 && x%47==0)idle(1);
        end
    endtask
    task automatic check_packet(input int sample);
        bit used[0:7];
        int first,wanted,found,actual_count,expected_count;
        logic[31:0] actual_word,reference_word;
        for(int w=0;w<N;w++)begin
            if(w<=12 || w==77)begin
                checks++;
                if(word_at(w)!==expected[sample*N+w])
                    $fatal(1,"FAIL real sample%0d packetword%0d got%08x expected%08x",sample,w,word_at(w),expected[sample*N+w]);
            end
        end
        for(int colour=0;colour<2;colour++)begin
            first=colour==0?13:45;
            actual_count=0;expected_count=0;
            for(int i=0;i<8;i++)begin
                used[i]=0;
                if(word_at(first+4*i)&32'h80000000)actual_count++;
                if(expected[sample*N+first+4*i]&32'h80000000)expected_count++;
            end
            if(actual_count!=expected_count)$fatal(1,"FAIL real sample%0d colour%0d valid descriptor count",sample,colour);
            for(int i=0;i<8;i++)if(expected[sample*N+first+4*i]&32'h80000000)begin
                found=-1;
                for(int j=0;j<8;j++)if(!used[j] && found<0)begin
                    wanted=1;
                    for(int field_n=0;field_n<4;field_n++)begin
                        actual_word=word_at(first+4*j+field_n);
                        reference_word=expected[sample*N+first+4*i+field_n];
                        if(actual_word!==reference_word)wanted=0;
                    end
                    if(wanted)found=j;
                end
                checks++;
                if(found<0)$fatal(1,"FAIL real sample%0d colour%0d missing golden descriptor%0d",sample,colour,i);
                used[found]=1;
            end
        end
        matched_frames++;
        $display("PASS recorded sample%0d mode%0d: EPA2 raw/header/flags exact; valid candidate descriptors agree unordered; frame_valid=%0d",
                 sample,modes[sample],(word_at(5)>>7)&1);
    endtask
    initial begin
        if($value$plusargs("VECTORS=%s",vectors))begin end
        if($value$plusargs("CASES=%d",case_count))begin end
        if(case_count<1 || case_count>MAX_CASES)$fatal(1,"FAIL recorded CASES outside compiled MAX_CASES");
        $readmemh({vectors,"/frames.hex"},frames,0,case_count*PIX-1);
        $readmemh({vectors,"/expected.hex"},expected,0,case_count*N-1);
        $readmemh({vectors,"/modes.hex"},modes,0,case_count-1);
        idle(4);@(negedge pclk);reset=0;
        for(int sample=0;sample<case_count;sample++)begin
            control_async={2'b00,modes[sample]};idle(12);boundary();
            sensor_frame(sample);boundary();check_packet(sample);
        end
        if(matched_frames!=case_count)$fatal(1,"FAIL recorded frame count");
        $display("INFO recorded replay cadence: minimum interrow invalid=%0d; minimum cleanEOP-to-boundary=%0d; zero extra H/V blanking",
                 min_row_idle,min_eop_gap);
        $display("PASS partARecordedReplay: %0d REAL camera inputs, %0d packet/descriptor checks, R%0d/B%0d, numerical model/RTL replay only - not measured EPA2 hardware outputs",
                 case_count,checks,RATIO_RED_MIN_VALUE,RATIO_BLUE_MIN_VALUE);
        $finish;
    end
    initial begin #1s;$fatal(1,"FAIL partARecordedReplay watchdog");end
endmodule
