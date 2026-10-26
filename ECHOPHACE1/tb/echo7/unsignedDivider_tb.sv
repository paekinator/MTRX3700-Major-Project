// ECHO-7 team | AI-assisted by OpenAI Codex; human review pending.
`timescale 1ns/1ps
module unsignedDivider_tb;
    logic clk=0; always #20 clk=~clk;
    logic reset=1,start=0;
    logic [26:0] numerator=0,denominator=0;
    wire busy,done,divide_by_zero;
    wire [26:0] quotient;
    unsignedDivider dut(.*);
    task automatic check(input logic [26:0] n,d);
        int cycles;
        @(negedge clk); numerator=n; denominator=d; start=1;
        @(negedge clk); start=0; cycles=0;
        while(!done && cycles<28) begin @(negedge clk); cycles++; end
        if(!done || busy || divide_by_zero!==(d==0)) $fatal(1,"Divider protocol failure");
        if(quotient !== (d==0 ? 27'd0 : n/d)) $fatal(1,"Divider mismatch n=%0d d=%0d q=%0d",n,d,quotient);
    endtask
    initial begin
        repeat(3) @(negedge clk); reset=0;
        check(0,1); check(1,1); check(27'h7ffffff,1); check(27'h7ffffff,27'h7ffffff);
        check(1,307200); check(78336000,307200); check(123,0);
        for(int i=0;i<1000;i++) check(27'($urandom),27'($urandom));
        @(negedge clk); start=1; numerator=456; denominator=7;
        @(negedge clk); start=0; repeat(3) @(negedge clk); reset=1;
        @(negedge clk); if(busy || done || quotient!=0) $fatal(1,"Divider reset failure");
        reset=0; check(456,7);
        $display("PASS unsignedDivider_tb: exact quotients, zero, limits, 1000 random cases, reset"); $finish;
    end
    initial begin #5ms; $fatal(1,"Divider timeout"); end
endmodule
