// ECHO-7 Part A | Human owner: Member A (name/SID pending).
// AI-assisted by OpenAI Codex; human review required.
// V2: exact 4-connected CCL. CAP bounds active handles (including aliases);
// a separate CAP completed pool applies MIN_AREA when roots retire.
// Never reuse within a row. Canonicalize ALL W line entries before freeing
// aliases or absent roots. Either capacity overflow invalidates the whole frame.
// Output order is retirement order; area is exact, centre is bbox midpoint.
// Leave W+CAP invalid clocks after each row; the next edge accepts a new row.
// Final publication: W+CAP+1 clocks after EOP. No ready/backpressure.
// Unexpected housekeeping pixels flag error+overrun; EOP forces termination.
// New SOP aborts old and new frames invalid; next complete frame recovers.
// IDs count every SOP, first=1, modulo65536. SOP on publication edge is legal.
module boundedCandidates #(
    parameter int W=320, H=240, CAP=8, MIN_AREA=32
) (
    input logic clk, reset,
    input logic in_valid, in_sop, in_eop,
    input logic [1:0] in_mask,
    input logic [8:0] in_x,
    input logic [7:0] in_y,
    output part_a_pkg::candidate_t [7:0] red_candidates, blue_candidates,
    output logic [3:0] red_count, blue_count,
    output logic out_valid, frame_valid,
    output logic red_overflow, blue_overflow, overflow,
    output logic frame_error, overrun,
    output logic [15:0] frame_id,
    output wire busy
);
    import part_a_pkg::*;
    typedef enum logic [2:0] {IDLE,COLLECT,CANON,RETIRE,ROW_DONE} state_t;
    state_t state;
    logic [3:0] line_label [0:1][0:W-1], left_label [0:1];
    logic [3:0] parent [0:1][0:CAP-1];
    candidate_t boxes [0:1][0:CAP-1];
    logic [CAP-1:0] free_slots [0:1], live_roots [0:1];
    // Bench-visible high-water mark; aliases occupy handles until row seal.
    logic [3:0] allocation_peak [0:1];
    logic [1:0] current_overflow;
    logic current_bad, current_overrun, end_frame;
    logic [15:0] next_id, current_id;
    logic [8:0] expected_x, canon_index;
    logic [7:0] expected_y;
    logic [3:0] scan_index, work_red_count, work_blue_count;
    candidate_array_t work_red, work_blue, publish_red, publish_blue;
    candidate_t scan_red, scan_blue;
    logic publish_ok;
    assign busy = state != IDLE;

    function automatic logic [3:0] root_of(input logic colour,input logic [3:0] label_id);
        logic [3:0] r;
        r=label_id;
        for(int step=0;step<CAP;step++) begin
            if(r!=0 && int'(r)<=CAP) r=parent[colour][int'(r)-1];
            else r=0;
        end
        return r;
    endfunction
    function automatic logic [3:0] used_count(input logic [CAP-1:0] available);
        logic [3:0] n;
        n=0;
        for(int i=0;i<CAP;i++) if(!available[i]) n=n+4'd1;
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
    logic colour, allocate_pixel, capacity_hit;
    logic [CAP-1:0] available;
    logic [3:0] chosen_label,merged_label,left_root,up_root,canonical_red,canonical_blue,occupied_plus_one;
    candidate_t updated_box;
    always_comb begin
        colour=in_mask==2'b10;
        available=starting?{CAP{1'b1}}:free_slots[colour];
        occupied_plus_one=used_count(available)+4'd1;
        chosen_label=0;merged_label=0;left_root=0;up_root=0;
        allocate_pixel=0;capacity_hit=0;updated_box='0;
        if(accepting && coords_ok && (in_mask==1 || in_mask==2)) begin
            if(in_x!=0 && !starting)left_root=root_of(colour,left_label[colour]);
            if(in_y!=0 && !starting)up_root=root_of(colour,line_label[colour][in_x]);
            if(left_root==0 && up_root==0) begin
                for(int i=0;i<CAP;i++)if(chosen_label==0 && available[i])chosen_label=4'(i+1);
                if(chosen_label!=0) begin
                    allocate_pixel=1;updated_box.valid=1;
                    updated_box.xmin=in_x;updated_box.xmax=in_x;
                    updated_box.ymin=in_y;updated_box.ymax=in_y;updated_box.area=17'd1;
                end else capacity_hit=1;
            end else if(left_root==0 || up_root==0 || left_root==up_root) begin
                chosen_label=left_root!=0?left_root:up_root;
                updated_box=add_pixel(boxes[colour][int'(chosen_label)-1],in_x,in_y);
            end else begin
                chosen_label=left_root<up_root?left_root:up_root;
                merged_label=left_root<up_root?up_root:left_root;
                updated_box=add_pixel(union_boxes(boxes[colour][int'(chosen_label)-1],boxes[colour][int'(merged_label)-1]),in_x,in_y);
            end
        end
    end
    always_comb begin
        canonical_red=0;canonical_blue=0;
        if(state==CANON) begin
            canonical_red=root_of(0,line_label[0][canon_index]);
            canonical_blue=root_of(1,line_label[1][canon_index]);
        end
        scan_red='0;scan_blue='0;
        if(state==RETIRE && int'(scan_index)<CAP) begin
            scan_red=with_centre(boxes[0][scan_index]);scan_blue=with_centre(boxes[1][scan_index]);
        end
        publish_ok=!current_bad && current_overflow==0 && !unexpected_publish_pixel;
        publish_red=work_red;publish_blue=work_blue;
        for(int i=0;i<8;i++) begin
            publish_red[i].valid=work_red[i].valid && publish_ok;
            publish_blue[i].valid=work_blue[i].valid && publish_ok;
        end
    end
    always_ff @(posedge clk) begin
        if(reset) begin
            state<=IDLE;expected_x<=0;expected_y<=0;next_id<=0;current_id<=0;
            current_overflow<=0;current_bad<=0;current_overrun<=0;end_frame<=0;
            canon_index<=0;scan_index<=0;work_red_count<=0;work_blue_count<=0;
            work_red<='0;work_blue<='0;
            red_candidates<='0;blue_candidates<='0;red_count<=0;blue_count<=0;
            out_valid<=0;frame_valid<=0;frame_error<=0;overrun<=0;
            red_overflow<=0;blue_overflow<=0;overflow<=0;frame_id<=0;
            for(int c=0;c<2;c++) begin
                free_slots[c]<='1;live_roots[c]<='0;allocation_peak[c]<=0;left_label[c]<=0;
                for(int i=0;i<CAP;i++) begin parent[c][i]<=4'(i+1);boxes[c][i]<='0;end
            end
            // First valid row ignores and overwrites stale line RAM.
        end else begin
            out_valid<=0;
            if(state==CANON) begin
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
                        if(parent[c][scan_index]==scan_index+4'd1 && boxes[c][scan_index].valid && int'(boxes[c][scan_index].area)>=MIN_AREA) begin
                            if(c==0) begin
                                if(int'(work_red_count)<CAP)begin work_red[work_red_count]<=scan_red;work_red_count<=work_red_count+4'd1;end
                                else current_overflow[0]<=1;
                            end else begin
                                if(int'(work_blue_count)<CAP)begin work_blue[work_blue_count]<=scan_blue;work_blue_count<=work_blue_count+4'd1;end
                                else current_overflow[1]<=1;
                            end
                        end
                    end
                end
                if(scan_index==4'(CAP-1))state<=ROW_DONE;
                else scan_index<=scan_index+4'd1;
            end
            if(state==ROW_DONE) begin
                if(end_frame) begin
                    out_valid<=1;frame_valid<=publish_ok;
                    red_candidates<=publish_red;blue_candidates<=publish_blue;
                    red_count<=publish_ok?work_red_count:4'd0;blue_count<=publish_ok?work_blue_count:4'd0;
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
                    red_candidates<='0;blue_candidates<='0;red_count<=0;blue_count<=0;
                end
                next_id<=next_id+16'd1;current_id<=next_id+16'd1;current_overflow<=0;
                current_bad<=overlapping_start;current_overrun<=housekeeping;end_frame<=0;
                work_red<='0;work_blue<='0;work_red_count<=0;work_blue_count<=0;
                for(int c=0;c<2;c++) begin
                    free_slots[c]<='1;live_roots[c]<='0;allocation_peak[c]<=0;left_label[c]<=0;
                    for(int i=0;i<CAP;i++)begin parent[c][i]<=4'(i+1);boxes[c][i]<='0;end
                end
            end
            if(accepting) begin
                current_bad<=(starting?overlapping_start:current_bad) || !coords_ok || in_mask==2'b11 || (in_eop!=last_expected);
                if(coords_ok) begin
                    line_label[0][in_x]<=0;line_label[1][in_x]<=0;left_label[0]<=0;left_label[1]<=0;
                    if(in_mask==1 || in_mask==2) begin
                        line_label[colour][in_x]<=chosen_label;left_label[colour]<=chosen_label;
                        if(capacity_hit)current_overflow[colour]<=1;
                        if(chosen_label!=0)boxes[colour][int'(chosen_label)-1]<=updated_box;
                        if(allocate_pixel) begin
                            free_slots[colour][int'(chosen_label)-1]<=0;
                            parent[colour][int'(chosen_label)-1]<=chosen_label;
                            if(starting || occupied_plus_one>allocation_peak[colour])allocation_peak[colour]<=occupied_plus_one;
                        end
                        if(merged_label!=0)begin
                            parent[colour][int'(merged_label)-1]<=chosen_label;
                            boxes[colour][int'(merged_label)-1].valid<=0;boxes[colour][int'(merged_label)-1].area<=0;
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
        assert(CAP>=1 && CAP<=8)else $fatal(1,"CAP must be 1..8");
        assert(MIN_AREA>=1 && MIN_AREA<=W*H)else $fatal(1,"MIN_AREA outside frame size");
    end
    always_ff @(posedge clk)if(!reset)begin
        assert(work_red_count<=CAP && work_blue_count<=CAP)else $fatal(1,"completed pool count out of range");
        assert(allocation_peak[0]<=CAP && allocation_peak[1]<=CAP)else $fatal(1,"active allocation peak out of range");
        if(out_valid && !frame_valid)begin
            assert(red_count==0 && blue_count==0)else $fatal(1,"invalid frame published counts");
            for(int i=0;i<8;i++)assert(!red_candidates[i].valid && !blue_candidates[i].valid)else $fatal(1,"invalid frame published candidate");
        end
    end
`endif
endmodule
