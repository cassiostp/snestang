// Stand-ins for the Gowin and HDMI parts of a scaler, for simulation: a pixel
// counter with the real module's timing (cx, cy count the frame, and
// the picture is the rgb input seen while cx = x + 1), and a pass-through
// output buffer.
//
// Mirrors src/hdmi2/hdmi.sv for the 720p mode (VIC 4) and 480p120 (VIC 48/49).
// std_timing 0 uses NATIVE_FRAME_WIDTH; 1 uses 1650 (720p) or 858 (480p).
// A floating (Z) std_timing selects the standard line. Height is 750 or 525.
module hdmi #(
    parameter VIDEO_ID_CODE = 4,
    parameter DVI_OUTPUT = 0,
    parameter VIDEO_REFRESH_RATE = 60.0,
    parameter IT_CONTENT = 1,
    parameter AUDIO_RATE = 48000,
    parameter AUDIO_BIT_WIDTH = 16,
    parameter NATIVE_FRAME_WIDTH = 1647,
    parameter START_X = 0,
    parameter START_Y = 0
) (
    input         clk_pixel_x5,
    input         clk_pixel,
    input         clk_audio,
    input  [23:0] rgb,
    input         reset,
    input         std_timing,
    input  [15:0] audio_sample_word [1:0],
    output [2:0]  tmds,
    output        tmds_clock,
    output reg [10:0] cx = START_X,
    output reg [9:0]  cy = START_Y,
    output [10:0] frame_width,
    output [9:0]  frame_height
);
    wire v480 = (VIDEO_ID_CODE == 48 || VIDEO_ID_CODE == 49);
    wire [10:0] std_w = v480 ? 11'd858 : 11'd1650;
    wire [9:0]  ht = v480 ? 10'd525 : 10'd750;
    assign frame_width = (std_timing === 1'b0) ? NATIVE_FRAME_WIDTH : std_w;
    assign frame_height = ht;
    assign tmds = 3'b0;
    assign tmds_clock = 1'b0;
    always @(posedge clk_pixel) begin
        cx <= (cx == frame_width - 11'd1) ? 11'd0 : cx + 11'd1;
        if (cx == frame_width - 11'd1)
            cy <= (cy == ht - 10'd1) ? 10'd0 : cy + 10'd1;
    end
endmodule

module ELVDS_OBUF (input I, output O, output OB);
    assign O = I;
    assign OB = ~I;
endmodule
