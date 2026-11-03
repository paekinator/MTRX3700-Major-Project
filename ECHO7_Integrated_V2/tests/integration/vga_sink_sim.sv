`timescale 1ns/1ps
// TEST ONLY: Qsys VGA sink handshake model, not a timing/analogue VGA validation.
// The actual camera, perceptionCore, tracker, overlay and Member C RTL are compiled.
module vga_sink(input wire clk_clk,reset_reset_n,
 input wire [29:0] video_in_data,input wire video_in_startofpacket,video_in_endofpacket,video_in_valid,
 output wire video_in_ready,output wire vga_CLK,vga_HS,vga_VS,vga_BLANK,vga_SYNC,
 output wire [7:0] vga_R,vga_G,vga_B);
 assign video_in_ready=reset_reset_n;
 assign vga_CLK=clk_clk;
 assign vga_HS=1'b1;assign vga_VS=1'b1;assign vga_BLANK=reset_reset_n;assign vga_SYNC=1'b0;
 assign vga_R=video_in_data[29:22];assign vga_G=video_in_data[19:12];assign vga_B=video_in_data[9:2];
endmodule
