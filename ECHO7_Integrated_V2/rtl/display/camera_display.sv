/*
 *  camera_display.sv -- show the frame buffer on the monitor: an Avalon-ST video source.
 *
 *  Exactly the source you wrote for Lesson 3 Task 3.2 (vga_face) and used in the Assignment 2
 *  display: a raster position that advances on every valid & ready handshake, startofpacket on
 *  pixel (0,0), endofpacket on the last, 30-bit RGB out. The VGA Controller (vga_sink.qsys, the
 *  University Program core) does the sync signals and the DAC.
 *
 *  The stored picture is 320x240 and the screen is 640x480, so each stored pixel is shown as a
 *  2x2 block: the read address is (x/2, y/2). The frame buffer's read port is registered (one clock
 *  of latency), so the address is formed from the NEXT position and presented one handshake ahead:
 *  by the time the raster reaches a pixel, its data is already on rd_pixel. While the controller is
 *  not ready (its blanking: 160 clocks a line, 45 lines a frame, and any other stall) the address
 *  must point at the CURRENT position, or the port fetches the pixel after the one on offer and the
 *  controller accepts the wrong one when it resumes.
 *
 *  And one more rule for a single frame buffer: the camera keeps writing while the display is
 *  stalled, and it can overwrite the very word on offer. The read port is live, so the offer would
 *  change under the controller. So the first stalled cycle copies the offer into a register, and
 *  the source offers that copy until the handshake (Avalon-ST: data holds until it is taken).
 */
module camera_display #(
    parameter int H_RES = 640,
    parameter int V_RES = 480,
    parameter int W     = 320,         // stored picture
    parameter int H     = 240,
    parameter bit ROTATE_CCW_90 = 0 // ECHO-7 AI-assisted: aspect-preserving portrait view.
) (
    input  logic                 clk,            // VGA pixel clock (25 MHz)
    input  logic                 reset,
    input  logic                 hold_enable,    // 1: freeze the offered pixel during a stall (Avalon-ST); 0: live read port (diagnostic)
    // frame buffer read port
    output logic [$clog2(W)-1:0] rd_x,
    output logic [$clog2(H)-1:0] rd_y,
    input  logic [15:0]          rd_pixel,       // RGB565, one clock after rd_x/rd_y
    // Avalon-ST source into the VGA Controller
    output logic [29:0]          data,
    output logic                 startofpacket,
    output logic                 endofpacket,
    output logic                 valid,
    input  logic                 ready
);
    import camera_pkg::*;

    logic [$clog2(H_RES)-1:0] x, x_next;
    logic [$clog2(V_RES)-1:0] y, y_next;
    logic last_pixel;
    assign last_pixel = (x == H_RES - 1) && (y == V_RES - 1);

    always_comb begin
        if (reset || last_pixel)  begin x_next = '0;         y_next = '0;         end
        else if (x == H_RES - 1)  begin x_next = '0;         y_next = y + 1'b1;   end
        else                      begin x_next = x + 1'b1;   y_next = y;          end
    end
    always_ff @(posedge clk)
        if (reset || (valid && ready)) begin x <= x_next; y <= y_next; end

    // The read address: one position AHEAD of the raster on a handshake, so that the registered read
    // port has the next pixel ready by the next clock; the CURRENT position while stalled, so that
    // the pixel on offer stays on offer. (Let the address run ahead during a stall and the port
    // returns the next pixel while the controller has not taken this one: it then accepts the
    // wrong pixel after every stall, one per line at the least. Avalon-ST: data holds until the
    // handshake.) A stored pixel covers a 2x2 block of the screen, hence the >> 1.
    // For unsigned coordinates 0..511, floor(2*n/3) equals floor(683*n/1024).
    // The 9x10-bit product is exact in 19 bits; this removes signed 32-bit /3
    // logic while preserving every visible pixel, including scale boundaries.
    function automatic logic [8:0] twoThirds(input logic [8:0] coordinate);
        logic [18:0] product;
        begin
            product = coordinate * 19'd683;
            twoThirds = product[18:10];
        end
    endfunction

    logic handshake;
    assign handshake = valid && ready;
    logic image_pixel;
    generate if (ROTATE_CCW_90) begin : rotated
        // 320x240 -> 240x320 -> 360x480. Nearest-neighbour scale 3/2.
        // The displayed portrait occupies x=140..499, with 140-pixel side bars.
        wire [$clog2(H_RES)-1:0] fetch_x = handshake ? x_next : x;
        wire [$clog2(V_RES)-1:0] fetch_y = handshake ? y_next : y;
        always_comb begin
            rd_x='0; rd_y='0;
            if(fetch_x>=140 && fetch_x<500) begin
                rd_x=9'd319-twoThirds(fetch_y);
                rd_y=8'(twoThirds(9'(fetch_x-10'd140)));
            end
        end
        assign image_pixel=(x>=140 && x<500);
`ifndef SYNTHESIS
        initial assert(H_RES==640 && V_RES==480 && W==320 && H==240)
            else $fatal(1,"CCW rotation requires 320x240 storage and 640x480 output");
`endif
    end else begin : unrotated
        assign rd_x = ($clog2(W))'((handshake ? x_next : x) >> 1);
        assign rd_y = ($clog2(H))'((handshake ? y_next : y) >> 1);
        assign image_pixel=1'b1;
    end endgenerate

    logic [23:0] rgb;
    logic [29:0] live, held;
    logic        stalled_q;
    assign rgb   = rgb565_to_rgb888(rd_pixel);
    assign live  = image_pixel ? {rgb[23:16], 2'b00, rgb[15:8], 2'b00, rgb[7:0], 2'b00} : 30'd0;
    // Avalon-ST: what is on offer must not change until it is taken. The address holds during a stall, but
    // with a single frame buffer the camera can overwrite that very word meanwhile, and the RAM's read port
    // is live. So the first stalled cycle freezes the offer and the handshake is made with the frozen value.
    always_ff @(posedge clk) begin
        stalled_q <= valid && !ready && !reset;
        if (valid && !ready && !stalled_q) held <= live;
    end
    assign data  = (stalled_q && hold_enable) ? held : live;
    assign valid = ~reset;
    assign startofpacket = (x == 0) && (y == 0);
    assign endofpacket   = last_pixel;
endmodule
