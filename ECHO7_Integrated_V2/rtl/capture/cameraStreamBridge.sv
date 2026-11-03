// Preserve native pixels and SOF metadata across PCLK -> CLOCK_50. Source time is
// a registered Gray-coded shared microsecond counter: its two-PCLK observation
// delay is bounded and recorded, unlike a processing/publication timestamp.
// Target requests use a held-word handshake and are bound at the actual SOF.
module cameraStreamBridge (
    input logic pclk, resetPclk, frameStart, pixelValid,
    input logic [15:0] pixel,
    input logic [9:0] pixelX,
    input logic [8:0] pixelY,
    input logic clk, reset,
    input logic [31:0] timeUs,
    input perception_pkg::targetRequest_t activeRequest,
    input logic streamReady,
    output logic streamValid,
    output logic [79:0] streamData,
    output logic transportFault
);
    logic [31:0] timeGray;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS; -name DONT_MERGE_REGISTER ON; -name PRESERVE_REGISTER ON" *) logic [31:0] timeGrayMeta, timeGraySync;
    logic [31:0] cameraTime;
    logic [15:0] frameId;
    logic sourceFault,frameDrop;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS; -name DONT_MERGE_REGISTER ON; -name PRESERVE_REGISTER ON" *) logic [1:0] faultSync;
    logic [$bits(perception_pkg::targetRequest_t)-1:0] cameraRequest;
    wire kept=pixelValid && !pixelX[0] && !pixelY[0] && pixelX<640 && pixelY<480;
    logic [79:0] fifoData;
    wire fifoFull, fifoEmpty;
    // No request is issued while a previous registered FIFO read is in flight.
    logic readPending;
    wire pop=streamReady && !readPending && !fifoEmpty;
    heldBusCdc #(.WIDTH($bits(perception_pkg::targetRequest_t))) requestCdc (
        .sourceClk(clk),.sourceReset(reset),.sourceData(activeRequest),
        .destinationClk(pclk),.destinationReset(resetPclk),
        .destinationData(cameraRequest),.destinationValid());
    always_ff @(posedge clk) begin
        if(reset) begin timeGray<=0;faultSync<=0;readPending<=0; end
        else begin
            timeGray<=(timeUs>>1)^timeUs;
            faultSync<={faultSync[0],sourceFault};
            readPending<=pop;
        end
    end
    assign transportFault=faultSync[1];
    always_comb begin
        cameraTime[31]=timeGraySync[31];
        for(int i=30;i>=0;i--) cameraTime[i]=cameraTime[i+1]^timeGraySync[i];
        fifoData=0;
        if(frameStart) begin
            fifoData[79]=1;
            // A loss invalidates the next delivered SOF conservatively. The
            // sticky diagnostic is separate, so later complete frames recover.
            fifoData[78]=frameDrop;
            // v3 occupies two formerly spare SOF bits; pixel FIFO stays80bits.
            fifoData[50+:$bits(perception_pkg::targetRequest_t)]=cameraRequest;
            fifoData[49:34]=frameId+16'd1;
            fifoData[33:2]=cameraTime;
        end else begin
            fifoData[32:24]=pixelX[9:1];
            fifoData[23:16]=pixelY[8:1];
            fifoData[15:0]=pixel;
        end
    end
    always_ff @(posedge pclk) begin
        if(resetPclk) begin
            timeGrayMeta<=0;timeGraySync<=0;frameId<=0;sourceFault<=0;frameDrop<=0;
        end else begin
            timeGrayMeta<=timeGray;timeGraySync<=timeGrayMeta;
            if(frameStart) frameId<=frameId+16'd1;
            if(frameStart&&!fifoFull)frameDrop<=0;
            if((frameStart||kept)&&fifoFull)begin sourceFault<=1;frameDrop<=1;end
        end
    end
    asyncPixelFifo fifo (
        .writeClk(pclk),.writeReset(resetPclk),.writeValid((frameStart||kept)&&!resetPclk),
        .writeData(fifoData),.full(fifoFull),.readClk(clk),.readReset(reset),
        .readEnable(pop),.readData(streamData),.readValid(streamValid),.empty(fifoEmpty));
endmodule
