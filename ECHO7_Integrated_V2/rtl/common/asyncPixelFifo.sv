// Dual-clock FIFO, registered read, power-of-two depth. Only Gray pointers cross
// synchronisers; the data RAM is read after its write has crossed the pointer
// pipeline. readValid accompanies the registered readData one cycle after pop.
// Both sides must share the same reset epoch. No RAM reset loop: infer M10K.
module asyncPixelFifo #(parameter int WIDTH=80, ADDRESS_BITS=8) (
    input logic writeClk, writeReset, writeValid,
    input logic [WIDTH-1:0] writeData,
    output logic full,
    input logic readClk, readReset, readEnable,
    output logic [WIDTH-1:0] readData,
    output logic readValid, empty
);
    localparam int POINTER_BITS=ADDRESS_BITS+1;
    (* ramstyle="M10K, no_rw_check" *) logic [WIDTH-1:0] memory [0:(1<<ADDRESS_BITS)-1];
    logic [POINTER_BITS-1:0] writeBinary, writeGray, readBinary, readGray;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS; -name DONT_MERGE_REGISTER ON; -name PRESERVE_REGISTER ON" *) logic [POINTER_BITS-1:0] readGrayMeta, readGraySync;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS; -name DONT_MERGE_REGISTER ON; -name PRESERVE_REGISTER ON" *) logic [POINTER_BITS-1:0] writeGrayMeta, writeGraySync;
    wire [POINTER_BITS-1:0] writeNext=writeBinary+{{ADDRESS_BITS{1'b0}},(writeValid&&!full)};
    wire [POINTER_BITS-1:0] readNext=readBinary+{{ADDRESS_BITS{1'b0}},(readEnable&&!empty)};
    wire [POINTER_BITS-1:0] writeNextGray=(writeNext>>1)^writeNext;
    wire [POINTER_BITS-1:0] readNextGray=(readNext>>1)^readNext;
    always_ff @(posedge writeClk) begin
        if(writeValid && !full) memory[writeBinary[ADDRESS_BITS-1:0]]<=writeData;
        if(writeReset) begin
            writeBinary<=0; writeGray<=0; readGrayMeta<=0; readGraySync<=0; full<=0;
        end else begin
            readGrayMeta<=readGray; readGraySync<=readGrayMeta;
            writeBinary<=writeNext; writeGray<=writeNextGray;
            full<=writeNextGray=={~readGraySync[POINTER_BITS-1:POINTER_BITS-2],readGraySync[POINTER_BITS-3:0]};
        end
    end
    always_ff @(posedge readClk) begin
        if(readEnable && !empty) readData<=memory[readBinary[ADDRESS_BITS-1:0]];
        if(readReset) begin
            readBinary<=0; readGray<=0; writeGrayMeta<=0; writeGraySync<=0;
            empty<=1; readValid<=0;
        end else begin
            writeGrayMeta<=writeGray; writeGraySync<=writeGrayMeta;
            readBinary<=readNext; readGray<=readNextGray;
            empty<=readNextGray==writeGraySync;
            readValid<=readEnable&&!empty;
        end
    end
endmodule
