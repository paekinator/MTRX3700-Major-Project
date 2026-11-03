// Combinational colour segmentation for the measured camera profile.
// rgb is full-range unsigned RGB888; minimum values are HSV V floors in the
// same 0..255 units. colourMask is 0 = neither/ambiguous, 1 = red, 2 = blue.
// There is no clock or state: the caller binds this result to its pixel-valid
// cycle and changes the two configuration floors atomically at frame start.
// This gate does not claim illumination invariance. Hue/S reject the measured
// orange background while the separately calibrated V floors handle brightness.
module hsvColourGate #(
    // 250 preserves colour algorithm 1 replay. Algorithm 2 uses 260: actual
    // RGB565 blue-card edge pixels at H=251.4 and 259.2 were splitting a card.
    parameter int BLUE_HUE_UPPER=250
) (
    input  logic [23:0] rgb,
    input  logic [7:0] redMinimum,
    input  logic [7:0] blueMinimum,
    output logic [1:0] colourMask
);
    logic [7:0] red,green,blue,maximum,minimum,chroma;
    logic [8:0] twiceChroma;
    logic signed [8:0] redDifference,blueDifference;
    // Differences are -255..255. Multiplication by 60 gives -15300..15300;
    // the hue-bound products span -10200..2550. Signed 16 bits are sufficient
    // for every product/comparison without a divider or unsized int arithmetic.
    logic signed [15:0] chromaSigned,redNumerator,blueNumerator;
    logic signed [15:0] redLowerBound,blueLowerBound,blueUpperBound;
    logic saturated,redHit,blueHit;

    always_comb begin
        red=rgb[23:16];
        green=rgb[15:8];
        blue=rgb[7:0];
        maximum=red;
        if(green>maximum) maximum=green;
        if(blue>maximum) maximum=blue;
        minimum=red;
        if(green<minimum) minimum=green;
        if(blue<minimum) minimum=blue;
        chroma=maximum-minimum;
        twiceChroma={chroma,1'b0};
        saturated=(chroma!=8'd0)&&(twiceChroma>={1'b0,maximum});

        redDifference=$signed({1'b0,green})-$signed({1'b0,blue});
        blueDifference=$signed({1'b0,red})-$signed({1'b0,green});
        chromaSigned=$signed({8'd0,chroma});
        redNumerator=16'sd60*redDifference;
        blueNumerator=16'sd60*blueDifference;
        redLowerBound=-16'sd24*chromaSigned;
        blueLowerBound=-16'sd40*chromaSigned;
        blueUpperBound=16'(BLUE_HUE_UPPER-240)*chromaSigned;

        // With R as the unique maximum, wrapped hue -24..0 degrees is
        // exactly -24*chroma <= 60*(G-B) <= 0. Equal G/B is valid H = 0.
        redHit=saturated&&(maximum>=redMinimum)&&(red>green)&&(red>blue)&&
            (redNumerator>=redLowerBound)&&(redNumerator<=16'sd0);
        // B is the unique maximum. Compare relative to its 240-degree base,
        // avoiding a per-pixel divider. The profile is a compile-time version;
        // changing light does not silently select an undocumented algorithm.
        blueHit=saturated&&(maximum>=blueMinimum)&&(blue>red)&&(blue>green)&&
            (blueNumerator>=blueLowerBound)&&(blueNumerator<=blueUpperBound);
        colourMask=2'd0;
        if(redHit&&!blueHit) colourMask=2'd1;
        else if(blueHit&&!redHit) colourMask=2'd2;
    end
endmodule
