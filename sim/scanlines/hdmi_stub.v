// Stand-ins for the Gowin and HDMI parts of a scaler, for simulation: a pixel
// counter with the real module's timing (cx, cy count the frame, and
// the picture is the rgb input seen while cx = x + 1), and a pass-through
// output buffer.
//
// Mirrors src/hdmi2/hdmi.sv for the 720p mode: with std_timing the line is
// the standard 1650 clocks, otherwise NATIVE_FRAME_WIDTH (the console's own
// refresh rate). A floating (Z) std_timing - the pre-native baselines in
// sim/video_fx/build/, whose snes2hdmi has no such port - selects the old
// fixed 1650-clock line.
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
    assign frame_width = (std_timing === 1'b0) ? NATIVE_FRAME_WIDTH : 11'd1650;
    assign frame_height = 750;
    assign tmds = 3'b0;
    assign tmds_clock = 1'b0;
    always @(posedge clk_pixel) begin
        cx <= (cx == frame_width - 11'd1) ? 11'd0 : cx + 11'd1;
        if (cx == frame_width - 11'd1)
            cy <= (cy == 10'd749) ? 10'd0 : cy + 10'd1;
    end
endmodule

module ELVDS_OBUF (input I, output O, output OB);
    assign O = I;
    assign OB = ~I;
endmodule
