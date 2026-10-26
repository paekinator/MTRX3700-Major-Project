`timescale 1ns/1ps
// vga_sink_sim.sv -- simulation stand-in for the Platform Designer system vga_sink.qsys:
// the VGA Controller + monitor, as the Lesson 3 monitor model. Frame size and how many frames
// become .ppm files come from defines (-DVGA_H_RES=160 -DVGA_V_RES=120 -DVGA_PPM_EVERY=1 -DVGA_MAX_PPM=8).
`ifndef VGA_H_RES
`define VGA_H_RES 640
`define VGA_V_RES 480
`endif
`ifndef VGA_PPM_EVERY
`define VGA_PPM_EVERY 1
`define VGA_MAX_PPM 8
`endif
module vga_sink #(parameter int H_RES = `VGA_H_RES, V_RES = `VGA_V_RES) (
    input  logic        clk_clk, reset_reset_n,
    input  logic [29:0] video_in_data, input logic video_in_startofpacket, video_in_endofpacket, video_in_valid,
    output logic        video_in_ready,
    output logic        vga_CLK, vga_HS, vga_VS, vga_BLANK, vga_SYNC, output logic [7:0] vga_R, vga_G, vga_B
);
    int frames_done, errors, x_pos, y_pos; logic accept, discard;
    vga_monitor_model #(.H_RES(H_RES), .V_RES(V_RES), .H_BLANK(H_RES/4), .V_BLANK(V_RES/10), .ASCII_ART(0), .PPM_PREFIX("frame"), .MAX_PPM_FILES(`VGA_MAX_PPM), .PPM_EVERY(`VGA_PPM_EVERY), .VERBOSE(0)) u_mon (
        .clk(clk_clk), .reset(~reset_reset_n), .data(video_in_data), .startofpacket(video_in_startofpacket), .endofpacket(video_in_endofpacket),
        .valid(video_in_valid), .ready(video_in_ready), .frames_done, .errors, .x_pos, .y_pos, .accept, .discard);
    assign vga_CLK = clk_clk; assign {vga_HS, vga_VS, vga_BLANK, vga_SYNC} = '0; assign {vga_R, vga_G, vga_B} = '0;
endmodule
