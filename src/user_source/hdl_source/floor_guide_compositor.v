// 【未使用】旧版 640×480 合成器，已由 guide_scene_compositor.v 取代；顶层仍 include 但未例化。
// 仍保留在工程文件列表中，综合时不会进入设计层次；阅读当前设计可跳过本文件。
`timescale 1ns/1ps

// 640x480 smart floor-guide compositor.
//
// The upper region keeps the current TF-card activity image and adds a light
// header/status treatment.  The lower region is generated in real time and
// contains three room cards.  Activity-image and floor changes use a simple
// left-to-right reveal so that no second full-frame SDRAM read is required.
module floor_guide_compositor #(
    parameter integer FRAME_WIDTH  = 640,
    parameter integer FRAME_HEIGHT = 480,
    parameter integer TOP_HEIGHT   = 240,
    parameter integer ROOM_Y       = 300,
    parameter integer ROOM_WIDTH   = 160,
    parameter integer ROOM_HEIGHT  = 120,
    parameter integer ROOM0_X      = 30,
    parameter integer ROOM1_X      = 240,
    parameter integer ROOM2_X      = 450,
    parameter integer DIGIT_SCALE  = 2,
    parameter integer TRANSITION_STEP_X = 64,
    parameter integer TRANSITION_STEP_PANEL = 64,
    parameter integer PANEL_USE_IMAGE_BACKGROUND = 0,
    parameter [23:0] PANEL_COLOR       = 24'h12_18_2C,
    parameter [23:0] PANEL_ALT_COLOR   = 24'h0E_15_25,
    parameter [23:0] TRANSITION_COLOR  = 24'h08_0D_18,
    parameter [23:0] ROOM_BODY_COLOR   = 24'h1A_25_38,
    parameter [23:0] FREE_COLOR        = 24'h1E_66_F5,
    parameter [23:0] OCC_COLOR         = 24'hE0_32_2B,
    parameter [23:0] SELECT_COLOR      = 24'hFF_D2_00,
    parameter [23:0] TEXT_COLOR        = 24'hFF_FF_FF,
    parameter [23:0] BORDER_COLOR      = 24'hB8_C2_D1,
    parameter [23:0] HEADER_COLOR      = 24'h0B_13_24,
    parameter integer HEADER_HEIGHT   = 0
)(
    input  wire        I_clk,
    input  wire        I_rst,
    input  wire [23:0] I_rgb,
    input  wire        I_hs,
    input  wire        I_vs,
    input  wire        I_de,
    input  wire [1:0]  I_floor_idx,
    input  wire [1:0]  I_selected_room_idx,
    input  wire [8:0]  I_room_occupied,
    input  wire        I_auto_play_en,
    input  wire [1:0]  I_activity_idx,
    output reg  [23:0] O_rgb,
    output reg         O_hs,
    output reg         O_vs,
    output reg         O_de
);

localparam integer DIGIT_BASE_WIDTH  = 12;
localparam integer DIGIT_BASE_HEIGHT = 20;
localparam integer DIGIT_WIDTH       = DIGIT_BASE_WIDTH * DIGIT_SCALE;
localparam integer DIGIT_HEIGHT      = DIGIT_BASE_HEIGHT * DIGIT_SCALE;
localparam integer DIGIT_GAP         = 2 * DIGIT_SCALE;
localparam integer LABEL_WIDTH       = (3 * DIGIT_WIDTH) + (2 * DIGIT_GAP);
localparam integer LABEL_Y           = ROOM_Y + ((ROOM_HEIGHT - DIGIT_HEIGHT) / 2);

reg        vs_d;
reg        de_d;
reg [10:0] pixel_x;
reg [9:0]  pixel_y;

reg [1:0] floor_idx_frame;
reg [1:0] selected_room_frame;
reg [8:0] room_occupied_frame;
reg       auto_play_frame;
reg [1:0] activity_idx_frame;
reg [10:0] top_reveal_x;
reg [10:0] panel_reveal_x;

reg [23:0] composed_rgb;
reg [1:0]  active_room;
reg        in_room;
reg        room_occupied_now;
reg        border_pixel;
reg        label_pixel;
integer    room_x;
integer    local_x;
integer    local_y;
integer    label_x;

wire frame_edge;
wire line_end;

assign frame_edge = vs_d && !I_vs;
assign line_end   = de_d && !I_de;

function occupied_lookup;
    input [1:0] floor_index;
    input [1:0] room_index;
    input [8:0] occupied_bits;
    begin
        case ({floor_index, room_index})
            4'b00_00: occupied_lookup = occupied_bits[0];
            4'b00_01: occupied_lookup = occupied_bits[1];
            4'b00_10: occupied_lookup = occupied_bits[2];
            4'b01_00: occupied_lookup = occupied_bits[3];
            4'b01_01: occupied_lookup = occupied_bits[4];
            4'b01_10: occupied_lookup = occupied_bits[5];
            4'b10_00: occupied_lookup = occupied_bits[6];
            4'b10_01: occupied_lookup = occupied_bits[7];
            4'b10_10: occupied_lookup = occupied_bits[8];
            default:  occupied_lookup = 1'b0;
        endcase
    end
endfunction

function [6:0] digit_segments;
    input [3:0] digit;
    begin
        // Bit order: a, b, c, d, e, f, g.
        case (digit)
            4'd0: digit_segments = 7'b1111110;
            4'd1: digit_segments = 7'b0110000;
            4'd2: digit_segments = 7'b1101101;
            4'd3: digit_segments = 7'b1111001;
            4'd4: digit_segments = 7'b0110011;
            4'd5: digit_segments = 7'b1011011;
            4'd6: digit_segments = 7'b1011111;
            4'd7: digit_segments = 7'b1110000;
            4'd8: digit_segments = 7'b1111111;
            4'd9: digit_segments = 7'b1111011;
            default: digit_segments = 7'b0000000;
        endcase
    end
endfunction

function digit_pixel;
    input [3:0] digit;
    input integer px;
    input integer py;
    input integer origin_x;
    input integer origin_y;
    integer dx;
    integer dy;
    reg [6:0] seg;
    begin
        digit_pixel = 1'b0;
        if ((px >= origin_x) && (px < origin_x + DIGIT_WIDTH) &&
            (py >= origin_y) && (py < origin_y + DIGIT_HEIGHT)) begin
            dx  = (px - origin_x) / DIGIT_SCALE;
            dy  = (py - origin_y) / DIGIT_SCALE;
            seg = digit_segments(digit);

            if (seg[6] && (dy < 2) && (dx >= 2) && (dx < 10))
                digit_pixel = 1'b1;
            if (seg[5] && (dx >= 10) && (dy >= 2) && (dy < 9))
                digit_pixel = 1'b1;
            if (seg[4] && (dx >= 10) && (dy >= 11) && (dy < 18))
                digit_pixel = 1'b1;
            if (seg[3] && (dy >= 18) && (dx >= 2) && (dx < 10))
                digit_pixel = 1'b1;
            if (seg[2] && (dx < 2) && (dy >= 11) && (dy < 18))
                digit_pixel = 1'b1;
            if (seg[1] && (dx < 2) && (dy >= 2) && (dy < 9))
                digit_pixel = 1'b1;
            if (seg[0] && (dy >= 9) && (dy < 11) &&
                (dx >= 2) && (dx < 10))
                digit_pixel = 1'b1;
        end
    end
endfunction

always @* begin
    composed_rgb       = I_rgb;
    active_room        = 2'd0;
    in_room            = 1'b0;
    room_occupied_now  = 1'b0;
    border_pixel       = 1'b0;
    label_pixel        = 1'b0;
    room_x             = 0;
    local_x            = 0;
    local_y            = 0;
    label_x            = 0;

    if (I_de) begin
        if (pixel_y < TOP_HEIGHT) begin
            // Optional header tint; disabled for unobstructed activity images.
            composed_rgb = I_rgb;
            if (pixel_y < HEADER_HEIGHT) begin
                // Scale each color channel independently; a packed shift
                // leaks R/G low bits into the adjacent channel's high bits.
                composed_rgb[23:16] = (I_rgb[23:16] >> 2) + HEADER_COLOR[23:16];
                composed_rgb[15:8]  = (I_rgb[15:8]  >> 2) + HEADER_COLOR[15:8];
                composed_rgb[7:0]   = (I_rgb[7:0]   >> 2) + HEADER_COLOR[7:0];
            end

            // A new activity frame is revealed from left to right.
            if (pixel_x >= top_reveal_x)
                composed_rgb = TRANSITION_COLOR;
        end else begin
            if (PANEL_USE_IMAGE_BACKGROUND != 0)
                composed_rgb = I_rgb;
            else if (pixel_y[5])
                composed_rgb = PANEL_COLOR;
            else
                composed_rgb = PANEL_ALT_COLOR;

            // A floor change reveals the new lower panel from left to right.
            if (pixel_x < panel_reveal_x) begin
                if ((pixel_y >= TOP_HEIGHT) && (pixel_y < TOP_HEIGHT + 3))
                    composed_rgb = BORDER_COLOR;

                // Lower header: large floor number and compact activity
                // playback indicator.
                if ((pixel_y >= TOP_HEIGHT + 8) &&
                    digit_pixel({2'b00, floor_idx_frame} + 4'd1,
                                pixel_x, pixel_y, 18, TOP_HEIGHT + 8))
                    composed_rgb = TEXT_COLOR;

                if ((pixel_x >= FRAME_WIDTH - 34) &&
                    (pixel_x < FRAME_WIDTH - 14) &&
                    (pixel_y >= TOP_HEIGHT + 16) &&
                    (pixel_y < TOP_HEIGHT + 36))
                    composed_rgb = auto_play_frame ?
                                   24'h36_D3_78 : 24'h5B_64_72;

                if ((pixel_y >= ROOM_Y) &&
                    (pixel_y < ROOM_Y + ROOM_HEIGHT)) begin
                    if ((pixel_x >= ROOM0_X) &&
                        (pixel_x < ROOM0_X + ROOM_WIDTH)) begin
                        active_room = 2'd0;
                        room_x      = ROOM0_X;
                        in_room     = 1'b1;
                    end else if ((pixel_x >= ROOM1_X) &&
                                 (pixel_x < ROOM1_X + ROOM_WIDTH)) begin
                        active_room = 2'd1;
                        room_x      = ROOM1_X;
                        in_room     = 1'b1;
                    end else if ((pixel_x >= ROOM2_X) &&
                                 (pixel_x < ROOM2_X + ROOM_WIDTH)) begin
                        active_room = 2'd2;
                        room_x      = ROOM2_X;
                        in_room     = 1'b1;
                    end
                end

                if (in_room) begin
                    local_x = pixel_x - room_x;
                    local_y = pixel_y - ROOM_Y;
                    room_occupied_now = occupied_lookup(floor_idx_frame,
                                                         active_room,
                                                         room_occupied_frame);

                    if (active_room == selected_room_frame)
                        border_pixel = (local_x < 4) ||
                                       (local_x >= ROOM_WIDTH - 4) ||
                                       (local_y < 4) ||
                                       (local_y >= ROOM_HEIGHT - 4);
                    else
                        border_pixel = (local_x < 2) ||
                                       (local_x >= ROOM_WIDTH - 2) ||
                                       (local_y < 2) ||
                                       (local_y >= ROOM_HEIGHT - 2);

                    label_x = room_x + ((ROOM_WIDTH - LABEL_WIDTH) / 2);
                    label_pixel =
                        digit_pixel({2'b00, floor_idx_frame} + 4'd1,
                                    pixel_x, pixel_y, label_x, LABEL_Y) ||
                        digit_pixel(4'd0, pixel_x, pixel_y,
                                    label_x + DIGIT_WIDTH + DIGIT_GAP,
                                    LABEL_Y) ||
                        digit_pixel({2'b00, active_room} + 4'd1,
                                    pixel_x, pixel_y,
                                    label_x + 2 * (DIGIT_WIDTH + DIGIT_GAP),
                                    LABEL_Y);

                    // Dark card body, colored status strip/pill, then the
                    // high-contrast room label and selected outline.
                    composed_rgb = ROOM_BODY_COLOR;
                    if (local_y < 12)
                        composed_rgb = room_occupied_now ? OCC_COLOR :
                                       FREE_COLOR;
                    if ((local_x >= 14) && (local_x < 48) &&
                        (local_y >= 20) && (local_y < 40))
                        composed_rgb = room_occupied_now ? OCC_COLOR :
                                       FREE_COLOR;
                    if (label_pixel)
                        composed_rgb = TEXT_COLOR;
                    if (border_pixel)
                        composed_rgb = (active_room == selected_room_frame) ?
                                       SELECT_COLOR : BORDER_COLOR;
                end
            end else begin
                composed_rgb = TRANSITION_COLOR;
            end
        end
    end
end

always @(posedge I_clk or posedge I_rst) begin
    if (I_rst) begin
        vs_d                <= 1'b0;
        de_d                <= 1'b0;
        pixel_x             <= 11'd0;
        pixel_y             <= 10'd0;
        floor_idx_frame     <= 2'd0;
        selected_room_frame <= 2'd0;
        room_occupied_frame <= 9'd0;
        auto_play_frame     <= 1'b0;
        activity_idx_frame  <= 2'd0;
        top_reveal_x        <= FRAME_WIDTH;
        panel_reveal_x      <= FRAME_WIDTH;
        O_rgb               <= 24'd0;
        O_hs                <= 1'b0;
        O_vs                <= 1'b0;
        O_de                <= 1'b0;
    end else begin
        vs_d  <= I_vs;
        de_d  <= I_de;
        O_rgb <= composed_rgb;
        O_hs  <= I_hs;
        O_vs  <= I_vs;
        O_de  <= I_de;

        if (frame_edge) begin
            if (I_activity_idx != activity_idx_frame) begin
                activity_idx_frame <= I_activity_idx;
                top_reveal_x       <= 11'd0;
            end else if (top_reveal_x < FRAME_WIDTH) begin
                if (top_reveal_x + TRANSITION_STEP_X >= FRAME_WIDTH)
                    top_reveal_x <= FRAME_WIDTH;
                else
                    top_reveal_x <= top_reveal_x + TRANSITION_STEP_X;
            end

            if (I_floor_idx != floor_idx_frame) begin
                floor_idx_frame <= I_floor_idx;
                panel_reveal_x   <= 11'd0;
            end else if (panel_reveal_x < FRAME_WIDTH) begin
                if (panel_reveal_x + TRANSITION_STEP_PANEL >= FRAME_WIDTH)
                    panel_reveal_x <= FRAME_WIDTH;
                else
                    panel_reveal_x <= panel_reveal_x + TRANSITION_STEP_PANEL;
            end

            selected_room_frame <= I_selected_room_idx;
            room_occupied_frame <= I_room_occupied;
            auto_play_frame     <= I_auto_play_en;
            pixel_x             <= 11'd0;
            pixel_y             <= 10'd0;
        end else if (!I_de) begin
            pixel_x <= 11'd0;
            if (line_end && (pixel_y < FRAME_HEIGHT - 1))
                pixel_y <= pixel_y + 1'b1;
            else if (line_end)
                pixel_y <= 10'd0;
        end else if (pixel_x < FRAME_WIDTH - 1) begin
            pixel_x <= pixel_x + 1'b1;
        end
    end
end

endmodule
