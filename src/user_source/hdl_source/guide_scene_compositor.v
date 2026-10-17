`include "scene_motion.v"
`include "room_status_ticker.v"
`include "room_list_fade.v"
`include "room_list_scroll.v"
`include "site_point_memory.v"
`include "room_notes_font.v"
`timescale 1ns / 1ps

`include "guide_font_rom.v"
`include "guide_large_font.v"

// ============================================================================
// guide_scene_compositor：图文合成器，运行在 video_clk（40 MHz）。
// 输入 I_rgb/HS/VS/DE 来自读 FIFO 对齐后的像素流，场景参数来自调度器。
// 模块按区域叠加列表、地图标记、文字和详情面板，输出继续交给后置叠加。
//
// 当前 RUNTIME_CONFIG=1 路径有六级像素流水：
// v0：把 scan_x/y 变换到页面坐标和面板局部坐标，保存输入像素及同步信号。
// pre：保存卡片、图片、观察点及面板命中，形成 pixel_x/y 和区域局部坐标。
// d：组合判断区域优先级，寄存底色、文字颜色、字形请求和字形起点。
// q2：同步字模给出笔画行，字内列号、文字使能、底色及 HS/VS/DE 同步延迟。
// q3：按列取笔画，选择文字色或底色，寄存供混合的颜色和权重。
// out：按淡化/压暗或大图 alpha 输出最终 RGB，HS/VS/DE 随像素一同输出。
//
// 楼层、选择、占用和进度等帧级状态在 frame_edge 锁存。观察点坐标每点
// 分四拍计算并缓存，像素阶段只查区域。名称、说明和动态字模在启动时载入 RAM。
// scan_x/y 是物理扫描坐标，view_x/content_y 是页面和面板变换后的坐标；
// 各区域从它们求局部位置，字形请求最终统一进入对应尺寸的字模存储器。
//
// 详情大图覆盖屏幕中央 640×480。过渡时输入字的两个 RGB565 分量分别表示
// 原界面底图与原生照片；先完成底图的文字/面板合成，再在末级混合照片。
// I_photo_view_alpha=0 保留详情，=16 显示完整照片；覆盖区外持续显示原界面。
// ============================================================================
// region 01 接口
module guide_scene_compositor #(
    parameter integer RUNTIME_CONFIG = 0,
    parameter integer PANEL_STEP = 20,
    parameter integer PHOTO_STEP = 32,
    parameter integer SCROLL_FRAMES = 3
) (
    input wire I_clk, I_rst,
    input [12:0] I_scene_motion,
    input cfg_we,
    input [12:0] cfg_addr,
    input [7:0] cfg_data,
    input font_write_clk, font_write_en,
    input [12:0] font_write_addr,
    input [17:0] font_write_data,
    input I_loading, I_load_error,
    input I_map_loading,
    // 像素接口；输入与 I_hs/I_vs/I_de 同步，输出延迟由当前流水线统一决定。
    input wire [23:0] I_rgb,
    input wire I_hs, I_vs, I_de,
    input wire [1:0] I_floor_idx,
    input wire I_selection_visible,
    input wire I_floor_selecting,
    input wire [1:0] I_floor_cursor, I_requested_floor,
    input wire [3:0] I_selected_room_idx,
    input wire [29:0] I_room_occupied,
    input wire [15:0] I_elapsed_bcd,
    input wire I_auto_play_en, I_detail_requested, I_view_settled,
    input wire [12:0] I_carousel_progress,
    input wire [1:0] I_period_select,
    input wire [7:0] I_panel_height,
    // 大图覆盖参数；I_photo_rgb565 是过渡帧 FIFO 字的低 16 位照片样本。
    input wire I_photo_full,
    input wire [4:0] I_photo_view_alpha,
    input wire [15:0] I_photo_rgb565,
    input [36:0] I_map_view,
    input [13:0] I_map_scale,
    input [10:0] I_map_width,
    input [9:0] I_map_height,
    input wire I_map_mode, I_map_zoom, I_map_pan,
    input wire [8:0] I_map_x,
    input wire [7:0] I_map_y,
    output wire O_panel_active,
    output reg [23:0] O_rgb,
    output reg O_hs, O_vs, O_de
);

    // endregion

    // region 02 扫描坐标与 v0 坐标变换
    reg vs_d, de_d;

    reg [9:0] pixel_x, pixel_y;
    reg [9:0] scan_x, scan_y;
    wire [9:0] raw_view_x, raw_view_y;
    wire raw_view_valid;
    scene_motion_xy motion_xy (
        .motion(I_scene_motion),
        .x(scan_x),
        .y(scan_y),
        .vx(raw_view_x),
        .vy(raw_view_y),
        .valid(raw_view_valid),
        .blank_end(),
        .horizontal_shift()
    );
    wire [8:0] panel_remaining = 9'd210 - {1'b0, I_panel_height};
    wire [9:0] panel_drop = {panel_remaining, 1'b0} + (panel_remaining >> 1);
    wire raw_panel_here = I_panel_height != 0 && raw_view_x >= 32 && raw_view_x < 784 &&
        raw_view_y >= 72 + panel_drop && raw_view_y < 528 + panel_drop && scan_y < 568;
    wire [9:0] raw_content_y = raw_panel_here ? raw_view_y - panel_drop : raw_view_y;
    reg [9:0] view_x, content_y, physical_y_v0;
    reg view_valid, panel_here;
    wire raw_photo_hit = scan_x >= 80 && scan_x < 720 && scan_y >= 60 && scan_y < 540;
    wire photo_mix = I_photo_view_alpha != 0 && I_photo_view_alpha != 16;
    reg photo_rect_v0, photo_rect_pre;
    reg [23:0] rgb_v0;
    reg hs_v0, vs_v0, de_v0;
    // Finish page/panel coordinate arithmetic before the card/marker decoders.
    // The scan counter and frame-state sampling still use the undelayed input.
    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst) begin
            view_x <= 0;
            content_y <= 0;
            physical_y_v0 <= 0;
            view_valid <= 0;
            panel_here <= 0;
            photo_rect_v0 <= 0;
            rgb_v0 <= 0;
            hs_v0 <= 0;
            vs_v0 <= 0;
            de_v0 <= 0;
        end else begin
            view_x <= raw_view_x;
            content_y <= raw_content_y;
            physical_y_v0 <= scan_y;
            view_valid <= raw_view_valid;
            panel_here <= raw_panel_here;
            photo_rect_v0 <= raw_photo_hit;
            // A mixed FIFO word carries backdrop RGB565 in bits 31:16 and
            // photo RGB565 in bits 15:0. I_rgb is that word's bits 31:8.
            // Outside the overlay rectangle the reader keeps ordinary RGB888.
            rgb_v0 <= photo_mix && raw_photo_hit ?
                {I_rgb[23:19], I_rgb[23:21], I_rgb[18:13], I_rgb[18:17], I_rgb[12:8], I_rgb[12:10]} : I_rgb;
            hs_v0 <= I_hs;
            vs_v0 <= I_vs;
            de_v0 <= I_de;
        end
    end
    // endregion

    // region 03 区域寄存、文字请求与显示状态
    reg view_valid_pre;
    reg [9:0] physical_y_pre;
    reg [23:0] rgb_pre;
    reg [15:0] photo_v0, photo_pre, photo_d, photo_q2, photo_q3;
    reg mix_d, mix_q2, mix_q3;
    wire photo_mix_pre = photo_mix && photo_rect_pre;
    wire photo_full_pre = I_photo_full && photo_rect_pre;
    wire [23:0] overlay_rgb = {
        photo_q3[15:11], photo_q3[15:13], photo_q3[10:5], photo_q3[10:9], photo_q3[4:0], photo_q3[4:2]
    };
    always @(posedge I_clk) begin
        photo_v0 <= I_photo_rgb565;
        photo_pre <= photo_v0;
        photo_d <= photo_pre;
        photo_q2 <= photo_d;
        photo_q3 <= photo_q2;
        mix_d <= photo_mix_pre;
        mix_q2 <= mix_d;
        mix_q3 <= mix_q2;
    end
    reg hs_pre, vs_pre, de_pre;
    reg card_hit_pre;
    reg [2:0] card_row_pre;
    reg panel_hit_pre, carousel_hit_pre, map_hit_pre, photo_hit_pre;
    reg [9:0] marker_hit_pre, marker_inner_pre;
    reg card_top_pre, card_bottom_pre;
    reg card_name_x_pre, card_status_x_pre, card_prompt_x_pre;
    reg signed [11:0] card_local_x_pre, card_local_y_pre;
    integer pre;

    wire frame_edge = vs_d && !I_vs;

    reg [1:0] floor_f, period_f;
    reg selection_f;
    reg floor_selecting_f;
    reg [1:0] floor_cursor_f, requested_floor_f;

    reg [3:0] room_f;

    reg [29:0] occupied_f;

    reg [15:0] elapsed_f;

    reg auto_f, ready_f;
    reg [12:0] progress_f;
    wire [41:0] status_visible_phase;
    wire [5:0] status_selected_phase;
    reg [7:0] status_sample;
    wire [9:0] bar_end = 10'd304 + {1'b0, progress_f[12:4]};
    reg [23:0] bar_edge_color;

    wire [7:0] panel_height = I_panel_height;

    reg [8:0] photo_reveal;

    reg [7:0] scroll_offset;

    reg [7:0] scroll_frame_count;

    reg [5:0] breath_phase;

    wire [4:0] breath_level = breath_phase[5] ? ~breath_phase[4:0] : breath_phase[4:0];

    assign O_panel_active = (panel_height != 0);

    `include "guide_messages.vh"

    `include "guide_site_config.vh"
    `include "ui_text_request.vh"
    wire rt_clk = I_clk;
    `include "runtime_site_fields.vh"
    (* syn_ramstyle="block_ram" *) reg [6:0] runtime_names[0:511];
    reg [6:0] name_read_q;
    reg glyph_from_name;
    reg [8:0] name_addr;
    reg name_sel_q;
    reg [8:0] name_addr_q;
    reg [12:0] glyph_q;
    reg [3:0] row_q;
    reg [23:0] base_q2, text_q2;
    reg [3:0] gx_q2;
    reg te_q2, hs_q2, vs_q2, de_q2;
    // Optional SITE.CFG title uses eight spare words in the existing name RAM.
    // The marker follows all eight glyph IDs, so legacy configs keep the fixed
    // title and a custom title cannot be selected before its characters arrive.
    reg runtime_title_valid;
    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst) runtime_title_valid <= 0;
        else if (RUNTIME_CONFIG && cfg_we) begin
            if (cfg_addr == 13'd0) runtime_title_valid <= 0;
            else if (cfg_addr == 13'd1296) runtime_title_valid <= cfg_data == 8'h54;
        end
    end
    always @(posedge I_clk)
        if (RUNTIME_CONFIG && cfg_we && cfg_addr >= 1024 && cfg_addr < 1296)
            runtime_names[cfg_addr-1024] <= cfg_data[6:0];
    function [9:0] card_x;
        input [4:0] index;
        begin
            card_x = RUNTIME_CONFIG ? 10'd16 : site_x(index);
        end
    endfunction
    function [9:0] card_w;
        input [4:0] index;
        begin
            card_w = RUNTIME_CONFIG ? 10'd272 : site_w(index);
        end
    endfunction
    function [9:0] card_h;
        input [4:0] index;
        begin
            card_h = RUNTIME_CONFIG ? 10'd68 : site_h(index);
        end
    endfunction

    reg [9:0] marker_text_hit_pre;
    reg [23:0] base_color;
    // Carry a small palette index through the priority tree. Decode the RGB
    // value after its register, in parallel with the synchronous glyph read.
    localparam [2:0] INK_DARK = 3'd0, INK_GRAY = 3'd1, INK_AMBER = 3'd2, INK_RED = 3'd3, INK_GREEN = 3'd4,
        INK_WHITE = 3'd5, INK_BLUE = 3'd6, INK_FOOTER = 3'd7;
    reg [2:0] text_ink, text_ink_d;
    function [23:0] ink_rgb;
        input [2:0] ink;
        begin
            case (ink)
                INK_DARK: ink_rgb = 24'h152138;
                INK_GRAY: ink_rgb = 24'h81868b;
                INK_AMBER: ink_rgb = 24'h99631e;
                INK_RED: ink_rgb = 24'hc64e57;
                INK_GREEN: ink_rgb = 24'h158065;
                INK_WHITE: ink_rgb = 24'hffffff;
                INK_BLUE: ink_rgb = 24'h3477b3;
                INK_FOOTER: ink_rgb = 24'h606c78;
                default: ink_rgb = 24'h152138;
            endcase
        end
    endfunction

    reg [12:0] glyph;  // encoded source/position until the first pipeline register

    reg [3:0] glyph_x, glyph_y;  // glyph_x stores origin modulo 16, glyph_y is row

    reg text_enable;
    reg narrow_digit, narrow_d, narrow_q;

    reg [23:0] base_d;
    wire [23:0] text_color_d = ink_rgb(text_ink_d);

    reg [3:0] glyph_x_d, pixel_x_low_d;

    reg text_enable_d, hs_d, vs_pipe_d, de_pipe_d;

    wire [15:0] glyph_pixels;
    wire [1:0] list_floor;
    wire [3:0] list_room;
    wire [4:0] list_opacity;
    // endregion

    // region 04 列表动画与运行时文字
    room_list_fade list_fader (
        .clk(I_clk),
        .rst(I_rst),
        .frame_tick(frame_edge),
        .enabled(!I_map_mode && I_panel_height == 0 && !I_detail_requested),
        .target_floor(I_floor_idx),
        .target_room(I_selected_room_idx),
        .shown_floor(list_floor),
        .shown_room(list_room),
        .opacity(list_opacity)
    );
    wire [1:0] card_floor = I_map_mode ? floor_f : list_floor;
    wire [4:0] list_base = list_floor * 5'd10;
    wire [9:0] list_occupied = list_floor == 0 ? occupied_f[9:0] :
        list_floor == 1 ? occupied_f[19:10] : occupied_f[29:20];
    wire [9:0]
        map_occupied = floor_f == 0 ? occupied_f[9:0] : floor_f == 1 ? occupied_f[19:10] : occupied_f[29:20];
    wire [3:0] list_first;
    wire [6:0] list_shift;
    wire [8:0] list_position;
    wire [3:0] visible_room[0:6];
    genvar vr;
    generate
        for (vr = 0; vr < 7; vr = vr + 1) begin : visible_indices
            assign visible_room[vr] = list_first + vr;
        end
    endgenerate
    wire [10:0] list_y = {1'b0, content_y} + list_shift;
    wire [2:0] card_row_now = list_y < 166 ? 0 :
        list_y < 236 ? 1 : list_y < 306 ? 2 : list_y < 376 ? 3 : list_y < 446 ? 4 : list_y < 516 ? 5 : 6;
    wire [9:0] card_top_now = list_y < 166 ? 96 : list_y < 236 ? 166 :
        list_y < 306 ? 236 : list_y < 376 ? 306 : list_y < 446 ? 376 : list_y < 516 ? 446 : 516;
    wire [10:0] card_y_now = list_y - card_top_now;
    // Decode the seven card bodies directly. Avoid serialising the row lookup,
    // top-coordinate mux, subtraction and comparison on the card-hit path.
    wire card_body_now = (list_y >= 96 && list_y < 164) || (list_y >= 166 && list_y < 234) ||
        (list_y >= 236 && list_y < 304) || (list_y >= 306 && list_y < 374) ||
        (list_y >= 376 && list_y < 444) || (list_y >= 446 && list_y < 514) || (list_y >= 516 && list_y < 584);
    wire [3:0] card_room_now = list_first + card_row_now;
    room_list_scroll list_scroll (
        .clk(I_clk),
        .rst(I_rst),
        .frame_tick(frame_edge),
        .floor_idx(list_floor),
        .room_idx(list_room),
        .first_room(list_first),
        .pixel_shift(list_shift),
        .position(list_position)
    );
    always @(posedge I_clk) name_read_q <= runtime_names[name_addr];
    room_status_ticker status_ticker (
        .clk(I_clk),
        .rst(I_rst),
        .frame_tick(frame_edge),
        .occupied(I_room_occupied),
        .first_room(list_first),
        .floor_idx(card_floor),
        .room_idx(I_selected_room_idx),
        .visible_phase(status_visible_phase),
        .selected_phase(status_selected_phase)
    );

    reg [29:0] activity_mask;
    wire [9:0] list_activity = list_floor == 0 ? activity_mask[9:0] :
        list_floor == 1 ? activity_mask[19:10] : activity_mask[29:20];
    wire floor_activity = |list_activity;
    (* syn_ramstyle="block_ram" *) reg [7:0] notes_mem[0:4095];
    reg notes_select, notes_literal;
    reg [11:0] notes_addr;
    reg [5:0] notes_label;
    reg [7:0] notes_read_q, notes_label_q;
    reg notes_literal_q;
    wire [7:0] notes_glyph_q = notes_literal_q ? notes_label_q : notes_read_q;
    reg notes_select_q, notes_select_q2;
    wire [15:0] notes_pixels;
    `include "room_notes_labels.vh"
    always @(posedge I_clk) begin
        if (RUNTIME_CONFIG && cfg_we && cfg_addr >= 2048 && cfg_addr < 5888)
            notes_mem[cfg_addr-2048] <= cfg_data;
        notes_read_q <= notes_mem[notes_addr];
        notes_label_q <= notes_label_char(notes_label);
        notes_literal_q <= notes_literal;
    end
    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst) activity_mask <= 0;
        else if (RUNTIME_CONFIG && cfg_we && cfg_addr >= 320 && cfg_addr < 800 && cfg_addr[3:0] == 6)
            activity_mask[(cfg_addr-320)>>4] <= cfg_data[0];
    end
    room_notes_font notes_font (
        .clk(I_clk),
        .write_clk(font_write_clk),
        .write_en(RUNTIME_CONFIG && font_write_en && font_write_addr[12] && font_write_addr < 13'd5632),
        .write_addr(font_write_addr[10:0]),
        .write_data(font_write_data[15:0]),
        .glyph(notes_glyph_q),
        .row(row_q),
        .pixels(notes_pixels)
    );
    reg [4:0] fade_d, fade_q2;
    reg dim_d, dim_q2;
    reg [23:0] composed_q3;
    reg [4:0] fade_q3;
    reg dim_q3, hs_q3, vs_q3, de_q3;
    wire dim_background = I_panel_height != 0 && !panel_hit_pre && !photo_full_pre;
    wire [4:0] dim_alpha = I_panel_height >= 208 ? 8 : I_panel_height >= 182 ? 9 :
        I_panel_height >= 156 ? 10 : I_panel_height >= 130 ? 11 : I_panel_height >= 104 ? 12 :
        I_panel_height >= 78 ? 13 : I_panel_height >= 52 ? 14 : I_panel_height >= 26 ? 15 : 16;

    reg large_text, large_d, large_q2;
    reg [4:0] large_x, large_y, large_x_d, large_y_d, large_x_q2;
    reg [2:0] large_col;
    wire [23:0] large_pixels;
    guide_large_font large_font (
        .clk(I_clk),
        .write_clk(font_write_clk),
        .write_en(RUNTIME_CONFIG && font_write_en && !font_write_addr[12]),
        .write_addr(font_write_addr[11:0]),
        .write_data(font_write_data),
        .glyph(name_sel_q ? name_read_q : decode_text_request(glyph_q)),
        .row(large_y_d),
        .pixels(large_pixels)
    );
    function [2:0] font24_col;
        input [8:0] x;
        begin
            font24_col = x >= 168 ? 7 :
                x >= 144 ? 6 : x >= 120 ? 5 : x >= 96 ? 4 : x >= 72 ? 3 : x >= 48 ? 2 : x >= 24 ? 1 : 0;
        end
    endfunction
    function dot_pixel;
        input [9:0] x, y, cx, cy;
        input outer;
        reg signed [10:0] dx, dy;
        begin
            dx = $signed({1'b0, x}) - $signed({1'b0, cx});
            dy = $signed({1'b0, y}) - $signed({1'b0, cy});
            dot_pixel = outer ? (dx >= -11'sd14 && dx <= 11'sd14 && dy >= -11'sd14 && dy <= 11'sd14) :
                (dx >= -11'sd11 && dx <= 11'sd11 && dy >= -11'sd11 && dy <= 11'sd11);
        end
    endfunction
    wire [23:0] composed_rgb = te_q2 && (large_q2 ? large_pixels[23-large_x_q2] :
                                         (notes_select_q2 ? notes_pixels[15-gx_q2] : glyph_pixels[
                                          15-(narrow_q ? {gx_q2[2:0], 1'b0} : gx_q2)])) ? text_q2 : base_q2;
    function [7:0] fade_channel;
        input [7:0] c, b;
        input [4:0] a;
        reg signed [8:0] delta;
        reg signed [14:0] product;
        begin
            delta = $signed({1'b0, c}) - $signed({1'b0, b});
            product = delta * $signed({1'b0, a});
            fade_channel = $signed({1'b0, b}) + (product >>> 4);
        end
    endfunction
    wire list_fade_pixel = !I_map_mode && !photo_full_pre && !panel_hit_pre && view_valid_pre &&
        pixel_x < 304 && pixel_y >= 56 && pixel_y < 528;

    guide_font_rom font (
        .clk(I_clk),
        .glyph(RUNTIME_CONFIG ? (name_sel_q ? name_read_q : decode_text_request(
            glyph_q
        )) : decode_text_request(
            glyph
        )),
        .row(RUNTIME_CONFIG ? row_q : glyph_y),
        .pixels(glyph_pixels)
    );

    // Geometry is bounded to 800x600; retain signed local offsets without
    // synthesizing 32-bit subtract/compare chains for every room card.
    reg signed [11:0] room_x, room_y, room_w, room_h, local_x, local_y, text_x;
    reg [4:0] room_id;
    integer r;

    integer slot, selected_number;
    integer floor_row, floor_top;
    reg [9:0] marker_x[0:9], marker_y[0:9];
    reg [9:0] marker_visible;
    reg [3:0] marker_index;
    reg [1:0] marker_stage;
    reg [36:0] marker_view;
    reg [13:0] marker_scale;
    reg [1:0] marker_floor;
    wire [4:0] marker_point_id = marker_floor * 5'd10 + marker_index;
    wire [9:0] marker_point_x, marker_point_y;
    // endregion

    // region 05 观察点坐标与 pre 区域命中
    site_point_memory marker_points (
        .clk(I_clk),
        .cfg_we(cfg_we),
        .cfg_addr(cfg_addr),
        .cfg_data(cfg_data),
        .read_index(marker_point_id),
        .point_x(marker_point_x),
        .point_y(marker_point_y)
    );
    reg [10:0] marker_width;
    reg [9:0] marker_height;
    reg marker_in_image;
    reg signed [12:0] marker_dx, marker_dy;
    reg signed [27:0] marker_px, marker_py;
    wire signed [27:0] marker_screen_x = 28'sd328 + (marker_px >>> 13);
    wire signed [27:0] marker_screen_y = 28'sd240 + (marker_py >>> 13);

    integer m;
    function [9:0] scale_three_quarters_x;
        input [9:0] v;
        reg [11:0] t;
        begin
            t = {2'b0, v} + ({2'b0, v} << 1);
            scale_three_quarters_x = t >> 2;
        end
    endfunction
    function [9:0] scale_three_quarters_y;
        input [8:0] v;
        reg [10:0] t;
        begin
            t = {2'b0, v} + ({2'b0, v} << 1);
            scale_three_quarters_y = t >> 2;
        end
    endfunction
    function [9:0] scale_four_thirds;
        input [9:0] v;
        begin
            scale_four_thirds = v + v / 10'd3;
        end
    endfunction
    reg loading_f, error_f, map_loading_f;
    reg occupied_now, border, icon_pixel;

    reg [3:0] period_tens, period_ones;

    // Geometry stage: compute bounded card geometry independently of text/overlay
    // priority. Delay the source pixel and timing with these coordinates.
    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst) begin
            card_row_pre <= 0;
            physical_y_pre <= 0;
            photo_rect_pre <= 0;
            view_valid_pre <= 0;
            pixel_x <= 0;
            pixel_y <= 0;
            rgb_pre <= 0;
            hs_pre <= 0;
            vs_pre <= 0;
            de_pre <= 0;
            card_hit_pre <= 0;
            marker_text_hit_pre <= 0;
            marker_hit_pre <= 0;
            marker_inner_pre <= 0;
            card_top_pre <= 0;
            card_bottom_pre <= 0;
            card_name_x_pre <= 0;
            card_status_x_pre <= 0;
            card_prompt_x_pre <= 0;
            panel_hit_pre <= 0;
            carousel_hit_pre <= 0;
            map_hit_pre <= 0;
            photo_hit_pre <= 0;
            card_local_x_pre <= 0;
            card_local_y_pre <= 0;
        end else begin
            card_row_pre <= card_row_now;
            physical_y_pre <= physical_y_v0;
            photo_rect_pre <= photo_rect_v0;
            view_valid_pre <= view_valid;
            pixel_x <= view_x;
            pixel_y <= content_y;
            rgb_pre <= rgb_v0;
            hs_pre <= hs_v0;
            vs_pre <= vs_v0;
            de_pre <= de_v0;
            panel_hit_pre <= panel_here;
            carousel_hit_pre <= view_x >= 304 && view_x < 784 && content_y >= 64 && content_y < 424;
            map_hit_pre <= view_x >= 8 && view_x < 648 && content_y >= 56 && content_y < 536;
            photo_hit_pre <= view_x >= 288 && view_x < 768 && content_y >= 136 && content_y < 496;
            card_name_x_pre <= view_x >= 30 && view_x < 222;
            card_status_x_pre <= view_x >= 244 && view_x < 276;
            card_prompt_x_pre <= view_x >= 30 && view_x < 254;
            card_top_pre <= card_y_now >= 8 && card_y_now < 32;
            card_bottom_pre <= card_y_now >= 42 && card_y_now < 58;
            card_local_x_pre <= $signed({2'b0, view_x}) - 12'sd16;
            card_local_y_pre <= $signed({1'b0, card_y_now});
            card_hit_pre <= card_room_now < cfg_room_count(
                card_floor
            ) && content_y >= 96 && content_y < 516 && view_x >= 16 && view_x < 288 && card_body_now;
            for (pre = 0; pre < 10; pre = pre + 1) begin
                marker_hit_pre[pre] <= dot_pixel(view_x, content_y, marker_x[pre], marker_y[pre], 1'b1);
                marker_inner_pre[pre] <= dot_pixel(view_x, content_y, marker_x[pre], marker_y[pre], 1'b0);
                marker_text_hit_pre[pre] <= view_x >= marker_x[pre] - 10'd8 && view_x < marker_x[pre] +
                    10'd8 && content_y >= marker_y[pre] - 10'd8 && content_y < marker_y[pre] + 10'd8;
            end
        end
    end

    // endregion

    // region 06 按区域选择底色与文字请求
    always @* begin
        floor_top = 0;
        large_text = 0;
        large_x = 0;
        large_y = 0;
        large_col = 0;
        notes_select = 0;
        notes_literal = 0;
        notes_addr = 0;
        notes_label = 0;
        name_addr = 0;
        glyph_from_name = 0;
        base_color = 24'hf8f7f5;
        text_ink = INK_DARK;
        glyph = 0;
        glyph_x = 0;
        glyph_y = 0;
        text_enable = 0;
        narrow_digit = 0;
        r = 0;
        room_x = 0;
        room_y = 0;
        room_w = 0;
        room_h = 0;
        room_id = 0;
        local_x = 0;
        local_y = 0;
        text_x = 0;
        slot = 0;
        selected_number = floor_f * 10 + room_f;
        occupied_now = 0;
        border = 0;
        icon_pixel = 0;
        status_sample = 0;
        case (progress_f[3:2])
            0: bar_edge_color = 24'he6e6e1;
            1: bar_edge_color = 24'hc6d3dc;
            2: bar_edge_color = 24'hacbecd;
            default: bar_edge_color = 24'h8fa7bc;
        endcase
        case (period_f)
            0: begin
                period_tens = 0;
                period_ones = 5;
            end
            1: begin
                period_tens = 0;
                period_ones = 2;
            end
            2: begin
                period_tens = 1;
                period_ones = 0;
            end
            default: begin
                period_tens = 3;
                period_ones = 0;
            end
        endcase
        if (!I_map_mode) begin
            // Separate section heading, six spacious rows and a bounded image viewport.
            if (pixel_x >= 16 && pixel_x < 288 && pixel_y >= 56 && pixel_y < 528) base_color = 24'hfefefe;
            if (pixel_y >= 68 && pixel_y < 84 && pixel_x >= 28 && pixel_x < 92) begin
                text_enable = 1;
                glyph = request_ui(16 + ((pixel_x - 28) >> 4));
                glyph_x = 28;
                glyph_y = pixel_y - 68;
            end
            if (floor_activity && pixel_x >= 104 && pixel_x < 148 && pixel_y >= 64 && pixel_y < 88) begin
                base_color = 24'hffedba;
                if (pixel_x >= 110 && pixel_x < 142 && pixel_y >= 68 && pixel_y < 84) begin
                    text_enable = 1;
                    notes_select = 1;
                    notes_literal = 1;
                    notes_label = 18 + ((pixel_x - 110) >> 4);
                    glyph_x = 110;
                    glyph_y = pixel_y - 68;
                    text_ink = INK_AMBER;
                end
            end
            if (|card_hit_pre) begin
                r = card_row_pre;
                room_id = list_base + visible_room[r];
                room_x = card_x(room_id);
                room_w = card_w(room_id);
                local_x = card_local_x_pre;
                local_y = card_local_y_pre;
                occupied_now = list_occupied[visible_room[r]];
                base_color = selection_f && visible_room[r] == list_room ? 24'he6eef5 : 24'hfefefe;
                if (local_x < 3 && selection_f && visible_room[r] == list_room) base_color = 24'h3477b3;
                if (local_y == 67 && local_x >= 12 && local_x < room_w - 12) base_color = 24'he0e1de;
                if (card_top_pre && card_name_x_pre) begin
                    text_enable = 1;
                    glyph_from_name = RUNTIME_CONFIG;
                    large_text = RUNTIME_CONFIG;
                    large_col = font24_col(local_x - 14);
                    large_x = local_x - 14 - large_col * 24;
                    large_y = local_y - 8;
                    name_addr = (room_id << 3) + large_col;
                    glyph = request_room(name_addr);
                    glyph_x = room_x + 14;
                    glyph_y = local_y - 8;
                end
                if (card_bottom_pre) begin
                    if (local_x >= 14 && local_x < 62) begin
                        text_enable = 1;
                        glyph_x = room_x + 14;
                        glyph_y = local_y - 42;
                        text_ink = INK_GRAY;
                        case ((local_x - 14) >> 4)
                            0: glyph = 2 + list_floor;
                            1: glyph = visible_room[r] == 9 ? 13'd2 : 13'd1;
                            default: glyph = visible_room[r] == 9 ? 13'd1 : 2 + visible_room[r];
                        endcase
                    end
                    if (card_status_x_pre) begin
                        status_sample = local_x - (room_w - 44) + {2'd0, status_visible_phase[r*6+:6]};
                        text_enable = 1;
                        glyph = status_sample[5] ? 13'd0 :
                            request_message(occupied_now ? 2 : 3, {5'd0, status_sample[4]});
                        glyph_x = room_x + room_w - 44 - status_visible_phase[r*6+:6];
                        glyph_y = local_y - 42;
                        text_ink = occupied_now ? INK_RED : INK_GREEN;
                    end
                end
                if (list_activity[visible_room[r]] && local_x >= 168 && local_x < 212 && local_y >= 38 &&
                    local_y < 62) begin
                    base_color = 24'hffedba;
                    if (local_x >= 174 && local_x < 206 && local_y >= 42 && local_y < 58) begin
                        text_enable = 1;
                        notes_select = 1;
                        notes_literal = 1;
                        notes_label = 18 + ((local_x - 174) >> 4);
                        glyph_x = room_x + 174;
                        glyph_y = local_y - 42;
                        text_ink = INK_AMBER;
                    end
                end
            end
            if (carousel_hit_pre) begin
                base_color = rgb_pre;
                text_enable = 0;
                large_text = 0;
                notes_select = 0;
            end
            if (pixel_x >= 304 && pixel_x < 784 && pixel_y >= 426 && pixel_y < 432) begin
                text_enable = 0;
                base_color = pixel_x < bar_end ? 24'h3477b3 :
                    pixel_x == bar_end ? bar_edge_color : 24'he2e3e0;
            end
            if (pixel_x >= 304 && pixel_x < 784 && pixel_y >= 440 && pixel_y < 528) begin
                base_color = 24'hfefefe;
                if (pixel_x >= 320 && pixel_x < 384 && pixel_y >= 450 && pixel_y < 466) begin
                    text_enable = 1;
                    glyph = request_ui(32 + ((pixel_x - 320) >> 4));
                    glyph_x = 320;
                    glyph_y = pixel_y - 450;
                    text_ink = INK_GRAY;
                end
                if (pixel_x >= 320 && pixel_x < 512 && pixel_y >= 478 && pixel_y < 502) begin
                    text_enable = 1;
                    large_text = 1;
                    glyph_from_name = 1;
                    large_col = font24_col(pixel_x - 320);
                    large_x = pixel_x - 320 - large_col * 24;
                    large_y = pixel_y - 478;
                    name_addr = (selected_number << 3) + large_col;
                end
                if (pixel_x >= 528 && pixel_x < 560 && pixel_y >= 454 && pixel_y < 470) begin
                    status_sample = pixel_x - 528 + {2'd0, status_selected_phase};
                    text_enable = 1;
                    glyph = status_sample[5] ? 13'd0 :
                        request_message(occupied_f[selected_number] ? 2 : 3, {5'd0, status_sample[4]});
                    glyph_x = 528 - status_selected_phase;
                    glyph_y = pixel_y - 454;
                    text_ink = occupied_f[selected_number] ? INK_RED : INK_GREEN;
                end
                if (pixel_x >= 528 && pixel_x < 592 && pixel_y >= 486 && pixel_y < 502) begin
                    text_enable = 1;
                    glyph = request_message(5, (pixel_x - 528) >> 4);
                    glyph_x = 528;
                    glyph_y = pixel_y - 486;
                    text_ink = INK_GRAY;
                end
                if (pixel_x >= 608 && pixel_x < 688 && pixel_y >= 486 && pixel_y < 502) begin
                    text_enable = 1;
                    glyph_x = 608;
                    glyph_y = pixel_y - 486;
                    case ((pixel_x - 608) >> 4)
                        0: glyph = 1 + elapsed_f[15:12];
                        1: glyph = 1 + elapsed_f[11:8];
                        2: glyph = 11;
                        3: glyph = 1 + elapsed_f[7:4];
                        default: glyph = 1 + elapsed_f[3:0];
                    endcase
                end
            end
        end
        if (I_map_mode) begin
            if (pixel_x >= 8 && pixel_x < 648 && pixel_y >= 56 && pixel_y < 536) base_color = 24'hdadcd9;
            if (map_hit_pre) begin
                // Reader supplies the warm-gray map padding; source pixels remain unchanged.
                base_color = ready_f ? rgb_pre : 24'hdadcd9;
                for (r = 0; r < 10; r = r + 1)
                if (cfg_show && (!cfg_selected || r == room_f) && marker_visible[r] &&
                    marker_hit_pre[r]) begin
                    if (selection_f && r == room_f) base_color = 24'h3477b3;
                    if (marker_inner_pre[r]) base_color = map_occupied[r] ? 24'hc64e57 : 24'h158065;
                    if (marker_text_hit_pre[r]) begin
                        narrow_digit = r == 9;
                        text_enable = 1;
                        glyph = r == 9 ? (pixel_x < marker_x[r] ? 13'd2 : 13'd1) : 2 + r;
                        glyph_x = marker_x[r] - 8;
                        glyph_y = pixel_y - marker_y[r] + 8;
                        text_ink = INK_WHITE;
                    end
                end
            end
            if (pixel_x >= 656 && pixel_x < 792 && pixel_y >= 56 && pixel_y < 320) begin
                base_color = 24'hfefefe;
                if (pixel_x >= 672 && pixel_x < 704 && pixel_y >= 70 && pixel_y < 86) begin
                    text_enable = 1;
                    glyph = request_message(12, (pixel_x - 672) >> 4);
                    glyph_x = 672;
                    glyph_y = pixel_y - 70;
                end
                for (floor_row = 0; floor_row < 3; floor_row = floor_row + 1) begin
                    floor_top = 100 + (cfg_floors - 1 - floor_row) * 56;
                    if (floor_row < cfg_floors && pixel_y >= floor_top && pixel_y < floor_top + 56) begin
                        base_color = floor_row == floor_f ? 24'he6eef5 : 24'hfefefe;
                        if (pixel_x < 660 && floor_row == floor_f) base_color = 24'h3477b3;
                        if (pixel_y == floor_top + 55) base_color = 24'he0e1de;
                        if (floor_selecting_f && floor_row == floor_cursor_f &&
                            (pixel_x == 660 || pixel_x == 790 || pixel_y == floor_top ||
                             pixel_y == floor_top + 54))
                            base_color = 24'h3477b3;
                        if (requested_floor_f != floor_f && floor_row == requested_floor_f &&
                            pixel_y >= floor_top + 52)
                            base_color = error_f ? 24'hc64e57 : 24'he3a137;
                        if (pixel_x >= 672 && pixel_x < 784 && pixel_y >= floor_top + 16 &&
                            pixel_y < floor_top + 40) begin
                            text_enable = 1;
                            large_text = 1;
                            glyph_from_name = 1;
                            large_col = font24_col(pixel_x - 672);
                            large_x = pixel_x - 672 - large_col * 24;
                            large_y = pixel_y - floor_top - 16;
                            name_addr = 240 + floor_row * 8 + large_col;
                        end
                    end
                end
                if (pixel_x >= 672 && pixel_x < 704 && pixel_y >= 284 && pixel_y < 300) begin
                    text_enable = 1;
                    glyph = pixel_x < 688 ? 13'd41 : 13'd5;
                    glyph_x = 672;
                    glyph_y = pixel_y - 284;
                    text_ink = INK_GRAY;
                end
                if (pixel_x >= 720 && pixel_x < 752 && pixel_y >= 284 && pixel_y < 300) begin
                    text_enable = 1;
                    glyph = request_message(12, (pixel_x - 720) >> 4);
                    glyph_x = 720;
                    glyph_y = pixel_y - 284;
                    text_ink = INK_GRAY;
                end
            end
            if (pixel_x >= 656 && pixel_x < 792 && pixel_y >= 332 && pixel_y < 536) begin
                base_color = 24'hfefefe;
                if (pixel_x >= 668 && pixel_x < 732 && pixel_y >= 346 && pixel_y < 362) begin
                    text_enable = 1;
                    glyph = request_ui(32 + ((pixel_x - 668) >> 4));
                    glyph_x = 668;
                    glyph_y = pixel_y - 346;
                    text_ink = INK_GRAY;
                end
                if (pixel_x >= 668 && pixel_x < 764 &&
                    ((pixel_y >= 378 && pixel_y < 402) || (pixel_y >= 406 && pixel_y < 430))) begin
                    text_enable = 1;
                    large_text = 1;
                    glyph_from_name = 1;
                    large_col = font24_col(pixel_x - 668);
                    large_x = pixel_x - 668 - large_col * 24;
                    large_y = pixel_y >= 406 ? pixel_y - 406 : pixel_y - 378;
                    name_addr = (selected_number << 3) + large_col + (pixel_y >= 406 ? 4 : 0);
                end
                if (pixel_x >= 668 && pixel_x < 716 && pixel_y >= 438 && pixel_y < 454) begin
                    text_enable = 1;
                    glyph_x = 668;
                    glyph_y = pixel_y - 438;
                    text_ink = INK_GRAY;
                    case ((pixel_x - 668) >> 4)
                        0: glyph = 2 + floor_f;
                        1: glyph = room_f == 9 ? 13'd2 : 13'd1;
                        default: glyph = room_f == 9 ? 13'd1 : 2 + room_f;
                    endcase
                end
                if (pixel_x >= 668 && pixel_x < 712 && pixel_y >= 472 && pixel_y < 500) begin
                    base_color = occupied_f[selected_number] ? 24'hc64e57 : 24'h158065;
                    if (pixel_x >= 674 && pixel_x < 706 && pixel_y >= 478 && pixel_y < 494) begin
                        text_enable = 1;
                        glyph = request_message(occupied_f[selected_number] ? 2 : 3, (pixel_x - 674) >> 4);
                        glyph_x = 674;
                        glyph_y = pixel_y - 478;
                        text_ink = INK_WHITE;
                    end
                end
                if (activity_mask[selected_number] && pixel_x >= 724 && pixel_x < 776 && pixel_y >= 472 &&
                    pixel_y < 500) begin
                    base_color = 24'hffedba;
                    if (pixel_x >= 734 && pixel_x < 766 && pixel_y >= 478 && pixel_y < 494) begin
                        text_enable = 1;
                        notes_select = 1;
                        notes_literal = 1;
                        notes_label = 18 + ((pixel_x - 734) >> 4);
                        glyph_x = 734;
                        glyph_y = pixel_y - 478;
                        text_ink = INK_AMBER;
                    end
                end
            end
        end
        // Header has 12px top/bottom breathing room and a centered floor name.
        if (pixel_y < 48) begin
            base_color = 24'hf9f8f6;
            text_enable = 0;
            large_text = 0;
            notes_select = 0;
            if (pixel_y == 47) base_color = 24'he0e1de;
            if (pixel_x >= 16 && pixel_x < 208 && pixel_y >= 12 && pixel_y < 36) begin
                text_enable = 1;
                large_text = 1;
                glyph_from_name = RUNTIME_CONFIG && runtime_title_valid;
                large_col = font24_col(pixel_x - 16);
                large_x = pixel_x - 16 - large_col * 24;
                large_y = pixel_y - 12;
                name_addr = 9'd264 + {6'd0, large_col};
                glyph = request_ui(large_col);
            end
            if (pixel_x >= 376 && pixel_x < 496 && pixel_y >= 12 && pixel_y < 36) begin
                text_enable = 1;
                large_text = 1;
                glyph_from_name = 1;
                large_col = font24_col(pixel_x - 376);
                large_x = pixel_x - 376 - large_col * 24;
                large_y = pixel_y - 12;
                name_addr = 240 + ((I_map_mode ? floor_f : list_floor) << 3) + large_col;
            end
            if (pixel_x >= 704 && pixel_x < 768 && pixel_y >= 16 && pixel_y < 32) begin
                text_enable = 1;
                glyph_from_name = 0;
                glyph = I_map_mode ? request_map((pixel_x - 704) >> 4) :
                    request_ui(48 + ((pixel_x - 704) >> 4));
                glyph_x = 704;
                glyph_y = pixel_y - 16;
            end
        end
        // One embedded status strip; audio draws only the trace in its right end.
        if (pixel_x >= 8 && pixel_x < 792 && pixel_y >= 540 && pixel_y < 564) begin
            base_color = 24'hfefefe;
            text_enable = 0;
            large_text = 0;
            notes_select = 0;
            glyph_from_name = 0;
            text_ink = INK_GRAY;
            if (pixel_x >= 20 && pixel_x < 308 && pixel_y >= 544 && pixel_y < 560) begin
                text_enable = 1;
                glyph = request_message(
                    I_map_pan ? 15 :
                        floor_selecting_f ? 4 : selection_f ? (I_map_mode ? 8 : 1) : (I_map_mode ? 6 : 0),
                    (pixel_x - 20) >> 4
                );
                glyph_x = 20;
                glyph_y = pixel_y - 544;
            end
            if ((loading_f || error_f || map_loading_f) && pixel_x >= 320 && pixel_x < 496 &&
                pixel_y >= 544 && pixel_y < 560) begin
                text_enable = 1;
                glyph = request_status({error_f, 4'd0} + ((pixel_x - 320) >> 4));
                glyph_x = 320;
                glyph_y = pixel_y - 544;
                text_ink = error_f ? INK_RED : INK_BLUE;
                if (map_loading_f && !error_f)
                    case ((pixel_x - 320) >> 4)
                        0: glyph = 13'd119;
                        1: glyph = 13'd35;
                        2: glyph = 13'd120;
                        3: glyph = 13'd121;
                        4: glyph = 13'd39;
                        default: glyph = 0;
                    endcase
            end
        end
        // Raised modal: warm surface, distinct border, separate header and footer.
        if (panel_hit_pre) begin
            base_color = 24'hf9f8f6;
            text_enable = 0;
            large_text = 0;
            notes_select = 0;
            glyph_from_name = 0;
            text_ink = INK_DARK;
            if (pixel_x == 32 || pixel_x == 783 || pixel_y == 72 || pixel_y == 527) base_color = 24'h8298ac;
            if (pixel_y == 122 || pixel_y == 502) base_color = 24'hd9dddf;
            if (pixel_y >= 503 && pixel_y < 527 && pixel_x > 32 && pixel_x < 783) base_color = 24'heeeFEB;
            if (pixel_x >= 52 && pixel_x < 244 && pixel_y >= 86 && pixel_y < 110) begin
                text_enable = 1;
                large_text = 1;
                glyph_from_name = 1;
                large_col = font24_col(pixel_x - 52);
                large_x = pixel_x - 52 - large_col * 24;
                large_y = pixel_y - 86;
                name_addr = (selected_number << 3) + large_col;
            end
            if (pixel_x >= 724 && pixel_x < 756 && pixel_y >= 90 && pixel_y < 106) begin
                text_enable = 1;
                glyph = request_message(occupied_f[selected_number] ? 2 : 3, (pixel_x - 724) >> 4);
                glyph_x = 724;
                glyph_y = pixel_y - 90;
                text_ink = occupied_f[selected_number] ? INK_RED : INK_GREEN;
            end
            if (pixel_x >= 56 && pixel_x < 120 && pixel_y >= 142 && pixel_y < 158) begin
                text_enable = 1;
                glyph = request_message(5, (pixel_x - 56) >> 4);
                glyph_x = 56;
                glyph_y = pixel_y - 142;
                text_ink = INK_GRAY;
            end
            if (pixel_x >= 56 && pixel_x < 136 && pixel_y >= 170 && pixel_y < 186) begin
                text_enable = 1;
                glyph_x = 56;
                glyph_y = pixel_y - 170;
                case ((pixel_x - 56) >> 4)
                    0: glyph = 1 + elapsed_f[15:12];
                    1: glyph = 1 + elapsed_f[11:8];
                    2: glyph = 11;
                    3: glyph = 1 + elapsed_f[7:4];
                    default: glyph = 1 + elapsed_f[3:0];
                endcase
            end
            if (pixel_x >= 56 && pixel_x < 248 && pixel_y == 202) base_color = 24'hd9dddf;
            if (pixel_x == 272 && pixel_y >= 136 && pixel_y < 496) base_color = 24'hd9dddf;
            if (photo_hit_pre) begin
                base_color = ready_f ? rgb_pre : 24'hdadcd9;
                text_enable = 0;
                large_text = 0;
                notes_select = 0;
            end
            if (RUNTIME_CONFIG && pixel_x >= 48 && pixel_x < 264 && pixel_y >= 214 && pixel_y < 484) begin
                if (pixel_y >= 348) base_color = activity_mask[selected_number] ? 24'hfff0c7 : 24'hf0f0eb;
                if (pixel_x < 51 && pixel_y >= 348 && activity_mask[selected_number]) base_color = 24'hd7a035;
                if (pixel_x >= 56 && pixel_x < 248) begin
                    if ((pixel_y >= 216 && pixel_y < 232) || (pixel_y >= 358 && pixel_y < 374)) begin
                        text_enable = 1;
                        notes_select = 1;
                        notes_literal = 1;
                        notes_label = (pixel_y >= 358 ? (activity_mask[selected_number] ? 16 : 32) : 0) +
                            ((pixel_x - 56) >> 4);
                        glyph_x = 56;
                        glyph_y = pixel_y >= 358 ? pixel_y - 358 : pixel_y - 216;
                        text_ink = pixel_y >= 358 ? INK_AMBER : INK_GRAY;
                    end
                    if ((pixel_y >= 240 && pixel_y < 320) ||
                        (pixel_y >= 386 && pixel_y < 466 && activity_mask[selected_number])) begin
                        slot = pixel_y >= 386 ?
                            (pixel_y >= 446 ? 3 : pixel_y >= 426 ? 2 : pixel_y >= 406 ? 1 : 0) :
                            (pixel_y >= 300 ? 3 : pixel_y >= 280 ? 2 : pixel_y >= 260 ? 1 : 0);
                        if ((pixel_y - (pixel_y >= 386 ? 386 : 240) - slot * 20) < 16) begin
                            text_enable = 1;
                            notes_select = 1;
                            notes_literal = 0;
                            notes_addr = selected_number * 128 + (pixel_y >= 386 ? 64 : 0) + slot * 16 +
                                ((pixel_x - 56) >> 4);
                            glyph_x = 56;
                            glyph_y = pixel_y - (pixel_y >= 386 ? 386 : 240) - slot * 20;
                        end
                    end
                end
            end
            if (pixel_x >= 128 && pixel_x < 512 && pixel_y >= 507 && pixel_y < 523) begin
                text_enable = 1;
                glyph_from_name = 0;
                notes_select = 0;
                large_text = 0;
                glyph = request_message(14, (pixel_x - 128) >> 4);
                glyph_x = 128;
                glyph_y = pixel_y - 507;
                text_ink = INK_FOOTER;
            end
        end
        if (photo_full_pre) begin
            base_color = rgb_pre;
            text_enable = 0;
            large_text = 0;
            notes_select = 0;
            glyph_from_name = 0;
        end
        if (!view_valid_pre) begin
            base_color = 24'hf8f7f5;
            text_enable = 0;
        end
        if (physical_y_pre >= 568) begin
            base_color = 24'hf9f8f6;
            text_enable = 0;
            large_text = 0;
            notes_select = 0;
            glyph_from_name = 0;
            if (pixel_y == 568) base_color = 24'he0e1de;
            if (pixel_x == 400 && pixel_y >= 574 && pixel_y < 592) base_color = 24'he0e1de;
            if (pixel_y >= 594 && pixel_y < 597 && ((!I_map_mode && pixel_x >= 180 && pixel_x < 220) ||
                                                    (I_map_mode && pixel_x >= 580 && pixel_x < 620)))
                base_color = 24'h3477b3;
            text_ink = (!I_map_mode && pixel_x < 400) || (I_map_mode && pixel_x >= 400) ? INK_BLUE : INK_DARK;
            if (pixel_y >= 574 && pixel_y < 590) begin
                if (pixel_x >= 168 && pixel_x < 232) begin
                    text_enable = 1;
                    glyph = request_ui(16 + ((pixel_x - 168) >> 4));
                    glyph_x = 168;
                    glyph_y = pixel_y - 574;
                end
                if (pixel_x >= 568 && pixel_x < 632) begin
                    text_enable = 1;
                    glyph = request_map((pixel_x - 568) >> 4);
                    glyph_x = 568;
                    glyph_y = pixel_y - 574;
                end
            end
        end
    end

    // endregion

    // region 07 字模流水、最终混合与帧状态更新
    always @(posedge I_clk or posedge I_rst) begin

        if (I_rst) begin

            composed_q3 <= 0;
            fade_q3 <= 16;
            dim_q3 <= 0;
            hs_q3 <= 0;
            vs_q3 <= 0;
            de_q3 <= 0;

            narrow_d <= 0;
            narrow_q <= 0;
            large_d <= 0;
            large_q2 <= 0;
            large_x_d <= 0;
            large_y_d <= 0;
            large_x_q2 <= 0;
            notes_select_q <= 0;
            notes_select_q2 <= 0;
            fade_d <= 16;
            fade_q2 <= 16;
            dim_d <= 0;
            dim_q2 <= 0;
            name_sel_q <= 0;
            name_addr_q <= 0;
            glyph_q <= 0;
            row_q <= 0;
            base_q2 <= 0;
            text_q2 <= 0;
            gx_q2 <= 0;
            te_q2 <= 0;
            hs_q2 <= 0;
            vs_q2 <= 0;
            de_q2 <= 0;
            vs_d <= 0;
            de_d <= 0;
            scan_x <= 0;
            scan_y <= 0;

            floor_f <= 0;
            room_f <= 0;
            occupied_f <= 0;
            elapsed_f <= 0;
            auto_f <= 0;
            period_f <= 0;
            ready_f <= 0;
            progress_f <= 0;
            selection_f <= 0;
            floor_selecting_f <= 0;
            floor_cursor_f <= 0;
            requested_floor_f <= 0;

            photo_reveal <= 0;
            scroll_offset <= 96;
            scroll_frame_count <= 0;
            breath_phase <= 0;
            marker_index <= 15;
            marker_stage <= 0;
            marker_view <= 0;
            marker_scale <= 4096;
            marker_floor <= 0;
            marker_dx <= 0;
            marker_dy <= 0;
            marker_px <= 0;
            marker_py <= 0;
            marker_width <= 640;
            marker_height <= 480;
            marker_in_image <= 0;
            marker_visible <= 0;
            loading_f <= 0;
            error_f <= 0;
            map_loading_f <= 0;
            for (m = 0; m < 10; m = m + 1) begin
                marker_x[m] <= 0;
                marker_y[m] <= 0;
            end
            base_d <= 0;
            text_ink_d <= INK_DARK;
            glyph_x_d <= 0;
            pixel_x_low_d <= 0;
            text_enable_d <= 0;

            hs_d <= 0;
            vs_pipe_d <= 0;
            de_pipe_d <= 0;
            O_rgb <= 0;
            O_hs <= 0;
            O_vs <= 0;
            O_de <= 0;

        end else begin

            narrow_d <= narrow_digit;
            narrow_q <= narrow_d;
            large_d <= large_text;
            large_q2 <= large_d;
            large_x_d <= large_x;
            large_y_d <= large_y;
            large_x_q2 <= large_x_d;
            notes_select_q <= notes_select;
            notes_select_q2 <= notes_select_q;
            dim_d <= dim_background;
            dim_q2 <= dim_d;
            // Reuse the existing blend for detail -> native photo. The retained
            // detail panel is fully open, so its outside dim is exactly one half.
            fade_d <= photo_mix_pre ? 5'd16 -
                I_photo_view_alpha : (dim_background ? dim_alpha : (list_fade_pixel ? list_opacity : 5'd16));
            fade_q2 <= fade_d;
            name_sel_q <= glyph_from_name;
            name_addr_q <= name_addr;
            glyph_q <= glyph;
            row_q <= glyph_y;
            base_q2 <= base_d;
            text_q2 <= text_color_d;
            gx_q2 <= pixel_x_low_d - glyph_x_d;
            te_q2 <= text_enable_d;
            hs_q2 <= hs_d;
            vs_q2 <= vs_pipe_d;
            de_q2 <= de_pipe_d;
            vs_d <= I_vs;
            de_d <= I_de;

            // d 级保存字形起点和像素 X 低位，q2 级相减得到字内列号，与字模行配套。
            base_d <= base_color;
            text_ink_d <= text_ink;
            glyph_x_d <= glyph_x;
            pixel_x_low_d <= pixel_x[3:0];
            text_enable_d <= text_enable;

            hs_d <= hs_pre;
            vs_pipe_d <= vs_pre;
            de_pipe_d <= de_pre;

            if (RUNTIME_CONFIG) begin
                // Separate the glyph-ROM/bit-selection path from color blending.
                composed_q3 <= mix_q2 && dim_q2 ? {1'b0, composed_rgb[23:17], 1'b0, composed_rgb[15:9], 1'b0,
                                                   composed_rgb[7:1]} : composed_rgb;
                fade_q3 <= fade_q2;
                dim_q3 <= dim_q2;
                hs_q3 <= hs_q2;
                vs_q3 <= vs_q2;
                de_q3 <= de_q2;
                O_rgb <= !de_q3 ? 24'd0 : {fade_channel(
                    composed_q3[23:16], mix_q3 ? overlay_rgb[23:16] : (dim_q3 ? 8'd0 : 8'hf8), fade_q3
                ), fade_channel(
                    composed_q3[15:8], mix_q3 ? overlay_rgb[15:8] : (dim_q3 ? 8'd0 : 8'hf7), fade_q3
                ), fade_channel(
                    composed_q3[7:0], mix_q3 ? overlay_rgb[7:0] : (dim_q3 ? 8'd0 : 8'hf5), fade_q3
                )};
                O_hs <= hs_q3;
                O_vs <= vs_q3;
                O_de <= de_q3;
            end else begin
                O_rgb <= !de_pipe_d ? 24'd0 : (text_enable_d && glyph_pixels[
                                               15-((pixel_x_low_d-glyph_x_d)&4'hf)] ? text_color_d : base_d);

                O_hs <= hs_d;
                O_vs <= vs_pipe_d;
                O_de <= de_pipe_d;
            end

            if (!frame_edge && marker_index < 10)
                case (marker_stage)
                    0: begin
                        marker_in_image <= marker_point_x < marker_width && marker_point_y < marker_height;
                        marker_dx <= $signed(
                            {2'b0, marker_point_x, 1'b0}
                        ) - $signed(
                            {1'b0, marker_view[22:11]}
                        );
                        marker_dy <= $signed(
                            {2'b0, marker_point_y, 1'b0}
                        ) - $signed(
                            {2'b0, marker_view[10:0]}
                        );
                        marker_stage <= 1;
                    end
                    1: begin
                        marker_px <= marker_dx * $signed({1'b0, marker_scale});
                        marker_py <= marker_dy * $signed({1'b0, marker_scale});
                        marker_stage <= 2;
                    end
                    2: begin
                        marker_x[marker_index] <= marker_screen_x;
                        marker_y[marker_index] <= 56 + marker_screen_y;
                        marker_visible[marker_index] <= marker_in_image && marker_index < cfg_room_count(
                            marker_floor
                        ) && marker_screen_x >= 8 && marker_screen_x < 648 && marker_screen_y >= 0 &&
                            marker_screen_y < 480;
                        marker_index <= marker_index + 1'b1;
                        marker_stage <= 3;
                    end
                    default: marker_stage <= 0;
                endcase
            if (frame_edge) begin
                progress_f <= I_carousel_progress;
                loading_f <= I_loading;
                error_f <= I_load_error;
                map_loading_f <= I_map_loading;
                marker_view <= I_map_view;
                marker_scale <= I_map_scale;
                marker_floor <= I_floor_idx;
                marker_width <= I_map_width;
                marker_height <= I_map_height;
                marker_index <= 0;
                marker_stage <= 3;
                floor_f <= I_floor_idx;
                room_f <= I_selected_room_idx;
                occupied_f <= I_room_occupied;
                selection_f <= I_selection_visible;
                floor_selecting_f <= I_floor_selecting;
                floor_cursor_f <= I_floor_cursor;
                requested_floor_f <= I_requested_floor;

                elapsed_f <= I_elapsed_bcd;
                auto_f <= I_auto_play_en;
                period_f <= I_period_select;
                ready_f <= I_view_settled;

                scan_x <= 0;
                scan_y <= 0;
                breath_phase <= breath_phase + 1'b1;

                if (!I_detail_requested || !I_view_settled) photo_reveal <= 0;

                else if (photo_reveal < 480)

                    photo_reveal <= (photo_reveal + PHOTO_STEP >= 480) ? 480 : photo_reveal + PHOTO_STEP;

                if (scroll_frame_count >= SCROLL_FRAMES - 1) begin

                    scroll_frame_count <= 0;

                    scroll_offset <= scroll_offset >= 191 ? 0 : scroll_offset + 1'b1;

                end else scroll_frame_count <= scroll_frame_count + 1'b1;

            end else if (!I_de) begin

                scan_x <= 0;

                if (de_d) scan_y <= scan_y == 599 ? 0 : scan_y + 1'b1;

            end else if (scan_x < 799) scan_x <= scan_x + 1'b1;

        end

    end

    // endregion

endmodule
