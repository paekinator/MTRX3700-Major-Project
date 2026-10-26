// ECHO-7 team | AI-assisted by OpenAI Codex; human review required.
// Both paths consume identical transactions and rendezvous at their output stages.
// This preserves the legacy dynamic renderer while calibrating original pixels.
module videoDiagnostics (
    input logic clk, reset,
    input logic [29:0] in_data,
    input logic [1:0] in_mask, in_mode,
    input logic in_overlay, in_calibration, in_sop, in_eop, in_valid,
    output wire in_ready,
    output wire [29:0] out_data,
    output wire out_sop, out_eop, out_valid,
    input logic out_ready
);
    wire dr, cr, dv, cv, ds, cs, de, ce, calibration;
    wire [29:0] dd, cd;
    assign in_ready=dr && cr;
    assign out_valid=dv && cv;
    assign out_data=calibration ? cd : dd;
    assign out_sop=cs;
    assign out_eop=ce;
    colourDiagnostics dynamic_u(.clk,.reset,.in_data,.in_mask,.in_mode,.in_overlay,
        .in_sop,.in_eop,.in_valid(in_valid && cr),.in_ready(dr),
        .out_data(dd),.out_sop(ds),.out_eop(de),.out_valid(dv),.out_ready(out_ready && cv),
        .display_red(),.display_blue(),.display_frame_id());
    roiCalibration calibration_u(.clk,.reset,.in_data,.in_mask,.in_mode,.in_calibration,.in_overlay,
        .in_sop,.in_eop,.in_valid(in_valid && dr),.in_ready(cr),
        .out_data(cd),.out_sop(cs),.out_eop(ce),.out_valid(cv),.out_ready(out_ready && dv),
        .out_calibration(calibration),.display_measurement(),.display_detected());
endmodule
