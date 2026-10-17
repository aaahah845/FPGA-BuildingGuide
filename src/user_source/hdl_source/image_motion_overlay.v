// 【未使用】早期动画叠加层，当前未例化。
// 仍保留在工程文件列表中，综合时不会进入设计层次；阅读当前设计可跳过本文件。
`timescale 1ns/1ps

// 图片练习效果：在已经对齐的视频像素流上叠加一个按帧移动的方框。
// 该模块不改变视频时序，只在 I_de 有效的像素区替换颜色。
module image_motion_overlay #(
    parameter ENABLE_EFFECT = 1'b1,
    parameter integer FRAME_WIDTH  = 640,
    parameter integer FRAME_HEIGHT = 480,
    parameter integer BOX_SIZE     = 64,
    parameter integer STEP_X       = 4,
    parameter integer STEP_Y       = 2,
    parameter [23:0] BOX_COLOR     = 24'h00_FF_40
)(
    input  wire        I_clk,
    input  wire        I_rst,
    input  wire [23:0] I_rgb,
    input  wire        I_hs,
    input  wire        I_vs,
    input  wire        I_de,
    output wire [23:0] O_rgb,
    output wire        O_hs,
    output wire        O_vs,
    output wire        O_de
);

localparam integer BOX_X_MAX = FRAME_WIDTH  - BOX_SIZE;
localparam integer BOX_Y_MAX = FRAME_HEIGHT - BOX_SIZE;

reg        vs_d;
reg        de_d;
reg [10:0] pixel_x;
reg [9:0]  pixel_y;
reg [10:0] box_x;
reg [9:0]  box_y;
reg        box_x_back;
reg        box_y_back;

wire frame_edge;
wire line_end;
wire inside_box;

// 当前 640x480 时序的 VS 有效电平为低，帧边界取进入低电平的一次边沿，
// 避免同一帧在 VS 的两个边沿各更新一次动画位置。
assign frame_edge = vs_d && !I_vs;
assign line_end = de_d && !I_de;

assign inside_box = ENABLE_EFFECT && I_de &&
                    (pixel_x >= box_x) &&
                    (pixel_x < (box_x + BOX_SIZE)) &&
                    (pixel_y >= box_y) &&
                    (pixel_y < (box_y + BOX_SIZE));

assign O_rgb = inside_box ? BOX_COLOR : I_rgb;
assign O_hs  = I_hs;
assign O_vs  = I_vs;
assign O_de  = I_de;

always @(posedge I_clk or posedge I_rst) begin
    if (I_rst) begin
        vs_d      <= 1'b0;
        de_d      <= 1'b0;
        pixel_x   <= 11'd0;
        pixel_y   <= 10'd0;
        box_x     <= 11'd0;
        box_y     <= 10'd0;
        box_x_back <= 1'b0;
        box_y_back <= 1'b0;
    end else begin
        vs_d <= I_vs;
        de_d <= I_de;

        // 进入新帧时更新动画位置。只使用同步到视频时钟域的 VS。
        if (frame_edge) begin
            if (!box_x_back) begin
                if (box_x + STEP_X >= BOX_X_MAX) begin
                    box_x      <= BOX_X_MAX;
                    box_x_back <= 1'b1;
                end else begin
                    box_x <= box_x + STEP_X;
                end
            end else if (box_x <= STEP_X) begin
                box_x      <= 11'd0;
                box_x_back <= 1'b0;
            end else begin
                box_x <= box_x - STEP_X;
            end

            if (!box_y_back) begin
                if (box_y + STEP_Y >= BOX_Y_MAX) begin
                    box_y      <= BOX_Y_MAX;
                    box_y_back <= 1'b1;
                end else begin
                    box_y <= box_y + STEP_Y;
                end
            end else if (box_y <= STEP_Y) begin
                box_y      <= 10'd0;
                box_y_back <= 1'b0;
            end else begin
                box_y <= box_y - STEP_Y;
            end
        end

        // 帧边界将坐标归零；行结束时递增 y，避免首个像素进入下一行坐标。
        if (frame_edge) begin
            pixel_x <= 11'd0;
            pixel_y <= 10'd0;
        end else if (!I_de) begin
            pixel_x <= 11'd0;
            if (line_end && (pixel_y < FRAME_HEIGHT - 1)) begin
                pixel_y <= pixel_y + 1'b1;
            end else if (line_end) begin
                pixel_y <= 10'd0;
            end
        end else if (pixel_x < FRAME_WIDTH - 1) begin
            pixel_x <= pixel_x + 1'b1;
        end
    end
end

endmodule
