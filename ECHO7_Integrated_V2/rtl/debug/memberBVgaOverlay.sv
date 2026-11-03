// Raw HSV display contours followed by accepted-marker digit labels. Top ports
// add VGA-domain SW0/SW1 enables. Contours mean colour segmentation only; they include the blue
// calibration reference and never grant a marker ID. There are no large boxes.
module memberBVgaOverlay #(
    parameter int MAX_HOLD_FRAMES=10,
    parameter bit ENABLE_DIAGNOSTICS=1,
    parameter int BLUE_HUE_UPPER=260,
    parameter int DEFAULT_BLUE_MINIMUM=20
) (
    input logic clk, reset,
    input logic [perception_pkg::DEBUG_WORD_COUNT*32-1:0] debugWords,
    input logic showCandidates,showCentre,
    input logic [29:0] inData,
    input logic inSop,inEop,inValid,
    output logic inReady,
    output logic [29:0] outData,
    output logic outSop,outEop,outValid,
    input logic outReady
);
    logic [perception_pkg::DEBUG_WORD_COUNT*32-1:0] frameDebug;
    logic [29:0] contourData;
    logic contourSop,contourEop,contourValid,contourReady,contourInputReady;
    logic pendingSop;
    logic [29:0] labelData;
    logic labelSop,labelEop,labelValid,labelReady;
    wire allowInput=!inSop || !pendingSop;
    assign inReady=contourInputReady && allowInput;
    logic [7:0] redMinimum,blueMinimum;
    // The upstream camera_display emits 640x480 packets. Freeze its coherent
    // debug packet at accepted SOP so the two-cycle contour delay cannot select
    // another configuration for the digit-label stage. This is metadata only.
    // A new SOP waits until the preceding SOP reaches the label stage, so even
    // consecutive one-pixel/truncated packets cannot overwrite its metadata.
    always_ff @(posedge clk)begin
        if(reset)begin frameDebug<=0;pendingSop<=0;end
        else begin
            if(ENABLE_DIAGNOSTICS ? (labelValid&&labelReady&&labelSop) :
                                   (contourValid&&contourReady&&contourSop))pendingSop<=0;
            if(inValid && inReady && inSop)begin frameDebug<=debugWords;pendingSop<=1;end
        end
    end
    always_comb begin
        redMinimum=8'd48;blueMinimum=8'(DEFAULT_BLUE_MINIMUM);
        if(debugWords[31:0]==32'h45425031)begin
            redMinimum=debugWords[7*32+8+:8];blueMinimum=debugWords[7*32+:8];
        end
    end
    memberBVgaContour #(.BLUE_HUE_UPPER(BLUE_HUE_UPPER)) contours(.clk(clk),.reset(reset),.redMinimum(redMinimum),.blueMinimum(blueMinimum),
        .inData(inData),.inSop(inSop),.inEop(inEop),.inValid(inValid && allowInput),.inReady(contourInputReady),
        .outData(contourData),.outSop(contourSop),.outEop(contourEop),.outValid(contourValid),.outReady(contourReady));
    memberBVgaLabels #(.MAX_HOLD_FRAMES(MAX_HOLD_FRAMES)) labels(
        .clk(clk),.reset(reset),.debugWords(frameDebug),
        .inData(contourData),.inSop(contourSop),.inEop(contourEop),.inValid(contourValid),.inReady(contourReady),
        .outData(labelData),.outSop(labelSop),.outEop(labelEop),.outValid(labelValid),.outReady(labelReady));
    generate if(ENABLE_DIAGNOSTICS)begin:withDiagnostics
        memberBVgaDiagnostics #(.BLUE_HUE_UPPER(BLUE_HUE_UPPER),.DEFAULT_BLUE_MINIMUM(DEFAULT_BLUE_MINIMUM)) diagnostics(.clk(clk),.reset(reset),.showCandidates(showCandidates),.showCentre(showCentre),
            .debugWords(frameDebug),.rawDebugWords(debugWords),.rawData(inData),.rawSop(inSop),.rawEop(inEop),.rawAccept(inValid&&inReady),
            .inData(labelData),.inSop(labelSop),.inEop(labelEop),.inValid(labelValid),.inReady(labelReady),
            .outData(outData),.outSop(outSop),.outEop(outEop),.outValid(outValid),.outReady(outReady));
    end else begin:withoutDiagnostics
        assign outData=labelData;assign outSop=labelSop;assign outEop=labelEop;assign outValid=labelValid;assign labelReady=outReady;
    end endgenerate
endmodule
