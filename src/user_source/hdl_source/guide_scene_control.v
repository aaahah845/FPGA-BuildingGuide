`include "map_navigation.v"
`include "direction_key_event.v"
`include "guide_nav_buttons.v"
`include "site_point_memory.v"
`include "room_elapsed_store.v"
`timescale 1ns / 1ps
// The debouncer is defined by guide_key_control.v, included by the top.
// ============================================================================
// 【说明】guide_scene_control：交互控制器（video_clk）
//
// 作用：把按键与拨码解释成“用户想看什么”，不负责加载图片。
// 输入：板载 KEY1~4、外接五向模块（方向与板载并联，MID/SET/RST 另行消抖）、
//       SW1~4；map_entry_ready/map_available 等下游就绪反馈；
//       photo_view_active 覆盖大图显示及退出淡出全过程。
// 输出（电平，持续有效）：floor_idx、selected_room_idx、map_mode、detail_requested、
//       参数面板状态、地图视野 map_view/map_scale；
//       （单拍脉冲）next_pulse 下一张轮播、auto_toggle_pulse 切换自动轮播、settings_event。
//
// 状态：PAGE 页面选择 / ROOM 房间选择 / FLOOR 楼层选择 / POINT 观察点 / PAN 平移。
// 按键优先级：SW1 面板 > SW3 返回 > 面板内操作 > 各状态普通操作，
// 所以加载过程中仍可返回或开关面板。
// 方向键短按在松开时生效，长按 800 ms 触发一次；context_changed 会作废
// 尚未松开的旧手势（cancel_keys），防止它在新页面松手时被当成新操作。
// 长按左：索引页切换自动轮播，地图上切换观察点/平移状态；与 SW2 共用分支。
// 进入地图时若地图尚未缓存，置 map_entry_pending 等待 broker 的 map_entry_ready。
// 详情面板展开后再次确认锁存大图请求；返回只撤销大图请求，待淡出结束
// 才恢复详情操作。大图期间方向/占用手势无效，参数面板仍可独立操作。
// ============================================================================
// region 01 接口
module guide_scene_control #(
    parameter integer RUNTIME_CONFIG = 0,
    parameter integer DEFER_MAP_ENTRY = 0,
    parameter integer EXTERNAL_NAV = 0,
    parameter integer CLK_FREQ_HZ = 25_000_000,
    parameter integer DEBOUNCE_MS = 10,
    parameter integer LONG_PRESS_MS = 800
) (
    input wire clk, rst, frame_request,
    input cfg_we,
    input [12:0] cfg_addr,
    input [7:0] cfg_data,
    input wire key_next_n, key_floor_n, key_room_n, key_auto_occ_n,
    input wire [3:0] switches,
    input wire [6:0] nav_keys_n,  // right,left,down,up,MID,SET,RST; active low
    input wire panel_active,
    input wire photo_view_active,
    input wire map_entry_ready,
    output reg map_entry_pending,
    input wire [1:0] display_floor_idx,
    input wire [3:0] display_room_idx,
    output reg [1:0] floor_idx,
    output wire floor_selecting,
    output reg [1:0] floor_cursor,
    output wire nearest_room_valid,
    output wire [3:0] nearest_room_idx,
    output reg [3:0] selected_room_idx,
    output reg [29:0] room_occupied,
    output reg detail_requested,
    output wire selection_visible,
    output wire [2:0] control_state,
    output wire [1:0] period_select,
    output wire [15:0] selected_elapsed_bcd,
    output reg next_pulse, auto_toggle_pulse,
    output reg map_mode,
    output wire map_zoom,
    output wire pan_mode,
    output wire [8:0] map_x,
    output wire [7:0] map_y,
    input map_available,
    input [10:0] map_width,
    input [9:0] map_height,
    output [36:0] map_view,
    output [13:0] map_scale,
    output [1:0] map_level,
    output [11:0] map_target_x2,
    output [10:0] map_target_y2,
    output reg photo_full_requested,
    output reg bilinear_enabled,
    output reg settings_open, spectrum_enabled, music_enabled,
    output reg [1:0] settings_field,
    output reg [3:0] brightness, volume,
    output reg [1:0] settings_event
);
    // endregion

    // region 02 配置、模式和按键事件
    `include "guide_site_config.vh"
    wire rt_clk = clk;
    `include "runtime_site_fields.vh"

    localparam PAGE = 3'd0, ROOM = 3'd1, FLOOR = 3'd2, POINT = 3'd3, PAN = 3'd4;
    reg [2:0] state;
    assign control_state = state;
    assign floor_selecting = state == FLOOR;
    assign selection_visible = state == ROOM || state == POINT || state == PAN;
    assign pan_mode = map_mode && state == PAN;
    assign period_select = cfg_period;
    wire [3:0] sw_stable;
    reg [3:0] sw_previous;
    reg switches_ready;
    // endregion

    // region 03 共享消抖节拍与外接按键
    localparam BOOT_CYCLES = (CLK_FREQ_HZ / 1000) * (DEBOUNCE_MS + 2) + 8;
    reg [$clog2(BOOT_CYCLES+1)-1:0] boot_count;
    wire [3:0] nav_events;
    wire input_ms_tick;
    // Human input counters share a 1 ms timebase in the external-navigation build.
    // Continuous synchronizers and per-contact disagreement resets still run at
    // clk; only elapsed-time counters are divided. Legacy instances remain exact.
    localparam INPUT_MS_CYCLES = CLK_FREQ_HZ / 1000 > 0 ? CLK_FREQ_HZ / 1000 : 1;
    localparam INPUT_MS_BITS   = INPUT_MS_CYCLES > 1 ? $clog2(INPUT_MS_CYCLES) : 1;
    generate
        if (EXTERNAL_NAV) begin : external_nav
            reg [INPUT_MS_BITS-1:0] ms_count;
            assign input_ms_tick = ms_count == INPUT_MS_CYCLES - 1;
            always @(posedge clk or posedge rst)
                if (rst) ms_count <= 0;
                else ms_count <= input_ms_tick ? 0 : ms_count + 1'b1;
            guide_nav_buttons #(
                .CLK_FREQ_HZ(CLK_FREQ_HZ),
                .DEBOUNCE_MS(DEBOUNCE_MS),
                .USE_MS_TICK(1)
            ) buttons (
                .clk(clk),
                .rst(rst),
                .enable(switches_ready),
                .ms_tick(input_ms_tick),
                .buttons_n(nav_keys_n[6:4]),
                .events(nav_events)
            );
        end else begin : no_external_nav
            assign nav_events = 4'b0;
            assign input_ms_tick = 1'b0;
        end
    endgenerate
    wire [3:0] sw_event = switches_ready ? ((sw_stable ^ sw_previous) | nav_events) : 4'd0;
    genvar i;
    generate
        for (i = 0; i < 4; i = i + 1) begin : sw_filter
            guide_button_debounce #(
                .CLK_FREQ_HZ(CLK_FREQ_HZ),
                .DEBOUNCE_MS(DEBOUNCE_MS),
                .USE_MS_TICK(EXTERNAL_NAV)
            ) db (
                .clk(clk),
                .rst(rst),
                .button_n(~switches[i]),
                .ms_tick(input_ms_tick),
                .pressed(sw_stable[i]),
                .press_pulse(),
                .release_pulse()
            );
        end
    endgenerate
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            sw_previous <= 0;
            switches_ready <= 0;
            boot_count <= 0;
        end else begin
            sw_previous <= sw_stable;
            if (!switches_ready) begin
                if (boot_count >= BOOT_CYCLES - 1) switches_ready <= 1;
                else boot_count <= boot_count + 1'b1;
            end
        end
    end
    wire [3:0] short_key, long_key, held;
    wire [3:0] keys = {key_auto_occ_n, key_room_n, key_floor_n, key_next_n} &
        (EXTERNAL_NAV ? nav_keys_n[3:0] : 4'hf);
    reg context_changed;
    // The request covers the cycles before the broker accepts the view; feedback
    // keeps the same input context locked until the return fade has completed.
    wire photo_view_busy = photo_full_requested || photo_view_active;
    wire cancel_keys = !switches_ready || (|sw_event) || context_changed ||
        (photo_view_busy && !settings_open) || (panel_active && !detail_requested && !settings_open);
    generate
        for (i = 0; i < 4; i = i + 1) begin : key_filter
            direction_key_event #(
                .CLK_FREQ_HZ(CLK_FREQ_HZ),
                .DEBOUNCE_MS(DEBOUNCE_MS),
                .LONG_PRESS_MS(LONG_PRESS_MS),
                .LONG_ENABLE(1),  // 左键也区分长短按，长按松手不再补发下一张/平移
                .USE_MS_TICK(EXTERNAL_NAV)
            ) gesture (
                .clk(clk),
                .rst(rst),
                .button_n(keys[i]),
                .ms_tick(input_ms_tick),
                .cancel(cancel_keys),
                .short_event(short_key[i]),
                .long_event(long_key[i]),
                .held(held[i])
            );
        end
    endgenerate
    wire right_key = short_key[0], left_key = short_key[1], down_key = short_key[2], up_key = short_key[3];
    // 长按左只在有对应操作的页面生效；面板和详情仍由下方统一优先级屏蔽。
    // 复用 SW2 分支，让两种输入采用相同的状态更新和旧手势取消规则。
    wire left_mode_toggle = long_key[1] &&
        ((map_mode && (state == POINT || state == PAN)) || (!map_mode && (state == PAGE || state == ROOM)));
    wire mode_toggle_event = sw_event[1] || left_mode_toggle;
    wire can_enter_map = !DEFER_MAP_ENTRY || map_entry_ready;
    // endregion

    // region 04 交互上下文与地图进入等待
    reg pending_point;
    reg nav_focus, nav_zoom, nav_reset;
    wire [3:0] nav_point_index, nav_room;
    wire nav_select;
    wire [13:0] nav_step;
    wire [4:0] nav_point_id = floor_idx * 5'd10 + nav_point_index;
    wire [3:0] nav_room_count = RUNTIME_CONFIG ? rt_counts[floor_idx] : site_room_count(floor_idx);
    wire [9:0] nav_point_x, nav_point_y;
    wire [11:0] nav_cx;
    wire [10:0] nav_cy;
    wire nav_allowed = map_mode && !detail_requested && !settings_open && !panel_active && !photo_view_busy;
    site_point_memory nav_points (
        .clk(clk),
        .cfg_we(cfg_we),
        .cfg_addr(cfg_addr),
        .cfg_data(cfg_data),
        .read_index(nav_point_id),
        .point_x(nav_point_x),
        .point_y(nav_point_y)
    );
    map_navigation u_map_navigation (
        .clk(clk),
        .rst(rst),
        .available(map_available),
        .width(map_width),
        .height(map_height),
        .frame_request(frame_request && nav_allowed && display_floor_idx == floor_idx &&
                       display_room_idx == selected_room_idx),
        .floor_id(floor_idx),
        .room_count(nav_room_count),
        .point_index(nav_point_index),
        .point_x(nav_point_x),
        .point_y(nav_point_y),
        .zoom_press(nav_zoom),
        .zoom_reset(nav_reset),
        .left_press(left_key && pan_mode && nav_allowed),
        .right_press(right_key && pan_mode && nav_allowed),
        .up_press((up_key || long_key[3]) && pan_mode && nav_allowed),
        .down_press((down_key || long_key[2]) && pan_mode && nav_allowed),
        .focus_press(nav_focus),
        .selected_room(selected_room_idx),
        .level(map_level),
        .step(nav_step),
        .scale(map_scale),
        .center_x2(nav_cx),
        .center_y2(nav_cy),
        .select_valid(nav_select),
        .select_room(nav_room),
        .target_x2(map_target_x2),
        .target_y2(map_target_y2),
        .nearest_valid(nearest_room_valid),
        .nearest_room(nearest_room_idx)
    );
    assign map_zoom = map_level != 0;
    assign map_view = {nav_step, nav_cx, nav_cy};
    assign map_x = 0;
    assign map_y = 0;
    wire [4:0] room_number = floor_idx * 5'd10 + selected_room_idx;
    wire [4:0] elapsed_room = RUNTIME_CONFIG ? (display_floor_idx * 5'd10 + display_room_idx) : room_number;
    localparam SHARE_SECOND  = EXTERNAL_NAV && CLK_FREQ_HZ >= 1000 && CLK_FREQ_HZ % 1000 == 0;
    localparam SECOND_COUNTS = SHARE_SECOND ? 1000 : CLK_FREQ_HZ;
    reg [$clog2(SECOND_COUNTS+1)-1:0] second_count;
    // At the board's integer-MHz clock this produces the same one-second pulse,
    // using the existing millisecond divider rather than another 26-bit counter.
    wire second_advance = !SHARE_SECOND || input_ms_tick;
    wire second_tick = second_advance && second_count >= SECOND_COUNTS - 1;
    wire occupancy_toggle = !sw_event[0] && !sw_event[2] && !settings_open && !photo_view_busy &&
        long_key[2] && selection_visible && state != PAN && (detail_requested || !panel_active);
    room_elapsed_store elapsed_store (
        .clk(clk),
        .rst(rst),
        .second_tick(second_tick),
        .occupied(room_occupied),
        .clear_valid(occupancy_toggle),
        .clear_room(room_number),
        .read_room(elapsed_room),
        .elapsed(selected_elapsed_bcd)
    );
    // endregion

    // region 05 交互状态和按键优先级
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= PAGE;
            floor_idx <= 0;
            floor_cursor <= 0;
            selected_room_idx <= 0;
            room_occupied <= 0;
            detail_requested <= 0;
            map_mode <= 0;
            map_entry_pending <= 0;
            pending_point <= 0;
            context_changed <= 0;
            nav_focus <= 0;
            nav_zoom <= 0;
            nav_reset <= 0;
            bilinear_enabled <= 0;
            settings_open <= 0;
            settings_field <= 0;
            spectrum_enabled <= 1;
            music_enabled <= 0;
            brightness <= 8;
            volume <= 8;
            settings_event <= 0;
            next_pulse <= 0;
            auto_toggle_pulse <= 0;
            photo_full_requested <= 0;
            second_count <= 0;
        end else begin
            context_changed <= 0;
            nav_focus <= 0;
            nav_zoom <= 0;
            nav_reset <= 0;
            settings_event <= 0;
            next_pulse <= 0;
            auto_toggle_pulse <= 0;
            if (state != FLOOR) floor_cursor <= floor_idx;
            if (second_tick) second_count <= 0;
            else if (second_advance) second_count <= second_count + 1'b1;
            // Global overlays and return take precedence even while an image is loading.
            if (sw_event[0]) begin
                settings_open <= !settings_open;
                settings_event <= 2;
                context_changed <= 1;
            end else if (sw_event[2]) begin
                context_changed <= 1;
                if (settings_open) begin
                    settings_open <= 0;
                    settings_event <= 2;
                end else if (photo_view_busy) begin
                    // Keep detail_requested and its selected room unchanged.
                    // Repeated returns during fade-out must not close the detail.
                    photo_full_requested <= 0;
                end else if (detail_requested) detail_requested <= 0;
                else if (state == PAN) state <= POINT;
                else begin
                    state <= PAGE;
                    selected_room_idx <= 0;
                    floor_cursor <= floor_idx;
                    map_entry_pending <= 0;
                    pending_point <= 0;
                    nav_reset <= 1;
                end
            end else if (settings_open) begin
                if (sw_event[3]) begin
                    bilinear_enabled <= !bilinear_enabled;
                    settings_event <= 1;
                    context_changed <= 1;
                end else if (up_key || long_key[3]) begin
                    settings_field <= settings_field - 1'b1;
                    settings_event <= 1;
                end else if (down_key || long_key[2]) begin
                    settings_field <= settings_field + 1'b1;
                    settings_event <= 1;
                end else if (left_key || right_key || long_key[0]) begin
                    settings_event <= 1;
                    case (settings_field)
                        0:
                        if (left_key) begin
                            if (brightness > 2) brightness <= brightness - 1'b1;
                            else settings_event <= 3;
                        end else begin
                            if (brightness < 8) brightness <= brightness + 1'b1;
                            else settings_event <= 3;
                        end
                        1:
                        if (left_key) begin
                            if (volume > 0) volume <= volume - 1'b1;
                            else settings_event <= 3;
                        end else begin
                            if (volume < 8) volume <= volume + 1'b1;
                            else settings_event <= 3;
                        end
                        2: spectrum_enabled <= !spectrum_enabled;
                        3: music_enabled <= !music_enabled;
                    endcase
                end
            end else if (!photo_view_busy) begin
                if (occupancy_toggle) begin
                    room_occupied[room_number] <= ~room_occupied[room_number];
                end
                if (sw_event[3] && detail_requested && panel_active) begin
                    photo_full_requested <= 1;
                    context_changed <= 1;
                end else if (!detail_requested && !panel_active) begin
                    // Pan mode owns automatic selection. Point mode keeps an explicit choice,
                    // even while the viewport is still easing toward that point.
                    if (state == PAN && nav_allowed && nearest_room_valid && display_floor_idx == floor_idx)
                        selected_room_idx <= nearest_room_idx;
                    if (map_entry_pending && can_enter_map) begin
                        map_mode <= 1;
                        map_entry_pending <= 0;
                        state <= pending_point ? POINT : PAGE;
                        nav_focus <= pending_point;
                        context_changed <= 1;
                    end
                    if (mode_toggle_event) begin
                        context_changed <= 1;
                        if (state == POINT) state <= PAN;
                        else if (state == PAN) state <= POINT;
                        else auto_toggle_pulse <= 1;
                    end else if (sw_event[3]) begin
                        context_changed <= 1;
                        if (state == FLOOR) begin
                            floor_idx <= floor_cursor;
                            if (floor_cursor != floor_idx) selected_room_idx <= 0;
                        end else if (selection_visible) detail_requested <= 1;
                    end else
                        case (state)
                            PAGE: begin
                                if (up_key) begin
                                    selected_room_idx <= 0;
                                    state <= map_mode ? FLOOR : ROOM;
                                    floor_cursor <= floor_idx;
                                    context_changed <= 1;
                                end else if (right_key && !map_mode) begin
                                    if (can_enter_map) begin
                                        map_mode <= 1;
                                        state <= PAGE;
                                    end else begin
                                        map_entry_pending <= 1;
                                        pending_point <= 0;
                                    end
                                    context_changed <= 1;
                                end else if (left_key) begin
                                    if (map_mode) begin
                                        map_mode <= 0;
                                        state <= PAGE;
                                        selected_room_idx <= 0;
                                        context_changed <= 1;
                                    end else next_pulse <= 1;
                                end
                            end
                            ROOM: begin
                                if (long_key[3]) begin
                                    floor_idx <= floor_idx == cfg_floors - 1 ? 0 : floor_idx + 1'b1;
                                    selected_room_idx <= 0;
                                    context_changed <= 1;
                                end else if (down_key)
                                    selected_room_idx <= selected_room_idx == cfg_room_count(
                                        floor_idx
                                    ) - 1 ? 0 : selected_room_idx + 1'b1;
                                else if (left_key) next_pulse <= 1;
                                else if (right_key) begin
                                    if (can_enter_map) begin
                                        map_mode <= 1;
                                        state <= POINT;
                                        nav_focus <= 1;
                                    end else begin
                                        map_entry_pending <= 1;
                                        pending_point <= 1;
                                    end
                                    context_changed <= 1;
                                end
                            end
                            FLOOR: begin
                                if (up_key || long_key[3])
                                    floor_cursor <= floor_cursor == cfg_floors - 1 ? 0 : floor_cursor + 1'b1;
                                else if (left_key) begin
                                    state <= POINT;
                                    selected_room_idx <= 0;
                                    nav_focus <= 1;
                                    context_changed <= 1;
                                end
                            end
                            POINT: begin
                                if (long_key[0]) nav_zoom <= 1;
                                else if (right_key) begin
                                    selected_room_idx <= selected_room_idx == cfg_room_count(
                                        floor_idx
                                    ) - 1 ? 0 : selected_room_idx + 1'b1;
                                    nav_focus <= 1;
                                end
                            end
                            PAN: if (long_key[0]) nav_zoom <= 1;
                            default: state <= PAGE;
                        endcase
                end
            end
        end
    end
    // endregion

endmodule
