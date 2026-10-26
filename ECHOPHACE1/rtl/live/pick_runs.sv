`timescale 1ns/1ps
/*
 *  pick_runs.sv -- the simplest picker: every run of columns above a threshold is one boundary.
 *
 *  Walks the finished column profile (start -> rd_x/rd_val, one-cycle read latency) and reports the
 *  centre of each run of consecutive columns whose value exceeds `thr`. Runs whose centres are closer
 *  than `min_gap` are merged (the first is kept), so that the two sides of a narrow gap between keys,
 *  which both show as edges, count once.
 *
 *  What it does not do, and what Lesson 4's peak picker (3.2d) adds at R-V3: it does not look for the
 *  local maximum inside a run (non-maximum suppression), and it has one threshold, not two (hysteresis).
 *  A run that straddles the threshold at its edges therefore moves its centre with the threshold.
 */
module pick_runs #(
    parameter int W    = 320,
    parameter int AW   = 20,
    parameter int NMAX = 32
) (
    input  logic                    clk,
    input  logic                    reset,
    input  logic                    start,
    input  logic [AW-1:0]           thr,
    input  logic [$clog2(W)-1:0]    min_gap,
    output logic [$clog2(W)-1:0]    rd_x,
    input  logic [AW-1:0]           rd_val,
    output logic                    busy,
    output logic                    done,
    output logic [$clog2(NMAX):0]   count,
    input  logic [$clog2(NMAX)-1:0] idx,
    output logic [$clog2(W)-1:0]    pos_of
);
    localparam int XW = $clog2(W);
    logic [XW-1:0] pos [0:NMAX-1];
    assign pos_of = pos[idx];

    typedef enum logic [1:0] {IDLE, WALK, FIN} state_t;
    state_t state;
    logic [XW:0]   x;                 // address being read (one ahead of the value examined)
    logic [XW-1:0] cur_x;             // the column rd_val belongs to
    logic          in_run;            // inside a run of columns above thr
    logic [XW-1:0] run_start, last_pos;
    logic          have_last;

    assign rd_x = x[XW-1:0];
    assign busy = (state == WALK);

    // store the run that has just ended (its centre), unless it is within min_gap of the last one
    task automatic end_run(input logic [XW-1:0] run_end);
        logic [XW:0]   sum;                   // one bit wider: run_start + run_end can exceed W
        logic [XW-1:0] centre;
        sum = {1'b0, run_start} + {1'b0, run_end};
        centre = sum[XW:1];
        if (!(have_last && (centre - last_pos) < min_gap) && count < NMAX) begin
            pos[count] <= centre; count <= count + 1'b1; last_pos <= centre; have_last <= 1'b1;
        end
    endtask

    always_ff @(posedge clk) begin
        done <= 1'b0;
        if (reset) begin
            state <= IDLE; count <= '0; x <= '0; in_run <= 1'b0; have_last <= 1'b0;
        end else case (state)
            IDLE: if (start) begin
                x <= '0; count <= '0; in_run <= 1'b0; have_last <= 1'b0; state <= WALK;
            end
            WALK: begin
                x     <= x + 1'b1;
                cur_x <= XW'(x - 1);                  // rd_val was read from x-1 (one-cycle latency)
                if (x >= 1) begin
                    if (rd_val > thr) begin
                        if (!in_run) begin in_run <= 1'b1; run_start <= XW'(x - 1); end
                    end else if (in_run) begin
                        in_run <= 1'b0; end_run(XW'(x - 2));
                    end
                end
                if (x == W) begin                     // the last real column has been examined
                    if (in_run) begin in_run <= 1'b0; end_run(XW'(W - 1)); end
                    state <= FIN;
                end
            end
            FIN: begin done <= 1'b1; state <= IDLE; end
            default: state <= IDLE;
        endcase
    end
endmodule
