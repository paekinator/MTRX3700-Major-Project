// ECHO-7 team; AI-assisted by OpenAI Codex. Preserve real measurements even with safety disabled.
module dualSonar (
    input logic CLOCK_50,reset50,echo1,echo2,
    output logic trig1,trig2,
    output logic [11:0] sonar1_distance_mm,sonar2_distance_mm,
    output logic sonar1_valid,sonar2_valid,sonar1_update,sonar2_update
);
    wire clk_sonar,locked;
    sonar_pll pll_u(.refclk(CLOCK_50),.rst(1'b0),.outclk_0(clk_sonar),.locked(locked));
    logic [1:0] rs=2'b11;
    always_ff @(posedge clk_sonar) rs<={rs[0],reset50 || !locked};
    logic [22:0] pace=0;
    always_ff @(posedge clk_sonar)
        if(rs[1]) pace<=0;
        else pace<=(pace==4_390_399) ? 23'd0:pace+1'b1;
    wire start1=(pace<16),start2=(pace>=2_195_200 && pace<2_195_216);
    wire [11:0] d1,d2;
    wire v1,v2;
    sonar_range s1(.clk(clk_sonar),.rst(rs[1]),.start_measure(start1),.echo(echo1),.trig(trig1),.distance(d1),.valid(v1),.ready());
    sonar_range s2(.clk(clk_sonar),.rst(rs[1]),.start_measure(start2),.echo(echo2),.trig(trig2),.distance(d2),.valid(v2),.ready());
    sonarSampleCdc c1(.src_clk(clk_sonar),.src_reset(rs[1]),.src_valid(v1),.src_distance_mm(d1),
        .dst_clk(CLOCK_50),.dst_reset(reset50),.distance_mm(sonar1_distance_mm),.valid(sonar1_valid),.update(sonar1_update));
    sonarSampleCdc c2(.src_clk(clk_sonar),.src_reset(rs[1]),.src_valid(v2),.src_distance_mm(d2),
        .dst_clk(CLOCK_50),.dst_reset(reset50),.distance_mm(sonar2_distance_mm),.valid(sonar2_valid),.update(sonar2_update));
endmodule
