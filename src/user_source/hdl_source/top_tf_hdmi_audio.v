// ============================================================================
// top：楼宇多媒体导览系统顶层（文件名 top_tf_hdmi_audio.v，模块名 top）
//
// 时钟域（板载 50 MHz → 两个 PLL，VCO 均为 1 GHz）
//   clk          50 MHz   上电复位计数、数码管诊断
//   sd_card_clk  50 MHz   SD 卡 / FAT32 / BMP / WAV、资源管理器 sd_site_assets
//   ext_mem_clk  100 MHz  SDRAM 控制器、写入 frame_fifo_write、读图 scene_frame_reader
//   ext_mem_clk_sft 100 MHz 相移 180°，送 SDRAM 硬核时钟
//   video_clk    40 MHz   按键与交互、调度器 broker、合成、叠加、音频输出
//   hdmi_5x_clk  200 MHz  TMDS 10:1 串行（DDR）
//
// 四条主链路（括号内为所在时钟域）
//   控制：按键 → guide_scene_control → site_scene_broker（40M）
//         → 请求/应答/裁决邮箱 → sd_site_assets（50M）
//   资源：sd_site_assets → FAT32 → BMP → 写 FIFO → frame_fifo_write → SDRAM（100M）
//   像素：scene_frame_reader（100M）→ 读 FIFO → video_delay → 合成器
//         → ui_viewport_800 → 频谱叠加 → 参数面板 → AXIS → HDMI IP → PHY（40M/200M）
//   音频：事件 → 邮箱 → sd_dual_audio 读 WAV（50M）→ 混音页 → 输出混音 → HDMI（40M）
//
// 显示 800×600@约 60.32 Hz（40 MHz ÷ 1056 ÷ 628）。SDRAM 2M×32，分 6 个图像槽，
// 每槽 307200 字（640×480），楼层大地图可占两个不相邻的槽。
// 阅读入口：先看下方时钟/复位，再沿交互、调度、资源、像素与音频链路查看例化。
// ============================================================================
`include "hdmi_event_audio.v"
`include "audio_event_mailbox.v"
`include "audio_output_mixer.v"
`include "ui_settings_overlay.v"
`include "audio_spectrum_overlay.v"
`include "ui_operation_events.v"
`include "av_scene_events.v"
`include "guide_key_control.v"  // 只用到其中的 guide_button_debounce
`include "floor_guide_compositor.v"  // 旧版合成器，当前未例化（历史遗留）
`include "cdc_sync.v"
`include "guide_scene_control.v"
`include "guide_scene_compositor.v"
`include "site_scene_broker.v"
`include "held_bus_cdc.v"
`include "ui_viewport_800.v"
`include "SD/sd_site_assets.v"

// region 01 顶层接口与链路信号
module top (
    input clk,
    input key_next_n,  // KEY1 A2: right / long zoom
    input key_floor_n,  // KEY2 B2: left / index next slide
    input key_room_n,  // KEY3 B1: down / long occupancy
    input key_auto_occ_n,  // KEY4 C1: up / long next floor
    input [6:0] nav_keys_n,  // external 5-way + SET/RST contacts
    input [3:0] switches,  // SW1 settings, SW2 autoplay/pan mode, SW3 return, SW4 confirm
    output [5:0] seg_sel,
    output [7:0] seg_data,
    // HDMI TMDS
    output HDMI_CLK_P,
    output HDMI_D2_P,
    output HDMI_D1_P,
    output HDMI_D0_P,
    // HDMI DDC
    output HDMI_DDC_SCL,
    inout HDMI_DDC_SDA,
    // TF card SPI
    output sd_ncs,
    output sd_dclk,
    output sd_mosi,
    input sd_miso
);

    parameter MEM_DATA_BITS = 32;
    parameter ADDR_BITS = 21;
    // UNUSED_BURST_BITS（原名 BUSRT_BITS）未被使用，突发长度由 frame_read_write 默认参数（256）决定。
    parameter UNUSED_BURST_BITS = 10;
    // 以下三项来自早期双缓冲方案。SLOT_WORDS（原名 FRAME_PIXELS）表示“一个槽的字数”
    // 及 read_len 端口的占位值；实际读图地址由 scene_frame_reader 按槽号计算。
    parameter SLOT_WORDS = 24'd307200;  // 一个槽 = 640×480 个 32 位字
    parameter BUF0_ADDR = 24'd0;
    parameter BUF1_ADDR = SLOT_WORDS;

    wire Sdr_init_done;
    wire Sdr_init_ref_vld;
    wire Sdr_busy;

    wire sd_card_clk;
    wire ext_mem_clk;
    wire ext_mem_clk_sft;
    wire video_clk;
    wire hdmi_5x_clk;

    wire hs;
    wire vs;
    wire de;

    wire [23:0] vout_data_raw;
    wire [23:0] vout_data;
    wire legacy_display_valid;

    // composited_*：合成器输出，已叠加列表/地图/详情/文字的像素流。
    wire [23:0] composited_rgb;
    wire composited_hs;
    wire composited_vs;
    wire composited_de;

    wire [1:0] guide_floor_idx;
    wire floor_selecting;
    wire [1:0] floor_cursor;
    wire nearest_room_valid;
    wire [3:0] nearest_room_idx;
    wire [3:0] guide_selected_room_idx;
    wire [29:0] guide_room_occupied;
    wire guide_auto_toggle_video;
    wire guide_next_video, guide_next_sd;
    wire detail_requested, panel_active, photo_full_requested;
    wire [3:0] legacy_resident_mask_sd;
    reg [3:0] legacy_resident_mask_meta, legacy_resident_mask_video;
    wire [12:0] scene_motion;
    wire transition_busy;
    wire scene_ready, scene_full;
    wire photo_view_active;
    wire [4:0] photo_view_alpha;
    wire photo_blend = photo_view_alpha != 0 && photo_view_alpha != 16;
    wire [31:0] video_pixel_packet;
    wire reader_full_applied_mem;
    (* ASYNC_REG="TRUE" *) reg [1:0] reader_full_sync_video;
    wire slide_anim;
    wire [4:0] slide_phase;
    wire [2:0] slide_old;
    wire [36:0] requested_map_view, scene_map_view;
    wire [13:0] requested_map_scale, scene_map_scale;
    wire [1:0] map_level;
    wire [11:0] map_target_x2;
    wire [10:0] map_target_y2;
    wire [12:0] carousel_progress;
    wire map_requested, zoom_requested, pan_requested, scene_map, scene_zoom, scene_pan;
    wire [8:0] map_origin_x, scene_map_x;
    wire [7:0] map_origin_y, scene_map_y;
    wire [2:0] scene_map_slot;
    wire [7:0] scene_panel_height;
    wire [2:0] scene_slide, scene_bg, scene_photo;
    wire [1:0] scene_floor;
    wire [3:0] scene_room;
    wire reader_fault;
    wire [1:0] period_select_video;
    wire [15:0] selected_elapsed_bcd;
    wire view_pause_video = detail_requested || panel_active || map_requested;
    (* ASYNC_REG = "TRUE" *) reg [1:0] view_pause_sync_sd;
    (* ASYNC_REG = "TRUE" *) reg [1:0] period_meta_sd, period_sync_sd;
    wire [2:0] applied_buf_idx_mem;
    wire applied_buf_valid_mem;
    (* ASYNC_REG = "TRUE" *) reg [2:0] applied_idx_meta_sd, applied_idx_sync_sd;
    (* ASYNC_REG = "TRUE" *) reg [1:0] applied_valid_sync_sd;
    wire view_settled_sd;
    (* ASYNC_REG = "TRUE" *) reg [1:0] view_settled_sync_video;
    (* ASYNC_REG = "TRUE" *) reg [1:0] display_valid_sync_video;
    wire guide_auto_toggle_sd;
    wire auto_play_active_sd;
    reg [1:0] auto_play_active_sync_video;
    wire auto_play_active_video;
    wire [1:0] displayed_image_idx_sd;
    reg [1:0] displayed_image_idx_meta_video;
    reg [1:0] displayed_image_idx_sync_video;
    wire [1:0] displayed_image_idx_video;

    wire [3:0] asset_error_code;
    wire [6:0] seg_data_0;

    wire video_read_req;
    wire video_read_req_ack;
    (* ASYNC_REG="TRUE" *) reg [1:0] video_ack_sync;
    (* ASYNC_REG="TRUE" *) reg [1:0] reader_fault_sync;
    wire video_read_en;
    wire [31:0] video_read_data;

    wire sd_card_write_en;
    wire [31:0] sd_card_write_data;
    wire sd_card_write_req;
    wire sd_card_write_req_ack_mem;
    reg sd_card_write_req_ack_mem_d;
    wire sd_card_write_ack_rise_mem;
    wire sd_card_write_ack_pulse_sd;
    wire frame_write_finish;
    wire frame_write_finish_pulse_sd;
    wire frame_write_abort_sd;
    wire frame_write_abort_mem;
    wire frame_write_abort_done_sd;
    wire [8:0] frame_write_fifo_used;

    wire [2:0] write_buf_idx, write_tail_idx;
    wire [17:0] asset_tails;
    wire [2:0] legacy_read_index;

    wire App_rd_en;
    wire [ADDR_BITS-1:0] App_rd_addr;
    wire Sdr_rd_en;
    wire [MEM_DATA_BITS-1:0] Sdr_rd_dout;
    wire App_wr_en;
    wire [ADDR_BITS-1:0] App_wr_addr;
    wire [MEM_DATA_BITS-1:0] App_wr_din;
    wire [3:0] App_wr_dm;

    wire hs_0;
    wire vs_0;
    wire de_0;

    // HDMI 1.4b 相关
    wire axis_s_user;
    wire axis_s_valid;
    wire axis_s_last;
    wire [23:0] axis_s_data;
    wire axis_s_ready;

    wire edid_trig;
    wire edid_valid;
    wire [7:0] edid_data;

    wire [9:0] tmds_ch0_data;
    wire [9:0] tmds_ch1_data;
    wire [9:0] tmds_ch2_data;
    wire [9:0] tmds_clk_data;

    // endregion

    // region 02 复位
    // ===================== 复位 =====================
    // 只有上电复位：两个 PLL 都锁定并连续稳定 20 ms 后释放 rst_all，
    // 再由 reset_sync 在每个时钟域内“异步置位、同步释放”。没有手动复位键。
    wire sys_pll_lock;
    wire video_pll_lock;
    wire rst_all;
    wire rst_sd;
    wire rst_mem;
    wire rst_video;
    wire rst_video_root;
    wire rst_video_control, rst_video_scene, rst_video_draw;
    wire rst_video_overlays, rst_video_audio, rst_video_output;
    // 视频域复位拆成 7 个独立寄存器（preserve 防止被合并），分别驱动控制、调度、
    // 绘制、叠加、音频、输出等模块组，降低单个复位网络的扇出；7 路在同一拍释放。
    wire [6:0] video_reset_leaf;
    reset_release_leaf #(
        .WIDTH(7)
    ) u_video_reset_leaves (
        .clk(video_clk),
        .reset_in(rst_video_root),
        .reset_out(video_reset_leaf)
    );
    assign rst_video = video_reset_leaf[0];
    assign rst_video_control = video_reset_leaf[1];
    assign rst_video_scene = video_reset_leaf[2];
    assign rst_video_draw = video_reset_leaf[3];
    assign rst_video_overlays = video_reset_leaf[4];
    assign rst_video_audio = video_reset_leaf[5];
    assign rst_video_output = video_reset_leaf[6];
    wire rst_hdmi;

    reg [19:0] rst_cnt = 20'd0;
    (* max_fanout = 8 *) reg rst_all_reg = 1'b1;

    // 上电复位计数（clk = 50 MHz）。SW4 早期曾用作复位，现在只是“确认”键。
    always @(posedge clk) begin
        if (!rst_all_reg) begin
            // 一旦复位释放，忽略后续微小的 PLL 抖动，防止系统在使用时随机复位
            rst_all_reg <= 1'b0;
        end else if (sys_pll_lock && video_pll_lock) begin
            // 等待 PLL 连续稳定 20ms @ 50MHz
            if (rst_cnt < 20'd1_000_000) begin
                rst_cnt <= rst_cnt + 1'b1;
                rst_all_reg <= 1'b1;
            end else begin
                rst_all_reg <= 1'b0;
            end
        end else begin
            rst_cnt <= 20'd0;
            rst_all_reg <= 1'b1;
        end
    end

    assign rst_all = rst_all_reg;

    assign displayed_image_idx_video = displayed_image_idx_sync_video;
    assign sd_card_write_ack_rise_mem = sd_card_write_req_ack_mem && !sd_card_write_req_ack_mem_d;

    // endregion

    // region 03 时钟
    // ===================== 时钟 =====================
    // sys_pll：clkc0=50 MHz（SD），clkc1=100 MHz（存储），clkc2=100 MHz 相移 180°（SDRAM 硬核时钟）
    // video_pll：clkc2=40 MHz（像素），clkc1=200 MHz（TMDS 串行），clkc0=25 MHz 仅作反馈
    sys_pll sys_pll_m0 (
        .refclk(clk),
        .reset(1'b0),
        .extlock(sys_pll_lock),
        .clk0_out(sd_card_clk),
        .clk1_out(ext_mem_clk),
        .clk2_out(ext_mem_clk_sft)
    );

    video_pll video_pll_m0 (
        .refclk(clk),
        .reset(1'b0),
        .extlock(video_pll_lock),
        .clk0_out(video_clk),
        .clk1_out(hdmi_5x_clk)
    );

    reset_sync u_reset_sd (
        .clk(sd_card_clk),
        .async_reset(rst_all),
        .reset_out(rst_sd)
    );

    reset_sync u_reset_mem (
        .clk(ext_mem_clk),
        .async_reset(rst_all),
        .reset_out(rst_mem)
    );

    reset_sync u_reset_video (
        .clk(video_clk),
        .async_reset(rst_all),
        .reset_out(rst_video_root)
    );

    reset_sync u_reset_hdmi (
        .clk(hdmi_5x_clk),
        .async_reset(rst_all),
        .reset_out(rst_hdmi)
    );

    // 运行配置分发（SITE.CFG → 各模块）与 broker ↔ 资源管理器的跨域邮箱，
    // 连线较多，单独放在 site_runtime_wiring.vh 中，在此原地展开。
    `include "site_runtime_wiring.vh"
    // endregion

    // region 04 交互控制（video_clk）
    // ===================== 交互控制（video_clk） =====================
    // guide_scene_control 把按键解释为“想看什么”：页面、楼层、房间/观察点、
    // 详情、参数面板与地图视野。它不直接加载图片，只把意图交给 broker。
    wire [2:0] cached_maps_sd;
    (* ASYNC_REG="TRUE" *) reg [2:0] cached_maps_meta, cached_maps_video;
    wire map_entry_ready, map_entry_pending, map_loading;
    always @(posedge video_clk or posedge rst_video)
        if (rst_video) begin
            cached_maps_meta <= 0;
            cached_maps_video <= 0;
        end else begin
            cached_maps_meta <= cached_maps_sd;
            cached_maps_video <= cached_maps_meta;
        end
    wire bilinear_enabled;
    wire settings_open, spectrum_enabled, music_enabled;
    wire [1:0] settings_field;
    wire selection_visible;
    wire [2:0] control_state;
    wire [3:0] sd_audio_event;
    wire [1:0] sd_audio_fallback, audio_fallback_video;
    wire [3:0] sd_audio_error;
    wire sd_audio_available;
    wire [15:0] sd_audio_sample;
    wire audio_sample_tick, audio_acr_tick;
    wire [23:0] tone_left, tone_right;
    (* ASYNC_REG="TRUE" *) reg [1:0] music_sync_sd;
    (* ASYNC_REG="TRUE" *) reg audio_error_meta, audio_error_sync;
    always @(posedge sd_card_clk or posedge rst_sd)
        if (rst_sd) music_sync_sd <= 0;
        else music_sync_sd <= {music_sync_sd[0], music_enabled};
    always @(posedge video_clk or posedge rst_video)
        if (rst_video) begin
            audio_error_meta <= 0;
            audio_error_sync <= 0;
        end else begin
            audio_error_meta <= |sd_audio_error;
            audio_error_sync <= audio_error_meta;
        end
    wire [3:0] ui_brightness, ui_volume;
    wire [1:0] settings_event, operation_event;
    reg [20:0] map_geometry_meta, map_geometry_sync;
    always @(posedge video_clk or posedge rst_video)
        if (rst_video) begin
            map_geometry_meta <= {11'd640, 10'd480};
            map_geometry_sync <= {11'd640, 10'd480};
        end else begin
            map_geometry_meta <= {asset_widths[scene_map_slot*11+:11], asset_heights[scene_map_slot*10+:10]};
            map_geometry_sync <= map_geometry_meta;
        end

    guide_scene_control #(
        .EXTERNAL_NAV(1),
        .RUNTIME_CONFIG(1),
        .DEFER_MAP_ENTRY(1),
        .CLK_FREQ_HZ(40_000_000),
        .DEBOUNCE_MS(10),
        .LONG_PRESS_MS(800)
    ) u_guide_scene_control (
        .clk(video_clk),
        .rst(rst_video_control | !site_ready),
        .frame_request(video_read_req),
        .map_target_x2(map_target_x2),
        .map_target_y2(map_target_y2),
        .cfg_we(cfg_we),
        .cfg_addr(cfg_addr),
        .cfg_data(cfg_data),
        .nav_keys_n(nav_keys_n),
        .key_next_n(key_next_n),
        .key_floor_n(key_floor_n),
        .key_room_n(key_room_n),
        .key_auto_occ_n(key_auto_occ_n),
        .map_entry_pending(map_entry_pending),
        .map_entry_ready(map_entry_ready),
        .switches(switches),
        .panel_active(panel_active || transition_busy),
        .photo_view_active(photo_view_active),
        .floor_idx(guide_floor_idx),
        .selected_room_idx(guide_selected_room_idx),
        .floor_selecting(floor_selecting),
        .floor_cursor(floor_cursor),
        .selection_visible(selection_visible),
        .control_state(control_state),
        .nearest_room_valid(nearest_room_valid),
        .nearest_room_idx(nearest_room_idx),
        .room_occupied(guide_room_occupied),
        .detail_requested(detail_requested),
        .period_select(period_select_video),
        .selected_elapsed_bcd(selected_elapsed_bcd),
        .display_floor_idx(scene_floor),
        .display_room_idx(scene_room),
        .photo_full_requested(photo_full_requested),
        .settings_open(settings_open),
        .settings_field(settings_field),
        .spectrum_enabled(spectrum_enabled),
        .music_enabled(music_enabled),
        .bilinear_enabled(bilinear_enabled),
        .brightness(ui_brightness),
        .volume(ui_volume),
        .settings_event(settings_event),
        .map_available(scene_ready && scene_map && scene_floor == guide_floor_idx),
        .map_width(map_geometry_sync[20:10]),
        .map_height(map_geometry_sync[9:0]),
        .map_view(requested_map_view),
        .map_scale(requested_map_scale),
        .map_level(map_level),
        .map_mode(map_requested),
        .map_zoom(zoom_requested),
        .pan_mode(pan_requested),
        .map_x(map_origin_x),
        .map_y(map_origin_y),
        .next_pulse(guide_next_video),
        .auto_toggle_pulse(guide_auto_toggle_video)
    );
    always @(posedge video_clk or posedge rst_video) begin
        if (rst_video) begin
            video_ack_sync <= 0;
            reader_full_sync_video <= 0;
        end else begin
            video_ack_sync <= {video_ack_sync[0], video_read_req_ack};
            reader_full_sync_video <= {reader_full_sync_video[0], reader_full_applied_mem};
        end
    end
    always @(posedge clk or posedge rst_all) begin
        if (rst_all) reader_fault_sync <= 0;
        else reader_fault_sync <= {reader_fault_sync[0], reader_fault};
    end
    always @(posedge video_clk or posedge rst_video) begin
        if (rst_video) begin
            legacy_resident_mask_meta <= 0;
            legacy_resident_mask_video <= 0;
        end else begin
            legacy_resident_mask_meta <= legacy_resident_mask_sd;
            legacy_resident_mask_video <= legacy_resident_mask_meta;
        end
    end
    // endregion

    // region 05 场景调度（video_clk）
    // ===================== 场景调度（video_clk） =====================
    // site_scene_broker 区分三种状态：wanted（用户当前想看）、request（已发出的
    // 事务快照）、committed（已提交上屏）。它向资源管理器发请求与预取，在帧边界
    // 判断结果是否提交，并产生页面/楼层/轮播动画参数。
    site_scene_broker #(
        .CLK_FREQ_HZ(40_000_000)
    ) u_scene_broker (
        .map_entry_pending(map_entry_pending),
        .map_loading(map_loading),
        .cached_maps(cached_maps_video),
        .map_entry_ready(map_entry_ready),
        .scene_motion(scene_motion),
        .transition_busy(transition_busy),
        .slide_anim(slide_anim),
        .slide_phase(slide_phase),
        .slide_old(slide_old),
        .clk(video_clk),
        .rst(rst_video_scene),
        .site_ready(site_ready),
        .background_ready(background_ready_sync[1]),
        .frame_request(video_read_req),
        .cfg_we(cfg_we),
        .cfg_addr(cfg_addr),
        .cfg_data(cfg_data),
        .requested_view(requested_map_view),
        .requested_scale(requested_map_scale),
        .map_view(scene_map_view),
        .map_scale(scene_map_scale),
        .carousel_progress(carousel_progress),
        .floor_idx(guide_floor_idx),
        .room_idx(guide_selected_room_idx),
        .detail_requested(detail_requested),
        .full_requested(photo_full_requested),
        .reader_full_applied(reader_full_sync_video[1]),
        .photo_view_alpha(photo_view_alpha),
        .photo_view_active(photo_view_active),
        .floor_selecting(floor_selecting),
        .floor_cursor(floor_cursor),
        .nearest_room_valid(nearest_room_valid),
        .nearest_room_idx(nearest_room_idx),
        .map_requested(map_requested),
        .zoom_requested(zoom_requested),
        .pan_requested(pan_requested),
        .origin_x(map_origin_x),
        .origin_y(map_origin_y),
        .next_pulse(guide_next_video),
        .auto_toggle_pulse(guide_auto_toggle_video),
        .auto_play_en(auto_play_active_video),
        .image_loading(load_sync[7]),
        .loading_resource(load_sync[6:0]),
        .visible_loading(visible_loading),
        .loading(site_loading),
        .load_error(site_load_error),
        .carousel_image_id(carousel_image_id),
        .request_keep(request_keep_v),
        .request_prefetch(request_prefetch_v),
        .prefetch_cancel(prefetch_cancel_v),
        .request_toggle(request_toggle_v),
        .request_primary(request_primary_v),
        .request_photo(request_photo_v),
        .request_need_photo(request_need_v),
        .request_tag(request_tag_v),
        .response_toggle(response_toggle_v),
        .response_ok(response_packet_v[6]),
        .response_primary(response_packet_v[5:3]),
        .response_photo(response_packet_v[2:0]),
        .decision_toggle(decision_toggle_v),
        .decision_accept(decision_accept_v),
        .scene_tag(scene_tag),
        .map_mode(scene_map),
        .map_zoom(scene_zoom),
        .map_pan(scene_pan),
        .map_slot(scene_map_slot),
        .map_x(scene_map_x),
        .map_y(scene_map_y),
        .ready(scene_ready),
        .full(scene_full),
        .panel_height(scene_panel_height),
        .slide(scene_slide),
        .bg(scene_bg),
        .photo(scene_photo),
        .floor(scene_floor),
        .room(scene_room)
    );

    // 写确认是 mem 域电平；只把它的上升沿作为事务事件送回 SD 域。
    always @(posedge ext_mem_clk or posedge rst_mem) begin
        if (rst_mem) sd_card_write_req_ack_mem_d <= 1'b0;
        else sd_card_write_req_ack_mem_d <= sd_card_write_req_ack_mem;
    end

    pulse_cdc u_write_ack_cdc (
        .src_clk  (ext_mem_clk),
        .src_reset(rst_mem),
        .src_pulse(sd_card_write_ack_rise_mem),
        .dst_clk  (sd_card_clk),
        .dst_reset(rst_sd),
        .dst_pulse(sd_card_write_ack_pulse_sd)
    );

    pulse_cdc u_frame_done_cdc (
        .src_clk  (ext_mem_clk),
        .src_reset(rst_mem),
        .src_pulse(frame_write_finish),
        .dst_clk  (sd_card_clk),
        .dst_reset(rst_sd),
        .dst_pulse(frame_write_finish_pulse_sd)
    );

    // 中止先进入 mem 域，本地清理后再返回完成事件。
    pulse_cdc u_write_abort_cdc (
        .src_clk  (sd_card_clk),
        .src_reset(rst_sd),
        .src_pulse(frame_write_abort_sd),
        .dst_clk  (ext_mem_clk),
        .dst_reset(rst_mem),
        .dst_pulse(frame_write_abort_mem)
    );

    pulse_cdc u_write_abort_done_cdc (
        .src_clk  (ext_mem_clk),
        .src_reset(rst_mem),
        .src_pulse(frame_write_abort_mem),
        .dst_clk  (sd_card_clk),
        .dst_reset(rst_sd),
        .dst_pulse(frame_write_abort_done_sd)
    );

    // endregion

    // region 06 资源管理器（sd_card_clk）
    // ===================== 资源管理器（sd_card_clk） =====================
    // sd_site_assets 是 SD 卡的唯一使用者：上电读 SITE.CFG；按 broker 请求查找
    // 6 槽缓存，未命中时读 BMP 写入 SDRAM；同时为音频播放器共享 FAT32 读取。
    // 原实例名 sd_card_bmp_m0；旧模块 sd_card_bmp 已不在层次中。
    wire [10:0] asset_stride;
    wire [20:0] asset_words, asset_first;
    wire asset_bottom_up;
    wire [65:0] asset_widths, asset_strides;
    wire [59:0] asset_heights;
    wire font_write_en;
    wire [12:0] font_write_addr;
    wire [17:0] font_write_data;
    sd_site_assets #(
        .CLK_FREQ_HZ(50_000_000),
        .ENABLE_SD_AUDIO(1)
    ) u_site_assets (
        .audio_music(music_sync_sd[1]),
        .audio_event(sd_audio_event),
        .audio_fallback(sd_audio_fallback),
        .audio_error(sd_audio_error),
        .audio_clk(video_clk),
        .audio_rst(rst_video),
        .audio_take(audio_sample_tick),
        .audio_available(sd_audio_available),
        .audio_sample(sd_audio_sample),
        .write_stride(asset_stride),
        .write_words(asset_words),
        .write_first_offset(asset_first),
        .write_bottom_up(asset_bottom_up),
        .slot_tails(asset_tails),
        .slot_widths(asset_widths),
        .slot_strides(asset_strides),
        .slot_heights(asset_heights),
        .cached_maps(cached_maps_sd),
        .image_loading(image_loading_sd),
        .loading_resource(loading_resource_sd),
        .clk(sd_card_clk),
        .rst(rst_sd),
        .cfg_video_clk(video_clk),
        .cfg_video_addr(cfg_read_addr),
        .cfg_video_data(cfg_read_data),
        .font_write_en(font_write_en),
        .font_write_addr(font_write_addr),
        .font_write_data(font_write_data),
        .config_ready(cfg_ready_sd),
        .background_ready(background_ready_sd),
        .error_code(asset_error_code),
        .request_keep(request_packet_sd[55:24]),
        .request_prefetch(request_packet_sd[23]),
        .prefetch_cancel(prefetch_cancel_sync[1]),
        .request_toggle(request_toggle_sd),
        .request_primary(request_packet_sd[14:8]),
        .request_photo(request_packet_sd[7:1]),
        .request_need_photo(request_packet_sd[0]),
        .request_tag(request_packet_sd[22:15]),
        .response_toggle(response_toggle_sd),
        .response_ok(response_ok_sd),
        .response_primary(response_primary_sd),
        .response_photo(response_photo_sd),
        .decision_toggle(decision_toggle_sd),
        .decision_accept(decision_accept_sd),
        .applied_valid(applied_packet_sd[14]),
        .applied_tag(applied_packet_sd[13:6]),
        .applied_mask(applied_packet_sd[5:0]),
        .write_abort(frame_write_abort_sd),
        .write_abort_done(frame_write_abort_done_sd),
        .frame_done_pulse(frame_write_finish_pulse_sd),
        .write_req_ack(sd_card_write_ack_pulse_sd),
        .write_fifo_used(frame_write_fifo_used),
        .write_buf_idx(write_buf_idx),
        .write_tail_idx(write_tail_idx),
        .write_req(sd_card_write_req),
        .write_en(sd_card_write_en),
        .write_data(sd_card_write_data),
        .SD_nCS(sd_ncs),
        .SD_DCLK(sd_dclk),
        .SD_MOSI(sd_mosi),
        .SD_MISO(sd_miso)
    );
    // 双缓冲遗留接口（已加 legacy_ 前缀）：legacy_read_index 只接到 read_addr_index 占位端口；
    // legacy_display_valid 与 legacy_resident_mask_* 已无下游使用，综合时会被优化掉。
    assign legacy_read_index = scene_slide;
    assign legacy_display_valid = background_ready_sd;
    assign legacy_resident_mask_sd = 4'b0001;

    // endregion

    // region 07 数码管诊断（clk）
    // ===================== 数码管诊断（clk） =====================
    // 显示资源管理器错误码；读控制器故障（reader_fault）时显示 E。
    // 连续两拍相同才更新，避免跨域采样时的毛刺显示。
    (* ASYNC_REG="TRUE" *) reg [3:0] diag_code_meta;
    reg [3:0] diag_code_sync, diag_code_last, diag_code_stable;
    always @(posedge clk or posedge rst_all) begin
        if (rst_all) begin
            diag_code_meta <= 0;
            diag_code_sync <= 0;
            diag_code_last <= 0;
            diag_code_stable <= 0;
        end else begin
            diag_code_meta <= reader_fault_sync[1] ? 4'he : asset_error_code;
            diag_code_sync <= diag_code_meta;
            diag_code_last <= diag_code_sync;
            if (diag_code_sync == diag_code_last) diag_code_stable <= diag_code_sync;
        end
    end

    seg_decoder seg_decoder_m0 (
        .bin_data(diag_code_stable),
        .seg_data(seg_data_0)
    );

    seg_scan seg_scan_m0 (
        .clk(clk),
        .rst_n(~rst_all),
        .seg_sel(seg_sel),
        .seg_data(seg_data),
        .seg_data_0({1'b1, 7'b1111_111}),
        .seg_data_1({1'b1, 7'b1111_111}),
        .seg_data_2({1'b1, 7'b1111_111}),
        .seg_data_3({1'b1, 7'b1111_111}),
        .seg_data_4({1'b1, 7'b1111_111}),
        .seg_data_5({1'b1, seg_data_0})
    );

    // endregion

    // region 08 视频时序与像素读出（video_clk）
    // ===================== 视频时序与像素读出（video_clk） =====================
    // video_timing_data 产生 800×600 的 HS/VS/DE，并在每帧开始前发 read_req，
    // 读控制器在该握手中锁存本帧场景描述。
    // 对齐关系：video_delay 21 拍 + 合成器 6 拍 = ui_viewport_800 的 27 拍。
    video_timing_data video_timing_data_m0 (
        .video_clk(video_clk),
        .rst(rst_video_output),
        .read_req(video_read_req),
        .read_req_ack(video_ack_sync[1]),
        .hs(hs_0),
        .vs(vs_0),
        .de(de_0)
    );

    wire window_de, canvas_hs, canvas_vs, canvas_de;
    wire [23:0] canvas_rgb;
    ui_viewport_800 viewport (
        .clk(video_clk),
        .rst(rst_video_output),
        .hs(hs_0),
        .vs(vs_0),
        .de(de_0),
        .ui_rgb(composited_rgb),
        .ui_de(composited_de),
        .window_de(window_de),
        .canvas_hs(canvas_hs),
        .canvas_vs(canvas_vs),
        .canvas_de(canvas_de),
        .canvas_rgb(canvas_rgb)
    );
    video_delay #(
        .DATA_WIDTH(32)
    ) video_delay_m0 (
        .video_clk(video_clk),
        .rst(rst_video_output),
        .read_en(video_read_en),
        .read_data(video_read_data),
        .hs(hs_0),
        .vs(vs_0),
        .de(window_de),
        .hs_r(hs),
        .vs_r(vs),
        .de_r(de),
        .vout_data(video_pixel_packet)
    );

    // 首个场景提交前输出黑色；之后始终显示读控制器按已提交场景读出的像素。
    // The compositor knows the pixel position: only the native photo rectangle
    // uses paired RGB565 during a transition; its surroundings retain RGB888.
    assign vout_data_raw = video_pixel_packet[31:8];
    assign vout_data = scene_ready ? vout_data_raw : 24'd0;

    // endregion

    // region 09 图文合成（video_clk）
    // ===================== 图文合成（video_clk） =====================
    // 在读出的图片像素上叠加列表卡片、地图标记、详情面板、文字与状态条。
    // 合成器只加工像素，不发加载请求，也不直接访问 SDRAM。
    guide_scene_compositor #(
        .RUNTIME_CONFIG(1)
    ) u_guide_scene_compositor (
        .font_write_clk(sd_card_clk),
        .font_write_en(font_write_en),
        .font_write_addr(font_write_addr),
        .font_write_data(font_write_data),
        .cfg_we(cfg_we),
        .cfg_addr(cfg_addr),
        .cfg_data(cfg_data),
        .I_map_loading(map_loading),
        .I_loading(visible_loading),
        .I_load_error(site_load_error),
        .I_clk(video_clk),
        .I_rst(rst_video_draw),
        .I_rgb(vout_data),
        .I_hs(hs),
        .I_vs(vs),
        .I_de(de),
        .I_floor_idx(scene_floor),
        .I_selected_room_idx(scene_room),
        .I_selection_visible(selection_visible),
        .I_floor_selecting(floor_selecting),
        .I_floor_cursor(floor_cursor),
        .I_requested_floor(guide_floor_idx),
        .I_room_occupied(guide_room_occupied),
        .I_elapsed_bcd(selected_elapsed_bcd),
        .I_auto_play_en(auto_play_active_video),
        .I_carousel_progress(carousel_progress),
        .I_detail_requested(detail_requested),
        .I_view_settled(scene_ready),
        .I_scene_motion(scene_motion),
        .I_panel_height(scene_panel_height),
        .I_photo_full(scene_full),
        .I_photo_view_alpha(photo_view_alpha),
        .I_photo_rgb565(video_pixel_packet[15:0]),
        .I_map_view(scene_map_view),
        .I_map_scale(scene_map_scale),
        .I_map_width(map_geometry_sync[20:10]),
        .I_map_height(map_geometry_sync[9:0]),
        .I_map_mode(scene_map),
        .I_map_zoom(scene_zoom),
        .I_map_pan(scene_pan),
        .I_map_x(scene_map_x),
        .I_map_y(scene_map_y),
        .I_period_select(period_select_video),
        .O_panel_active(panel_active),
        .O_rgb(composited_rgb),
        .O_hs(composited_hs),
        .O_vs(composited_vs),
        .O_de(composited_de)
    );

    // endregion

    // region 10 帧存读写（ext_mem_clk）
    // ===================== 帧存读写（ext_mem_clk） =====================
    // 写侧：资源管理器经写 FIFO 把 BMP 像素写入指定槽（6 个槽基址见 write_addr_*）。
    // 读侧：内含 scene_frame_reader，按每帧锁存的场景描述生成读地址并填充读 FIFO，
    //       并通过 applied_* 告诉资源管理器“本帧实际在用哪些槽”。
    // read_addr_*、read_len、read_addr_index 是旧双缓冲接口的占位，当前读路径不用。
    frame_read_write #(
        .WRITE_V_FLIP(1),
        .FRAME_WIDTH(640),
        .FRAME_HEIGHT(480),
        .VERIFY_READ_RETURNS(1)
    ) frame_read_write_m0 (
        .bilinear_enabled(bilinear_enabled),
        .image_stride(asset_stride),
        .image_first_offset(asset_first),
        .image_bottom_up(asset_bottom_up),
        .slot_tails(asset_tails),
        .slot_widths(asset_widths),
        .slot_strides(asset_strides),
        .slot_heights(asset_heights),
        .slide_anim(slide_anim),
        .slide_phase(slide_phase),
        .slide_old(slide_old),
        .scene_tag(scene_tag),
        .applied_pulse(reader_applied_pulse),
        .applied_tag(reader_applied_tag),
        .applied_mask(reader_applied_mask),
        .applied_full(reader_full_applied_mem),
        .scene_motion(scene_motion),
        .map_view(scene_map_view),
        .map_mode(scene_map),
        .map_zoom(scene_zoom),
        .map_slot(scene_map_slot),
        .map_x(scene_map_x),
        .map_y(scene_map_y),
        .scene_ready(scene_ready),
        .photo_full(scene_full),
        .photo_blend(photo_blend),
        .scene_panel_height(scene_panel_height),
        .scene_slide_slot(scene_slide),
        .scene_bg_slot(scene_bg),
        .scene_photo_slot(scene_photo),
        .reader_fault(reader_fault),
        .mem_clk(ext_mem_clk),
        .rst(rst_mem),
        .write_abort(frame_write_abort_mem),
        .Sdr_init_done(Sdr_init_done),
        .Sdr_init_ref_vld(Sdr_init_ref_vld),
        .Sdr_busy(Sdr_busy),
        .App_rd_en(App_rd_en),
        .App_rd_addr(App_rd_addr),
        .Sdr_rd_en(Sdr_rd_en),
        .Sdr_rd_dout(Sdr_rd_dout),
        .read_clk(video_clk),
        .read_req(video_read_req),
        .read_req_ack(video_read_req_ack),
        .read_finish(),
        .applied_buf_idx(applied_buf_idx_mem),
        .applied_buf_valid(applied_buf_valid_mem),
        .read_addr_0(BUF0_ADDR),
        .read_addr_1(BUF1_ADDR),
        .read_addr_2(24'd0),
        .read_addr_3(24'd0),
        .read_addr_index(legacy_read_index),
        .read_len(SLOT_WORDS),
        .read_en(video_read_en),
        .read_data(video_read_data),
        .App_wr_en(App_wr_en),
        .App_wr_addr(App_wr_addr),
        .App_wr_din(App_wr_din),
        .App_wr_dm(App_wr_dm),
        .write_clk(sd_card_clk),
        .write_req(sd_card_write_req),
        .write_req_ack(sd_card_write_req_ack_mem),
        .write_finish(frame_write_finish),
        .write_addr_0(BUF0_ADDR),
        .write_addr_1(BUF1_ADDR),
        .write_addr_2(21'd614400),
        .write_addr_3(21'd921600),
        .write_addr_4(21'd1228800),
        .write_addr_5(21'd1536000),
        .write_tail_index(write_tail_idx),
        .write_addr_index(write_buf_idx),
        .write_len(asset_words),
        .write_en(sd_card_write_en),
        .write_data(sd_card_write_data),
        .write_fifo_used(frame_write_fifo_used)
    );

    // 安路 SDRAM 控制器例程（内部为加密 IP 与封装内 2M×32 SDRAM 硬核）。
    // 静态时序报告中的 SDRAM 接口建立违例出现在该硬核接口上，见工程说明。
    sdram U3 (
        .Clk(ext_mem_clk),
        .Clk_sft(ext_mem_clk_sft),
        .Rst(rst_mem),
        .Sdr_init_done(Sdr_init_done),
        .Sdr_init_ref_vld(Sdr_init_ref_vld),
        .Sdr_busy(Sdr_busy),
        .App_wr_en(App_wr_en),
        .App_wr_addr(App_wr_addr),
        .App_wr_dm(App_wr_dm),
        .App_wr_din(App_wr_din),
        .App_rd_en(App_rd_en),
        .App_rd_addr(App_rd_addr),
        .Sdr_rd_en(Sdr_rd_en),
        .Sdr_rd_dout(Sdr_rd_dout)
    );

    // endregion

    // region 11 后置叠加与 AXIS 转换（video_clk）
    // ===================== 后置叠加与 AXIS 转换（video_clk） =====================
    // canvas → 频谱柱叠加（audio_spectrum_overlay，64 频带）
    //        → 参数面板 → RGB 转 AXIS（video_rgb_to_axis，H_ACTIVE=800）。
    wire adjusted_vs, adjusted_de;
    wire [23:0] adjusted_rgb;
    wire pcm_valid, pcm_acr_valid;
    wire [23:0] pcm_left, pcm_right;
    wire [19:0] pcm_acr_n, pcm_acr_cts;
    wire waveform_vs, waveform_de;
    wire [23:0] waveform_rgb;
    audio_spectrum_overlay u_spectrum_overlay (
        .clk(video_clk),
        .rst(rst_video_overlays),
        .enabled(spectrum_enabled),
        .panel_height(scene_panel_height),
        .pcm_valid(pcm_valid),
        .pcm_left(pcm_left),
        .in_vs(canvas_vs),
        .in_de(canvas_de),
        .in_rgb(canvas_rgb),
        .out_vs(waveform_vs),
        .out_de(waveform_de),
        .out_rgb(waveform_rgb)
    );
    ui_settings_overlay u_settings_overlay (
        .bilinear_enabled(bilinear_enabled),
        .clk(video_clk),
        .rst(rst_video_overlays),
        .in_vs(waveform_vs),
        .in_de(waveform_de),
        .in_rgb(waveform_rgb),
        .spectrum_enabled(spectrum_enabled),
        .music_enabled(music_enabled),
        .music_error(audio_error_sync),
        .settings_open(settings_open),
        .settings_field(settings_field),
        .brightness(ui_brightness),
        .volume(ui_volume),
        .out_vs(adjusted_vs),
        .out_de(adjusted_de),
        .out_rgb(adjusted_rgb)
    );
    // Font RAM and all name records must be loaded before exposing the UI.
    // Change the gate only during vertical sync; HDMI timing continues while black.
    reg config_display_ready;
    always @(posedge video_clk or posedge rst_video_output) begin
        if (rst_video_output) config_display_ready <= 0;
        else if (adjusted_vs) config_display_ready <= site_ready;
    end
    video_rgb_to_axis u_video_rgb_to_axis (
        .I_clk(video_clk),
        .I_rst(rst_video_output),
        .I_vs(adjusted_vs),
        .I_de(adjusted_de),
        .I_rgb(config_display_ready ? adjusted_rgb : 24'd0),
        .O_video_user(axis_s_user),
        .O_video_valid(axis_s_valid),
        .O_video_last(axis_s_last),
        .O_video_data(axis_s_data)
    );

    // 上电后自动打一拍，触发一次 EDID 读取
    startup_pulse #(
        .CNT_MAX(20'd100000)
    ) u_startup_pulse (
        .I_clk  (video_clk),
        .I_rst  (rst_video),
        .O_pulse(edid_trig)
    );

    // endregion

    // region 12 音频事件与输出（video_clk）
    // ===================== 音频事件与输出（video_clk） =====================
    // 48 kHz PCM 节拍与 ACR 由 40 MHz 像素时钟上的累加器产生（hdmi_event_audio）。
    // 事件来源：
    //   navigation_voice_events：页面/楼层切换完成后播报（MAP/INDEX/FLOORn.WAV）
    //   ui_operation_events    ：选择、占用、详情、参数变化等短提示（UI1~3.WAV）
    //   av_scene_events        ：本工程只接入轮播换图事件，其余输入接为常数 0
    // 事件经邮箱跨到 SD 域，由 sd_dual_audio 读 WAV；文件缺失时退回合成提示音。
    wire [1:0] audio_event;
    av_scene_events u_av_events (
        .clk(video_clk),
        .rst(rst_video_audio),
        .compositor_vs(vs),
        .axis_valid(axis_s_valid),
        .axis_user(axis_s_user),
        .axis_ready(axis_s_ready),
        .scene_ready(scene_ready),
        .photo_full(1'b0),
        .panel_height(8'd0),
        .slide_slot(carousel_image_id),
        .floor_idx(2'd0),
        .occupied(30'd0),
        .event_code(audio_event)
    );
    ui_operation_events u_operation_events (
        .clk(video_clk),
        .rst(rst_video_audio),
        .ready(site_ready && scene_ready && !transition_busy && map_requested == scene_map &&
               guide_floor_idx == scene_floor),
        .floor_idx(guide_floor_idx),
        .room_idx(guide_selected_room_idx),
        .map_mode(map_requested),
        .zoom(map_level),
        .detail(detail_requested),
        .full(photo_full_requested),
        .auto_play(auto_play_active_video),
        .pan_x(map_target_x2),
        .pan_y(map_target_y2),
        .occupied(guide_room_occupied),
        .settings_event(settings_event),
        .commit_event(audio_event),
        .event_code(operation_event)
    );
    hdmi_event_audio u_event_audio (
        .event_code(audio_fallback_video),
        .volume(ui_volume),
        .clk(video_clk),
        .rst(rst_video_audio),
        .audio_valid(audio_sample_tick),
        .left_data(tone_left),
        .right_data(tone_right),
        .acr_valid(audio_acr_tick),
        .acr_n(pcm_acr_n),
        .acr_cts(pcm_acr_cts)
    );
    wire [3:0] navigation_voice_event;
    navigation_voice_events u_navigation_voice (
        .clk(video_clk),
        .rst(rst_video_audio),
        .scene_ready(scene_ready),
        .transition_busy(transition_busy),
        .frame_accept(axis_s_valid && axis_s_user && axis_s_ready),
        .floor_idx(scene_floor),
        .map_mode(scene_map),
        .event_code(navigation_voice_event)
    );
    wire [3:0]
        sd_command_event = navigation_voice_event != 0 ? navigation_voice_event : {2'd0, operation_event};
    audio_event_mailbox #(
        .WIDTH(4),
        .PRIORITY_MIN(4)
    ) u_audio_commands (
        .sclk(video_clk),
        .srst(rst_video),
        .event_in(sd_command_event),
        .dclk(sd_card_clk),
        .drst(rst_sd),
        .event_out(sd_audio_event)
    );
    audio_event_mailbox u_audio_fallback (
        .sclk(sd_card_clk),
        .srst(rst_sd),
        .event_in(sd_audio_fallback),
        .dclk(video_clk),
        .drst(rst_video),
        .event_out(audio_fallback_video)
    );
    audio_output_mixer u_audio_output (
        .clk(video_clk),
        .rst(rst_video_audio),
        .tick(audio_sample_tick),
        .acr_tick(audio_acr_tick),
        .tone_left(tone_left),
        .tone_right(tone_right),
        .available(sd_audio_available),
        .sample(sd_audio_sample),
        .volume(ui_volume),
        .pcm_valid(pcm_valid),
        .acr_valid(pcm_acr_valid),
        .left_data(pcm_left),
        .right_data(pcm_right)
    );
    // endregion

    // region 13 HDMI 1.4b 发射
    // ===================== HDMI 1.4b 发射 =====================
    // 厂商加密 IP：AXIS 视频 + PCM 音频 → TMDS 10 位码；hdmi_phy_wrapper 做 10:1 串行。
    // 时序参数：每行 1056（有效 800），每帧 628（有效 600）。
    hdmi_1_4b_transmitter_core_wrapper #(
        .DEVICE("EG"),
        .HTOTAL(1056),
        .HSA(128),
        .HFP(40),
        .HBP(88),
        .HACTIVE(800),
        .VTOTAL(628),
        .VSA(4),
        .VFP(1),
        .VBP(23),
        .VACTIVE(600),
        .VIDEO_VIC(0),
        .VIDEO_TPG("Disable"),
        .VIDEO_FORMAT("RGB"),
        .AUDIO_SAMPLE_RATE("48K"),
        .IIC_SCL_DIV(400)
    ) u_hdmi_1_4b_transmitter_core_wrapper (
        .I_pixel_clk(video_clk),
        .I_rst(rst_video_output),
        .I_edid_read_trig(edid_trig),
        .O_edid_read_valid(edid_valid),
        .O_edid_read_data(edid_data),
        .I_axis_s_user(axis_s_user),
        .I_axis_s_valid(axis_s_valid),
        .I_axis_s_last(axis_s_last),
        .I_axis_s_data(axis_s_data),
        .O_axis_s_ready(axis_s_ready),
        .I_audio_valid(pcm_valid),
        .I_audio_left_data(pcm_left),
        .I_audio_right_data(pcm_right),
        .I_acr_valid(pcm_acr_valid),
        .I_acr_cts(pcm_acr_cts),
        .I_acr_n(pcm_acr_n),
        .O_video_locked(),
        .O_ddc_scl(HDMI_DDC_SCL),
        .IO_ddc_sda(HDMI_DDC_SDA),
        .O_ch0_tmds_data(tmds_ch0_data),
        .O_ch1_tmds_data(tmds_ch1_data),
        .O_ch2_tmds_data(tmds_ch2_data),
        .O_clk_tmds_data(tmds_clk_data)
    );

    hdmi_phy_wrapper #(
        .DEVICE("EG")
    ) u_hdmi2phy_wrapper (
        .I_pixel_clk(video_clk),
        .I_serial_clk(hdmi_5x_clk),
        .I_rst(rst_hdmi),
        .I_tmds_channel_0(tmds_ch0_data),
        .I_tmds_channel_1(tmds_ch1_data),
        .I_tmds_channel_2(tmds_ch2_data),
        .I_tmds_channel_clk(tmds_clk_data),
        .O_tmds_ch0_p(HDMI_D0_P),
        .O_tmds_ch1_p(HDMI_D1_P),
        .O_tmds_ch2_p(HDMI_D2_P),
        .O_tmds_clk_p(HDMI_CLK_P)
    );

    // endregion

endmodule
