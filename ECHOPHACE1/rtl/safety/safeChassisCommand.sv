// ECHO-7 team; AI-assisted by OpenAI Codex. Adapted from course chassis_command.
// Preserve T:1 JSON / 115200 8N1. Finish an in-flight line before priority stop.
// KEY0 requests zero; only power-on resets the UART, avoiding partial JSON on KEY0.
module safeChassisCommand #(parameter int CLKS_PER_BIT=434, PERIOD_CLKS=10_000_000) (
    input logic clk, reset, stop_active,
    input logic signed [3:0] safe_left,safe_right,
    output logic tx,busy,
    output logic zero_line_started, line_done
);
    localparam int N=26, PW=$clog2(PERIOD_CLKS+1);
    logic [1:0] power_reset=2'b11;
    always_ff @(posedge clk) power_reset<={power_reset[0],1'b0};
    logic [N*8-1:0] text_bytes='0;
    logic [5:0] remaining=0;
    logic [PW-1:0] timer=0;
    logic pending_stop=1, was_stop=1, was_nonzero=0, sending=0;
    logic uart_ready,uart_valid;
    wire effective_stop=reset || stop_active;
    wire nonzero=(safe_left!=0 || safe_right!=0);
    wire urgent=effective_stop && !was_stop || (!nonzero && was_nonzero);
    wire send_zero=effective_stop || pending_stop || urgent;
    function automatic logic [N*8+7:0] build_line(input logic signed [3:0] l,r);
        logic [7:0] ld,rd;
        logic [3:0] lm,rm;
        logic [N*8-1:0] t;
        lm=(l<0) ? -l:l; rm=(r<0) ? -r:r;
        ld=8'h30+{4'd0,lm}; rd=8'h30+{4'd0,rm};
        t='0;
        case ({l<0,r<0})
            2'b00: begin t[N*8-1 -:192]={"{\"T\":1,\"L\":0.",ld,",\"R\":0.",rd,"}\n"}; return {8'd24,t}; end
            2'b01: begin t[N*8-1 -:200]={"{\"T\":1,\"L\":0.",ld,",\"R\":-0.",rd,"}\n"}; return {8'd25,t}; end
            2'b10: begin t[N*8-1 -:200]={"{\"T\":1,\"L\":-0.",ld,",\"R\":0.",rd,"}\n"}; return {8'd25,t}; end
            default: begin t={"{\"T\":1,\"L\":-0.",ld,",\"R\":-0.",rd,"}\n"}; return {8'd26,t}; end
        endcase
    endfunction
    logic [N*8+7:0] next_line;
    always_comb next_line=build_line(send_zero ? 4'sd0:safe_left,send_zero ? 4'sd0:safe_right);
    assign uart_valid=(remaining!=0);
    uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) tx_u (
        .clk(clk),.rst(power_reset[1]),.data_tx(text_bytes[N*8-1 -:8]),
        .valid(uart_valid),.uart_out(tx),.ready(uart_ready));
    always_ff @(posedge clk) begin
        zero_line_started<=0; line_done<=0;
        was_stop<=effective_stop; was_nonzero<=nonzero;
        if (timer<PW'(PERIOD_CLKS)) timer<=timer+1'b1;
        if (urgent || reset) pending_stop<=1;
        if (power_reset[1]) begin
            remaining<=0; sending<=0; pending_stop<=1; timer<=0;
        end else begin
            if (uart_valid && uart_ready) begin
                text_bytes<=text_bytes<<8;
                remaining<=remaining-1'b1;
            end
            if (remaining==0 && uart_ready) begin
                if (sending) begin sending<=0; line_done<=1; end
                if (pending_stop || urgent || timer>=PW'(PERIOD_CLKS)) begin
                    remaining<=6'(next_line[N*8+:8]); text_bytes<=next_line[N*8-1:0];
                    pending_stop<=0; timer<=0; sending<=1;
                    zero_line_started<=send_zero || !nonzero;
                end
            end
        end
    end
    assign busy=sending || !uart_ready;
endmodule
