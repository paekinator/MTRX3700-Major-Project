/*
 *  camera_pkg.sv -- the pixel formats the camera code passes around.
 *
 *  The OV7670 is configured for RGB565 (ov7670_config.sv): two bytes per pixel, first byte
 *  {R[7:3], G[7:5]}, second byte {G[4:2], B[7:3]} (datasheet Figure 11). ov7670_capture.sv joins
 *  the two bytes into one 16-bit word, {first, second} = {R5, G6, B5}. Everything downstream
 *  (frame buffer, display, your Assignment 2 pipeline) wants either 8-bit RGB or 8-bit grey:
 *  these two functions are that conversion, and nothing else in the design knows about 565.
 */
package camera_pkg;

    // 16-bit RGB565 -> 24-bit RGB888. The low bits are filled by repeating the top bits, so that
    // 0x1F (all ones in a 5-bit channel) becomes 0xFF, not 0xF8: full white stays full white.
    function automatic logic [23:0] rgb565_to_rgb888(input logic [15:0] p);
        return {p[15:11], p[15:13],    // R: 5 bits + the top 3 again
                p[10:5],  p[10:9],     // G: 6 bits + the top 2 again
                p[4:0],   p[4:2]};     // B: 5 bits + the top 3 again
    endfunction

    // 16-bit RGB565 -> 8-bit grey, as (R + 2G + B) / 4 on the 8-bit channels: the weighting the
    // University Program RGB Resampler uses, and close enough to the 0.30/0.59/0.11 of BT.601
    // for edge detection. The Assignment 2 modules take this grey value where they took the ROM's.
    function automatic logic [7:0] rgb565_to_grey(input logic [15:0] p);
        logic [23:0] c;
        logic [9:0]  sum;
        c   = rgb565_to_rgb888(p);
        sum = {2'b00, c[23:16]} + {1'b0, c[15:8], 1'b0} + {2'b00, c[7:0]};   // R + 2G + B, 10 bits
        return sum[9:2];
    endfunction

endpackage
