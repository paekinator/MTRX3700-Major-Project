// ECHO-7 Part A | Human owner: Member A (name/SID pending).
// AI-assisted by OpenAI Codex; human review required.
// Exact 4-connected CCL. ACTIVE_CAP bounds temporary handles (including aliases);
// CAP bounds one shared red/blue completed pool, applying MIN_AREA at retirement.
// Same-edge retirement allocates red first, then blue; colour travels with each
// dense slot. Neither colour has a reserved share of the production pool.
// Never reuse within a row. Canonicalize ALL W line entries before freeing
// aliases or absent roots. Either capacity overflow invalidates the whole frame.
// Output order is retirement order; area is exact, centre is bbox midpoint.
// Leave W+ACTIVE_CAP invalid clocks after each row; the next edge accepts a row.
// Final publication: W+ACTIVE_CAP+1 clocks after EOP. No ready/backpressure.
// Unexpected housekeeping pixels flag error+overrun; EOP forces termination.
// New SOP aborts old and new frames invalid; next complete frame recovers.
// IDs count every SOP, first=1, modulo65536. SOP on publication edge is legal.
module boundedCandidates #(
    parameter int W=320, H=240, CAP=8, MIN_AREA=32, ACTIVE_CAP=(CAP>15?15:CAP),
    parameter bit PRUNE_UNUSABLE=0, SHARED_POOL=1
) (
    input logic clk, reset,
    input logic in_valid, in_sop, in_eop,
    input logic [1:0] in_mask,
    input logic [8:0] in_x,
    input logic [7:0] in_y,
    output candidate_pkg::candidate_array_t sharedCandidates,
    output logic [candidate_pkg::MAX_CANDIDATES-1:0] sharedColours,
    output logic [4:0] sharedCount,
    output logic [4:0] red_count, blue_count,
    output logic out_valid, frame_valid,
    output logic red_overflow, blue_overflow, overflow,
    output logic frame_error, overrun,
    output logic [15:0] frame_id,
    output wire busy,
    // Optional diagnostics; existing Part A consumers may leave these open.
    output wire [3:0] allocationPeakRed, allocationPeakBlue
);
    import candidate_pkg::*;
    typedef enum logic [2:0] {IDLE,COLLECT,CANON,RETIRE,ROW_DONE} state_t;
    state_t state;
    logic [3:0] line_label [0:1][0:W-1], left_label [0:1];
    // Raw upper-line handles for the next expected pixel. Resolve through
    // the CURRENT parent table when consumed: the previous pixel may union
    // these components on the immediately preceding clock edge.
    logic [3:0] prefetched_up [0:1];
    logic [3:0] parent [0:1][0:ACTIVE_CAP-1];
    candidate_t boxes [0:1][0:ACTIVE_CAP-1];
    logic [ACTIVE_CAP-1:0] free_slots [0:1], live_roots [0:1];
    // Bench-visible high-water mark; aliases occupy handles until row seal.
    logic [3:0] allocation_peak [0:1];
    assign allocationPeakRed=allocation_peak[0];
    assign allocationPeakBlue=allocation_peak[1];
    logic [1:0] current_overflow;
    logic current_bad, current_overrun, end_frame;
    logic [15:0] next_id, current_id;
    logic [8:0] expected_x, canon_index;
    logic [7:0] expected_y;
    logic [3:0] scan_index;
    logic [4:0] work_red_count, work_blue_count,workCount,blueInsertSlot;
    candidate_array_t workCandidates,publishCandidates;
    logic [MAX_CANDIDATES-1:0] workColours;
    logic [1:0] retireCandidate,insertCandidate;
    candidate_t scan_red, scan_blue;
    logic publish_ok;
    assign busy = state != IDLE;

    function automatic logic [3:0] root_of(input logic colour,input logic [3:0] label_id);
        // Union redirects every alias of the losing root on that edge.
        // All allocated handles therefore point directly to canonical roots.
        if(label_id!=0 && int'(label_id)<=ACTIVE_CAP)
            return parent[colour][int'(label_id)-1];
        return 4'd0;
    endfunction
    function automatic logic [3:0] used_count(input logic [ACTIVE_CAP-1:0] available);
        logic [3:0] n;
        n=0;
        for(int i=0;i<ACTIVE_CAP;i++) if(!available[i]) n=n+4'd1;
        return n;
    endfunction
    function automatic candidate_t add_pixel(input candidate_t a,input logic [8:0] x,input logic [7:0] y);
        candidate_t c;
        c=a; c.valid=1; c.area=a.area+17'd1;
        if(x<c.xmin)c.xmin=x; if(x>c.xmax)c.xmax=x;
        if(y<c.ymin)c.ymin=y; if(y>c.ymax)c.ymax=y;
        return c;
    endfunction
    function automatic candidate_t union_boxes(input candidate_t a,input candidate_t b);
        candidate_t c;
        c=a; c.area=a.area+b.area;
        c.xmin=a.xmin<b.xmin?a.xmin:b.xmin; c.xmax=a.xmax>b.xmax?a.xmax:b.xmax;
        c.ymin=a.ymin<b.ymin?a.ymin:b.ymin; c.ymax=a.ymax>b.ymax?a.ymax:b.ymax;
        return c;
    endfunction
    function automatic candidate_t with_centre(input candidate_t a);
        candidate_t c;
        c=a;
        c.cx=9'((int'(a.xmin)+int'(a.xmax))/2);
        c.cy=8'((int'(a.ymin)+int'(a.ymax))/2);
        return c;
    endfunction
    function automatic logic usable_size(input candidate_t a,input logic colour);
        logic [9:0] boxWidth;
        logic [8:0] boxHeight;
        // Inclusive native-pixel dimensions. This gate applies only when a
        // root retires, so it cannot hide active-label overflow or alter the
        // W+ACTIVE_CAP row-maintenance budget. Red signs require at least 24x24 in
        // the downstream reader. Blue also retains either orientation of a
        // possible 20x3 calibration reference. No location or ID is consulted.
        boxWidth={1'b0,a.xmax}-{1'b0,a.xmin}+10'd1;
        boxHeight={1'b0,a.ymax}-{1'b0,a.ymin}+9'd1;
        if(!PRUNE_UNUSABLE)return 1'b1;
        if(!colour)return boxWidth>=10'd24 && boxHeight>=9'd24;
        return (boxWidth>=10'd20 && boxHeight>=9'd3) ||
               (boxWidth>=10'd3 && boxHeight>=9'd20);
    endfunction

    wire starting=in_valid && in_sop;
    wire housekeeping=state==CANON || state==RETIRE;
    wire row_ready=state==ROW_DONE && !end_frame;
    wire publishing=state==ROW_DONE && end_frame;
    wire accepting=in_valid && (starting || state==COLLECT || row_ready);
    wire [8:0] this_expected_x=starting?9'd0:expected_x;
    wire [7:0] this_expected_y=starting?8'd0:expected_y;
    wire last_expected=this_expected_x==9'(W-1) && this_expected_y==8'(H-1);
    wire row_last_expected=this_expected_x==9'(W-1);
    wire coords_ok=int'(in_x)<W && int'(in_y)<H && in_x==this_expected_x && in_y==this_expected_y;
    wire overlapping_start=starting && (state==COLLECT || housekeeping || row_ready);
    wire unexpected_publish_pixel=publishing && in_valid && !in_sop;
    logic [3:0] canonical_red,canonical_blue;
    logic [ACTIVE_CAP-1:0] pixelAvailable [0:1];
    logic [3:0] pixelOccupiedPlusOne [0:1];
    logic [3:0] pixelChosenLabel [0:1],pixelMergedLabel [0:1];
    logic [3:0] pixelLeftRoot [0:1],pixelUpRoot [0:1];
    logic pixelAllocate [0:1],pixelCapacityHit [0:1];
    candidate_t pixelUpdatedBox [0:1];
    // Each colour owns independent labels/descriptors. Compute both paths
    // without using in_mask as a large data mux select; only the final write
    // enables select the arriving colour. The shared raster FSM is unchanged.
    always_comb begin
        for(int pixelColour=0;pixelColour<2;pixelColour++)begin
            pixelAvailable[pixelColour]=starting?{ACTIVE_CAP{1'b1}}:free_slots[pixelColour];
            pixelOccupiedPlusOne[pixelColour]=used_count(pixelAvailable[pixelColour])+4'd1;
            pixelChosenLabel[pixelColour]=0;pixelMergedLabel[pixelColour]=0;pixelLeftRoot[pixelColour]=0;pixelUpRoot[pixelColour]=0;
            pixelAllocate[pixelColour]=0;pixelCapacityHit[pixelColour]=0;pixelUpdatedBox[pixelColour]='0;
            if(accepting && coords_ok) begin
                if(in_x!=0 && !starting)pixelLeftRoot[pixelColour]=root_of(1'(pixelColour),left_label[pixelColour]);
                if(in_y!=0 && !starting)pixelUpRoot[pixelColour]=root_of(1'(pixelColour),prefetched_up[pixelColour]);
                if(pixelLeftRoot[pixelColour]==0 && pixelUpRoot[pixelColour]==0) begin
                    for(int i=0;i<ACTIVE_CAP;i++)if(pixelChosenLabel[pixelColour]==0 && pixelAvailable[pixelColour][i])pixelChosenLabel[pixelColour]=4'(i+1);
                    if(pixelChosenLabel[pixelColour]!=0) begin
                        pixelAllocate[pixelColour]=1;pixelUpdatedBox[pixelColour].valid=1;
                        pixelUpdatedBox[pixelColour].xmin=in_x;pixelUpdatedBox[pixelColour].xmax=in_x;
                        pixelUpdatedBox[pixelColour].ymin=in_y;pixelUpdatedBox[pixelColour].ymax=in_y;pixelUpdatedBox[pixelColour].area=17'd1;
                    end else pixelCapacityHit[pixelColour]=1;
                end else if(pixelLeftRoot[pixelColour]==0 || pixelUpRoot[pixelColour]==0 || pixelLeftRoot[pixelColour]==pixelUpRoot[pixelColour]) begin
                    pixelChosenLabel[pixelColour]=pixelLeftRoot[pixelColour]!=0?pixelLeftRoot[pixelColour]:pixelUpRoot[pixelColour];
                    pixelUpdatedBox[pixelColour]=add_pixel(boxes[pixelColour][int'(pixelChosenLabel[pixelColour])-1],in_x,in_y);
                end else begin
                    pixelChosenLabel[pixelColour]=pixelLeftRoot[pixelColour]<pixelUpRoot[pixelColour]?pixelLeftRoot[pixelColour]:pixelUpRoot[pixelColour];
                    pixelMergedLabel[pixelColour]=pixelLeftRoot[pixelColour]<pixelUpRoot[pixelColour]?pixelUpRoot[pixelColour]:pixelLeftRoot[pixelColour];
                    pixelUpdatedBox[pixelColour]=add_pixel(union_boxes(boxes[pixelColour][int'(pixelChosenLabel[pixelColour])-1],boxes[pixelColour][int'(pixelMergedLabel[pixelColour])-1]),in_x,in_y);
                end
            end
        end
    end
// synthesis translate_off
`ifndef SYNTHESIS
    // Verification aliases preserve the original bench's per-pixel view.
    // They are absent from synthesis and never drive production state.
    logic colour,allocate_pixel,capacity_hit;
    logic [ACTIVE_CAP-1:0] available;
    logic [3:0] chosen_label,merged_label,left_root,up_root,occupied_plus_one;
    candidate_t updated_box;
    always_comb begin
        colour=in_mask==2'b10;
        available=pixelAvailable[colour];occupied_plus_one=pixelOccupiedPlusOne[colour];
        chosen_label=0;merged_label=0;left_root=0;up_root=0;
        allocate_pixel=0;capacity_hit=0;updated_box='0;
        if(in_mask==1 || in_mask==2)begin
            chosen_label=pixelChosenLabel[colour];merged_label=pixelMergedLabel[colour];
            left_root=pixelLeftRoot[colour];up_root=pixelUpRoot[colour];
            allocate_pixel=pixelAllocate[colour];capacity_hit=pixelCapacityHit[colour];
            updated_box=pixelUpdatedBox[colour];
        end
    end
`endif
// synthesis translate_on
    always_comb begin
        canonical_red=0;canonical_blue=0;
        if(state==CANON) begin
            canonical_red=root_of(0,line_label[0][canon_index]);
            canonical_blue=root_of(1,line_label[1][canon_index]);
        end
        scan_red='0;scan_blue='0;
        if(state==RETIRE && int'(scan_index)<ACTIVE_CAP) begin
            scan_red=with_centre(boxes[0][scan_index]);scan_blue=with_centre(boxes[1][scan_index]);
        end
        retireCandidate=0;insertCandidate=0;blueInsertSlot=workCount;
        if(state==RETIRE)begin
            for(int c=0;c<2;c++)begin
                retireCandidate[c]=!free_slots[c][scan_index] &&
                    parent[c][scan_index]==scan_index+4'd1 && (end_frame||!live_roots[c][scan_index]) &&
                    boxes[c][scan_index].valid && int'(boxes[c][scan_index].area)>=MIN_AREA &&
                    usable_size(boxes[c][scan_index],1'(c));
            end
            // SHARED_POOL=0 exists only for retained CAP8 regression vectors;
            // it uses the same single16-slot storage with per-colour limits.
            // Production elaborates SHARED_POOL=1 and removes those branches.
            insertCandidate[0]=retireCandidate[0] && workCount<MAX_CANDIDATES &&
                (SHARED_POOL ? workCount<CAP : work_red_count<CAP);
            blueInsertSlot=workCount+5'(insertCandidate[0]);
            insertCandidate[1]=retireCandidate[1] && blueInsertSlot<MAX_CANDIDATES &&
                (SHARED_POOL ? blueInsertSlot<CAP : work_blue_count<CAP);
        end
        publish_ok=!current_bad && current_overflow==0 && !unexpected_publish_pixel;
        publishCandidates=workCandidates;
        for(int i=0;i<MAX_CANDIDATES;i++) begin
            publishCandidates[i].valid=workCandidates[i].valid && publish_ok;
        end
    end
    always_ff @(posedge clk) begin
        if(reset) begin
            state<=IDLE;expected_x<=0;expected_y<=0;next_id<=0;current_id<=0;
            current_overflow<=0;current_bad<=0;current_overrun<=0;end_frame<=0;
            canon_index<=0;scan_index<=0;work_red_count<=0;work_blue_count<=0;workCount<=0;
            workCandidates<='0;workColours<=0;
            sharedCandidates<='0;sharedColours<=0;sharedCount<=0;red_count<=0;blue_count<=0;
            out_valid<=0;frame_valid<=0;frame_error<=0;overrun<=0;
            red_overflow<=0;blue_overflow<=0;overflow<=0;frame_id<=0;
            for(int c=0;c<2;c++) begin
                free_slots[c]<='1;live_roots[c]<='0;allocation_peak[c]<=0;left_label[c]<=0;prefetched_up[c]<=0;
                for(int i=0;i<ACTIVE_CAP;i++) begin parent[c][i]<=4'(i+1);boxes[c][i]<='0;end
            end
            // First valid row ignores and overwrites stale line RAM.
        end else begin
            out_valid<=0;
            // Read x+1 while accepting x, using the internal raster position.
            // The next pixel may arrive immediately: no additional gap/ready.
            // Bad coordinates still advance expected_x in the original FSM,
            // so prefetch follows that same advancement, not malformed in_x.
            if(accepting && !row_last_expected) begin
                prefetched_up[0]<=line_label[0][this_expected_x+9'd1];
                prefetched_up[1]<=line_label[1][this_expected_x+9'd1];
            end
            if(state==CANON) begin
                // This edge also writes line[0]; forwarding the canonical
                // value avoids old-data RAM semantics. Retirement preserves
                // this root because live_roots marks every canonical label.
                // New SOP wins below and its first row never consumes up.
                if(canon_index==0 && !accepting) begin
                    prefetched_up[0]<=canonical_red;
                    prefetched_up[1]<=canonical_blue;
                end
                line_label[0][canon_index]<=canonical_red;line_label[1][canon_index]<=canonical_blue;
                if(canonical_red!=0)live_roots[0][int'(canonical_red)-1]<=1;
                if(canonical_blue!=0)live_roots[1][int'(canonical_blue)-1]<=1;
                if(canon_index==9'(W-1))begin state<=RETIRE;scan_index<=0;end
                else canon_index<=canon_index+9'd1;
            end
            if(state==RETIRE) begin
                // All remaining line references are now canonical. Retain roots
                // in their original slots; no descriptor-moving compaction.
                for(int c=0;c<2;c++) begin
                    if(!free_slots[c][scan_index] &&
                       (parent[c][scan_index]!=scan_index+4'd1 || end_frame || !live_roots[c][scan_index])) begin
                        free_slots[c][scan_index]<=1;
                        parent[c][scan_index]<=scan_index+4'd1;boxes[c][scan_index]<='0;
                    end
                    if(retireCandidate[c]&&!insertCandidate[c])current_overflow[c]<=1;
                end
                if(insertCandidate[0])begin
                    workCandidates[workCount[3:0]]<=scan_red;workColours[workCount[3:0]]<=0;
                    work_red_count<=work_red_count+5'd1;
                end
                if(insertCandidate[1])begin
                    workCandidates[blueInsertSlot[3:0]]<=scan_blue;workColours[blueInsertSlot[3:0]]<=1;
                    work_blue_count<=work_blue_count+5'd1;
                end
                workCount<=workCount+5'(insertCandidate[0])+5'(insertCandidate[1]);
                if(scan_index==4'(ACTIVE_CAP-1))state<=ROW_DONE;
                else scan_index<=scan_index+4'd1;
            end
            if(state==ROW_DONE) begin
                if(end_frame) begin
                    out_valid<=1;frame_valid<=publish_ok;
                    sharedCandidates<=publishCandidates;sharedColours<=publish_ok?workColours:16'd0;
                    sharedCount<=publish_ok?workCount:5'd0;
                    red_count<=publish_ok?work_red_count:5'd0;blue_count<=publish_ok?work_blue_count:5'd0;
                    frame_error<=current_bad || unexpected_publish_pixel;
                    overrun<=current_overrun || unexpected_publish_pixel;
                    red_overflow<=current_overflow[0];blue_overflow<=current_overflow[1];
                    overflow<=|current_overflow;frame_id<=current_id;state<=IDLE;
                end else state<=COLLECT;
            end
            if(housekeeping && in_valid && !in_sop) begin
                current_bad<=1;current_overrun<=1;
                if(in_eop) begin
                    end_frame<=1;
                    // Revisit roots passed before a late termination request.
                    // Freed slots prevent double insertion into the output pool.
                    if(!end_frame && state==RETIRE)begin state<=RETIRE;scan_index<=0;end
                end
            end
            if(starting) begin
                if(overlapping_start) begin
                    out_valid<=1;frame_valid<=0;frame_error<=1;overrun<=housekeeping;
                    red_overflow<=current_overflow[0];blue_overflow<=current_overflow[1];
                    overflow<=|current_overflow;frame_id<=current_id;
                    sharedCandidates<='0;sharedColours<=0;sharedCount<=0;red_count<=0;blue_count<=0;
                end
                next_id<=next_id+16'd1;current_id<=next_id+16'd1;current_overflow<=0;
                current_bad<=overlapping_start;current_overrun<=housekeeping;end_frame<=0;
                workCandidates<='0;workColours<=0;workCount<=0;work_red_count<=0;work_blue_count<=0;
                for(int c=0;c<2;c++) begin
                    free_slots[c]<='1;live_roots[c]<='0;allocation_peak[c]<=0;left_label[c]<=0;
                    for(int i=0;i<ACTIVE_CAP;i++)begin parent[c][i]<=4'(i+1);boxes[c][i]<='0;end
                end
            end
            if(accepting) begin
                current_bad<=(starting?overlapping_start:current_bad) || !coords_ok || in_mask==2'b11 || (in_eop!=last_expected);
                if(coords_ok) begin
                    line_label[0][in_x]<=0;line_label[1][in_x]<=0;left_label[0]<=0;left_label[1]<=0;
                    for(int pixelColour=0;pixelColour<2;pixelColour++)begin
                        if(in_mask==2'(pixelColour+1)) begin
                        line_label[pixelColour][in_x]<=pixelChosenLabel[pixelColour];left_label[pixelColour]<=pixelChosenLabel[pixelColour];
                        if(pixelCapacityHit[pixelColour])current_overflow[pixelColour]<=1;
                        if(pixelChosenLabel[pixelColour]!=0)boxes[pixelColour][int'(pixelChosenLabel[pixelColour])-1]<=pixelUpdatedBox[pixelColour];
                        if(pixelAllocate[pixelColour]) begin
                            free_slots[pixelColour][int'(pixelChosenLabel[pixelColour])-1]<=0;
                            parent[pixelColour][int'(pixelChosenLabel[pixelColour])-1]<=pixelChosenLabel[pixelColour];
                            if(starting || pixelOccupiedPlusOne[pixelColour]>allocation_peak[pixelColour])allocation_peak[pixelColour]<=pixelOccupiedPlusOne[pixelColour];
                        end
                        if(pixelMergedLabel[pixelColour]!=0)begin
                            // Aliases remain allocated until the existing
                            // canonicalisation/retirement pass: no early reuse.
                            for(int aliasSlot=0;aliasSlot<ACTIVE_CAP;aliasSlot++)
                                if(parent[pixelColour][aliasSlot]==pixelMergedLabel[pixelColour])
                                    parent[pixelColour][aliasSlot]<=pixelChosenLabel[pixelColour];
                            boxes[pixelColour][int'(pixelMergedLabel[pixelColour])-1].valid<=0;boxes[pixelColour][int'(pixelMergedLabel[pixelColour])-1].area<=0;
                        end
                    end
                    end
                end
                if(last_expected)begin expected_x<=0;expected_y<=0;end
                else if(row_last_expected)begin expected_x<=0;expected_y<=this_expected_y+8'd1;end
                else begin expected_x<=this_expected_x+9'd1;expected_y<=this_expected_y;end
                if(in_eop || row_last_expected) begin
                    state<=CANON;canon_index<=0;scan_index<=0;live_roots[0]<='0;live_roots[1]<='0;
                    end_frame<=in_eop || last_expected;
                end else state<=COLLECT;
            end
        end
    end
`ifndef SYNTHESIS
    initial begin
        assert(W>=1 && W<=320 && H>=1 && H<=240)else $fatal(1,"geometry must fit native 320x240");
        assert(CAP>=1 && CAP<=MAX_CANDIDATES)else $fatal(1,"CAP must be 1..16");
        assert(SHARED_POOL || CAP<=MAX_CANDIDATES/2)else $fatal(1,"legacy split limits must fit the shared storage");
        assert(ACTIVE_CAP>=1 && ACTIVE_CAP<=15)else $fatal(1,"ACTIVE_CAP must fit four-bit nonzero labels 1..15");
        assert(MIN_AREA>=1 && MIN_AREA<=W*H)else $fatal(1,"MIN_AREA outside frame size");
    end
    always_ff @(posedge clk)if(!reset)begin
        assert(work_red_count<=CAP && work_blue_count<=CAP)else $fatal(1,"completed pool count out of range");
        assert(workCount==work_red_count+work_blue_count && workCount<=MAX_CANDIDATES &&
            (!SHARED_POOL||workCount<=CAP))else $fatal(1,"shared completed pool accounting failed");
        assert(allocation_peak[0]<=ACTIVE_CAP && allocation_peak[1]<=ACTIVE_CAP)else $fatal(1,"active allocation peak out of range");
        if(out_valid && !frame_valid)begin
            assert(red_count==0 && blue_count==0 && sharedCount==0 && sharedColours==0)else $fatal(1,"invalid frame published counts/colours");
            for(int i=0;i<MAX_CANDIDATES;i++)assert(!sharedCandidates[i].valid)else $fatal(1,"invalid frame published candidate");
        end
    end
`endif
endmodule
