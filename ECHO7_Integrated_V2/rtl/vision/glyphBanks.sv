// Two 320x240 banks, still two bits per pixel (37.5 KiB total). Readers 3/4
// encode 00 background, 01 raw colour, 10 stroke-only white, 11 strong white.
// The exact RGB565/HSV predicates are mutually exclusive for all 65,536 inputs;
// changing either predicate requires rerunning that exhaustive invariant test.
// Ownership is controlled by
// perceptionCore: only WRITING may be written and only READING may be read.
// No reset of memory data; FREE/WRITING/READY/READING state invalidates old data.
// Read data has one synchronous clock of latency. No full RGB frame is added.
module glyphBanks (
    input logic clk, writeEnable, writeBank,
    input logic [16:0] writeAddress,
    input logic writeWhite,writeStrongWhite,writeColour,
    input logic readBank,
    input logic [16:0] readAddress,
    output logic readWhite,readStrongWhite,readColour
);
    (* ramstyle="M10K, no_rw_check" *) logic [1:0] bank0 [0:76799];
    (* ramstyle="M10K, no_rw_check" *) logic [1:0] bank1 [0:76799];
    logic [1:0] read0,read1;
    logic readBankDelayed;
    wire [1:0] writeCode=writeStrongWhite?2'b11:writeWhite?2'b10:writeColour?2'b01:2'b00;
    wire [1:0] readCode=readBankDelayed?read1:read0;
    always_ff @(posedge clk) begin
        if(writeEnable && !writeBank) bank0[writeAddress]<=writeCode;
        if(writeEnable && writeBank) bank1[writeAddress]<=writeCode;
        read0<=bank0[readAddress]; read1<=bank1[readAddress];
        readBankDelayed<=readBank;
    end
    assign readWhite=readCode[1];
    assign readStrongWhite=readCode==2'b11;
    assign readColour=readCode==2'b01;
    // synthesis translate_off
    always @(posedge clk) if(writeEnable) begin
        assert(!(writeWhite&&writeColour)&&(!writeStrongWhite||writeWhite))
            else $fatal(1,"Glyph code predicates overlap or strong white is not white");
    end
    // synthesis translate_on
endmodule
