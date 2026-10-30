`timescale 1ns/1ps
// ECHO-7 Part A | Human owner: Member A (name/SID pending).
// AI-assisted by OpenAI Codex; reference vectors come from independent Python BFS.
// V2 row-reclaimed CCL. Independent row-graph/BFS vectors; unordered descriptors.
// Generate using tools/part_a/candidates_reclaimed_model.py (see that tool's CLI).
// Run with +VECTORS=path if the simulator's cwd differs from the ECHOPHACE1 root.
module boundedCandidates_tb;
    import part_a_pkg::*;
    localparam int W=320, H=240, PIX=W*H, CAP=8, CASES=18, WORDS=134;
    localparam int ROW_GAP=W+CAP, FINAL_LATENCY=ROW_GAP+1;
    logic clk=0;
    always #5 clk=~clk;
    logic reset=1, in_valid=0, in_sop=0, in_eop=0;
    logic [1:0] in_mask=0;
    logic [8:0] in_x=0;
    logic [7:0] in_y=0;
    candidate_t [7:0] red_candidates,blue_candidates;
    logic [3:0] red_count,blue_count;
    logic out_valid,frame_valid,red_overflow,blue_overflow,overflow,frame_error,overrun,busy;
    logic [15:0] frame_id;
    boundedCandidates #(.W(W),.H(H),.CAP(CAP),.MIN_AREA(3)) dut(.*);
    logic [1:0] masks[0:CASES*PIX-1];
    logic [31:0] expected[0:CASES*WORDS-1];
    string vectors="work/part_a_reclaimed_vectors";
    int cycles=0, expected_id=0, last_pixel_cycle;
    always @(posedge clk) cycles=cycles+1;

    task automatic pixel(input int m,input int x,input int y,input bit sop,input bit eop);
        @(negedge clk);
        in_valid=1;in_mask=2'(m);in_x=9'(x);in_y=8'(y);in_sop=sop;in_eop=eop;
        @(posedge clk);#1;
    endtask
    task automatic gap;
        @(negedge clk);
        in_valid=0;in_mask=3;in_x=511;in_y=255;in_sop=1;in_eop=1; // invalid-cycle tags must be ignored
        @(posedge clk);#1;
    endtask
    task automatic quiet;
        @(negedge clk);in_valid=0;in_sop=0;in_eop=0;in_mask=0;
    endtask
    task automatic reset_dut;
        @(negedge clk);reset=1;in_valid=0;in_sop=0;in_eop=0;
        repeat(2) @(posedge clk);
        @(negedge clk);reset=0;expected_id=0;
    endtask
    task automatic wait_publish(input bit exact_latency=1);
        bit seen;
        seen=0;
        quiet();
        for(int n=0;n<FINAL_LATENCY+4;n++) begin
            @(posedge clk);#1;
            if(out_valid) begin seen=1;break;end
        end
        if(!seen)$fatal(1,"FAIL publication missing after bounded finalization");
        if(frame_id!==16'(expected_id))$fatal(1,"FAIL frame id got %0d expected %0d",frame_id,expected_id);
        if(exact_latency && cycles-last_pixel_cycle!=FINAL_LATENCY)$fatal(1,"FAIL finalize latency got %0d expected %0d",cycles-last_pixel_cycle,FINAL_LATENCY);
    endtask
    function automatic logic [31:0] field_value(input candidate_t c,input int field_n);
        case(field_n)
            0:return 32'(c.valid);1:return 32'(c.xmin);2:return 32'(c.xmax);
            3:return 32'(c.ymin);4:return 32'(c.ymax);5:return 32'(c.area);
            6:return 32'(c.cx);default:return 32'(c.cy);
        endcase
    endfunction
    task automatic check_case(input int test_n);
        int base,at,found,actual_count;
        bit match_fields;
        bit [7:0] matched;
        candidate_t c;
        base=test_n*WORDS;
        if(frame_valid!==1'(expected[base]) || red_count!==4'(expected[base+1]) || blue_count!==4'(expected[base+2]) ||
           red_overflow!==1'(expected[base+3]) || blue_overflow!==1'(expected[base+4]) || overflow!==1'(expected[base+5]))
            $fatal(1,"FAIL case %0d publication status/counts",test_n);
        if(frame_error || overrun)$fatal(1,"FAIL normal case %0d protocol flag",test_n);
        for(int colour=0;colour<2;colour++)begin
            matched=0;actual_count=0;
            for(int i=0;i<8;i++)begin
                c=colour==0?red_candidates[i]:blue_candidates[i];
                if(c.valid)begin
                    actual_count++;found=-1;
                    for(int j=0;j<8;j++)begin
                        at=base+6+(colour*8+j)*8;
                        match_fields=expected[at]!=0 && !matched[j];
                        for(int f=0;f<8;f++)if(field_value(c,f)!==expected[at+f])match_fields=0;
                        if(match_fields && found<0)found=j;
                    end
                    if(found<0)begin
                        // Diagnose the intentional cx-only mutation precisely,
                        // while retaining unordered full-field acceptance.
                        for(int j=0;j<8;j++)begin
                            at=base+6+(colour*8+j)*8;
                            match_fields=expected[at]!=0 && !matched[j];
                            for(int f=0;f<8;f++)
                                if(f!=6 && field_value(c,f)!==expected[at+f])match_fields=0;
                            if(match_fields)$fatal(1,"FAIL case%0d colour%0d candidate%0d field6 got%0d expected%0d",
                                test_n,colour,i,field_value(c,6),expected[at+6]);
                        end
                        $fatal(1,"FAIL case%0d colour%0d unmatched actual descriptor%0d area%0d box%0d,%0d-%0d,%0d",
                            test_n,colour,i,c.area,c.xmin,c.ymin,c.xmax,c.ymax);
                    end
                    matched[found]=1;
                end
            end
            if(actual_count!=int'(expected[base+1+colour]))$fatal(1,"FAIL valid descriptor count");
        end
    endtask
    task automatic send_case(input int test_n,input int fault);
        int x,y,m;
        expected_id++;
        for(int i=0;i<PIX;i++)begin
            if(i!=0 && i%W==0)repeat(ROW_GAP)gap();
            if(i!=0 && i%19==0)gap();
            x=i%W;y=i/W;m=int'(masks[test_n*PIX+i]);
            if(fault==1 && i==21)x=x+1;
            if(fault==2 && i==123)m=3;
            pixel(m,x,y,i==0,(i==PIX-1)&&fault!=3);
        end
        last_pixel_cycle=cycles;
    endtask
    task automatic check_invalid(input bit expected_overrun);
        if(frame_valid || !frame_error || overrun!==expected_overrun || red_count!=0 || blue_count!=0)
            $fatal(1,"FAIL malformed/overrun frame was not invalidated consistently");
        for(int i=0;i<8;i++)if(red_candidates[i].valid || blue_candidates[i].valid)
            $fatal(1,"FAIL invalid frame leaked candidate");
    endtask
    initial begin
        if($value$plusargs("VECTORS=%s",vectors))begin end
        $readmemh({vectors,"/masks.hex"},masks);
        $readmemh({vectors,"/expected.hex"},expected);
        reset_dut();
        for(int t=0;t<CASES;t++)begin
            send_case(t,0);wait_publish();check_case(t);
        end
        for(int fault=1;fault<=3;fault++)begin
            send_case(11,fault);wait_publish();check_invalid(0);
        end
        // Early EOP, including a short frame's first pixel.
        expected_id++;
        for(int i=0;i<20;i++)pixel(0,i,0,i==0,i==19);
        last_pixel_cycle=cycles;wait_publish();check_invalid(0);

        // Exactly W+CAP blank clocks: SOP on publication edge is legal.
        send_case(11,0);
        repeat(ROW_GAP)gap();
        expected_id++;pixel(0,0,0,1,0);
        if(!out_valid || !frame_valid || frame_error || overrun || frame_id!==16'(expected_id-1))
            $fatal(1,"FAIL SOP on publication edge was not accepted cleanly");
        for(int i=1;i<PIX;i++)begin
            if(i%W==0)repeat(ROW_GAP)gap();
            pixel(0,i%W,i/W,0,i==PIX-1);
        end
        last_pixel_cycle=cycles;wait_publish();check_case(11);

        // New SOP before previous finalization: old result is invalid, new frame is invalid too.
        send_case(11,0);
        expected_id++;
        pixel(0,0,0,1,0);
        if(!out_valid || frame_id!==16'(expected_id-1))$fatal(1,"FAIL overrun did not publish abandoned frame id");
        check_invalid(1);
        for(int i=1;i<PIX;i++)begin
            if(i%W==0)repeat(ROW_GAP)gap();
            pixel(0,i%W,i/W,0,i==PIX-1);
        end
        last_pixel_cycle=cycles;wait_publish();check_invalid(1);
        send_case(0,0);wait_publish();check_case(0); // recovery

        // New SOP during an unfinished capture: protocol error, not finalization overrun.
        expected_id++;for(int i=0;i<8;i++)pixel(0,i,0,i==0,0);
        expected_id++;pixel(0,0,0,1,0);
        if(!out_valid || frame_id!==16'(expected_id-1))$fatal(1,"FAIL early SOP old id");
        check_invalid(0);
        for(int i=1;i<PIX;i++)begin
            if(i%W==0)repeat(ROW_GAP)gap();
            pixel(0,i%W,i/W,0,i==PIX-1);
        end
        last_pixel_cycle=cycles;wait_publish();check_invalid(0);

        // A pixel arriving during canonicalization cannot silently corrupt the
        // next row. Ignore it, flag overrun, then consume a coordinate-correct
        // continuation so the protocol failure alone invalidates the frame.
        expected_id++;
        for(int x=0;x<W;x++)pixel(0,x,0,x==0,0);
        pixel(0,0,1,0,0);
        repeat(ROW_GAP-1)gap();
        for(int i=W;i<PIX;i++)begin
            if(i!=W && i%W==0)repeat(ROW_GAP)gap();
            pixel(0,i%W,i/W,0,i==PIX-1);
        end
        last_pixel_cycle=cycles;wait_publish();check_invalid(1);
        send_case(11,0);wait_publish();check_case(11);

        // EOP during canonicalization forces a bounded invalid termination.
        expected_id++;
        for(int x=0;x<W;x++)pixel(x<6?1:0,x,0,x==0,0);
        last_pixel_cycle=cycles;
        repeat(3)gap();pixel(0,0,1,0,1);
        wait_publish();check_invalid(1);

        // One clock short of the row gap: EOP arrives on the final RETIRE
        // edge after the active root's slot was already passed. Revisit it,
        // publish invalid, and ensure the next complete frame recovers.
        expected_id++;
        for(int x=0;x<W;x++)pixel(x<6?1:0,x,0,x==0,0);
        last_pixel_cycle=cycles;
        repeat(ROW_GAP-1)gap();pixel(0,0,1,0,1);
        wait_publish(0);check_invalid(1);
        send_case(0,0);wait_publish();check_case(0);

        // Reset during canonicalization and retirement discards every pending
        // line alias/output and restarts frame IDs, without clearing line RAM.
        for(int phase=0;phase<2;phase++)begin
            expected_id++;
            for(int x=0;x<W;x++)pixel(x<6?1:0,x,0,x==0,0);
            repeat(phase==0?3:W+3)gap();
            reset_dut();send_case(5,0);wait_publish();check_case(5);
        end

        // Reset discards an in-flight frame and restarts the SOP sequence at one.
        expected_id++;for(int i=0;i<40;i++)pixel(i<4?1:0,i,0,i==0,0);
        reset_dut();
        send_case(5,0);wait_publish();check_case(5);
        $display("PASS boundedCandidates: 18 V2 native-frame BFS cases; row reclamation, separate capacities, aliases, exact gaps, geometry, reset, framing and overrun");
        $finish;
    end
    initial begin #100ms;$fatal(1,"FAIL boundedCandidates watchdog");end
endmodule
