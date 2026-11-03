// Streaming horizontal support, retaining the complete same-colour run.
// MIN_RUN_LENGTH=3 preserves the historical algorithm; production colour3 uses
// 2 to retain the measured two-pixel connections on a rotated number-one sign.
// Both settings retain exactly the same accepted-token delay and row flush.
// Four raw history masks plus the incoming mask provide two pixels on either
// side of the output target. Two metadata tokens delay coordinates and SOP/EOP
// by accepted pixels; blank input clocks do not advance either history.
// At WIDTH-1 two zero-padding steps flush the final two pixels. The integration
// guarantees at least two idle clocks before the next row. A fresh SOP or x=0
// aborts any pending old row, so truncated frames cannot contaminate a new row.
module horizontalRunFilter #(
    parameter int WIDTH=320,
    parameter int MIN_RUN_LENGTH=3
) (
    input logic clk,reset,
    input logic in_valid,in_sop,in_eop,
    input logic [8:0] in_x,
    input logic [7:0] in_y,
    input logic [1:0] in_mask,
    output logic out_valid,out_sop,out_eop,
    output logic [8:0] out_x,
    output logic [7:0] out_y,
    output logic [1:0] out_mask
);
    // history0 is the immediately preceding raw pixel; history1 is the target.
    logic [1:0] history0,history1,history2,history3;
    logic token0Valid,token1Valid,token0Sop,token1Sop,token0Eop,token1Eop;
    logic [8:0] token0X,token1X;
    logic [7:0] token0Y,token1Y;
    logic [1:0] flushRemaining,newMask,filteredMask;
    logic restartRow,advance,realPixel;

    always_comb begin
        restartRow=in_valid&&(in_sop||in_x==9'd0);
        realPixel=in_valid&&(flushRemaining==2'd0);
        advance=!restartRow&&(realPixel||flushRemaining!=2'd0);
        newMask=2'd0;
        if(realPixel&&(in_mask==2'd1||in_mask==2'd2)) newMask=in_mask;
        filteredMask=2'd0;
        if(history1==2'd1||history1==2'd2) begin
            // history1 is the output target, history2 its left neighbour and
            // history0 its right neighbour. Only the predicate changes: do not
            // advance metadata sooner or remove either end-of-row padding step.
            if(MIN_RUN_LENGTH==2) begin
                if(history2==history1||history0==history1)
                    filteredMask=history1;
            end else if(MIN_RUN_LENGTH==3) begin
                if((history3==history1&&history2==history1)||
                   (history2==history1&&history0==history1)||
                   (history0==history1&&newMask==history1))
                    filteredMask=history1;
            end
        end
    end

    always_ff @(posedge clk) begin
        if(reset) begin
            history0<=0;history1<=0;history2<=0;history3<=0;
            token0Valid<=0;token1Valid<=0;
            token0Sop<=0;token1Sop<=0;token0Eop<=0;token1Eop<=0;
            token0X<=0;token1X<=0;token0Y<=0;token1Y<=0;
            flushRemaining<=0;
            out_valid<=0;out_sop<=0;out_eop<=0;
            out_x<=0;out_y<=0;out_mask<=0;
        end else begin
            out_valid<=0;out_sop<=0;out_eop<=0;out_mask<=0;
            if(restartRow) begin
                // Restart has priority over a pending flush. Only the new
                // frame/row's first real pixel enters the fresh history.
                history0<=(in_mask==2'd1||in_mask==2'd2)?in_mask:2'd0;
                history1<=0;history2<=0;history3<=0;
                token0Valid<=1;token1Valid<=0;
                token0Sop<=in_sop;token0Eop<=in_eop;
                token0X<=in_x;token0Y<=in_y;
                token1Sop<=0;token1Eop<=0;
                flushRemaining<=(in_x==9'(WIDTH-1))?2'd2:2'd0;
            end else if(advance) begin
                out_valid<=token1Valid;
                out_sop<=token1Valid&&token1Sop;
                out_eop<=token1Valid&&token1Eop;
                out_x<=token1X;out_y<=token1Y;
                out_mask<=token1Valid?filteredMask:2'd0;
                history3<=history2;history2<=history1;
                history1<=history0;history0<=newMask;
                token1Valid<=token0Valid;token0Valid<=realPixel;
                token1Sop<=token0Sop;token1Eop<=token0Eop;
                token1X<=token0X;token1Y<=token0Y;
                token0Sop<=realPixel&&in_sop;token0Eop<=realPixel&&in_eop;
                if(realPixel) begin token0X<=in_x;token0Y<=in_y;end
                if(flushRemaining!=2'd0) flushRemaining<=flushRemaining-2'd1;
                else if(in_x==9'(WIDTH-1)) flushRemaining<=2'd2;
            end
        end
    end
endmodule
