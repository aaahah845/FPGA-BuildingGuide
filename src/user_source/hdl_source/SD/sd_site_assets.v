`include "fat32_named_file.v"
`include "bmp_dynamic_read.v"
`include "shared_fat32_reader.v"
`include "sd_wav_player.v"
`include "audio_sector_fifo.v"
`include "sd_dual_audio.v"
// ============================================================================
// sd_site_assets：资源管理器，运行在 sd_card_clk（本工程为 50 MHz）。
// 接收调度器的资源 ID，查询或装入 SDRAM 图片槽，再返回槽号与结果。
//
// 启动先读取 27648 字节的 SITE.CFG V6，校验文件头、配置区和字模区。
// 前 8 KB 写配置 RAM，其余载入片上字模 RAM；完整校验后拉高 config_ready。
//
// request_toggle 变化时锁存请求。SCAN 逐槽查询资源 ID；未命中则从配置取
// 8.3 文件名，打开文件并解析 BMP 头，再分配空间、请求写入。主图完成后，
// 按 need_photo 决定是否继续照片阶段。响应后等待 decision，再等待读端接管。
//
// valid 标记图片根槽，footprint[根槽] 描述图片实际占用的物理槽。
// 大地图可以跨两个不相邻槽；尾槽按所属有效图片的占用与 age 参与分配。
// 分配优先空闲槽，否则比较 age；held、applied_mask、primary_pin 和预取
// 保留集合展开为物理槽掩码，保护本事务、当前扫描及返回界面所需的图片。
//
// write_req_ack 表示写控制器已接收参数，frame_done_pulse 表示写通路发送完成。
// source_started、ack_seen、done_seen 分别记录本笔 BMP 启动、接收和完成；
// LOAD_RUN 等解析器收尾与写通路完成条件一起满足后，才发布 valid 和槽信息。
//
// 取消适用于预取与前景照片阶段；前景主图继续完成，错误或超时另行中止。
// 中止时请求文件系统、BMP 和写通路收尾，ABORT_WAIT 等各方恢复空闲后应答。
// 接受的场景要等 applied_tag 匹配本笔 tag 才释放 held，后续由读端掩码保护。
// ============================================================================
// region 01 接口
module sd_site_assets #(
    parameter CLK_FREQ_HZ = 100000000,
    parameter ENABLE_SD_AUDIO = 0
) (
    input audio_music,
    input [3:0] audio_event,
    output [1:0] audio_fallback,
    output [3:0] audio_error,
    input audio_clk, audio_rst, audio_take,
    output audio_available,
    output [15:0] audio_sample,
    input clk, rst,
    input cfg_video_clk,
    input [12:0] cfg_video_addr,
    output wire [7:0] cfg_video_data,
    output reg font_write_en,
    output reg [12:0] font_write_addr,
    output reg [17:0] font_write_data,
    output reg config_ready, background_ready,
    output reg [3:0] error_code,
    output reg [2:0] cached_maps,
    output reg image_loading,
    output reg [6:0] loading_resource,
    // 来自调度器的请求邮箱，已在顶层跨域；一笔请求内的 ID、tag 和 keep 保持不变。
    input request_prefetch, prefetch_cancel,
    input [31:0] request_keep,
    input request_toggle,
    input [6:0] request_primary, request_photo,
    input request_need_photo,
    input [7:0] request_tag,
    output reg response_toggle, response_ok,
    output reg [2:0] response_primary, response_photo,
    input decision_toggle, decision_accept,
    // 读控制器接管反馈；根槽掩码在本模块展开为包含尾槽的物理保护集合。
    input applied_valid,
    input [7:0] applied_tag,
    input [5:0] applied_mask,
    // BMP 写通路：像素进入写 FIFO，ack/done/abort_done 分别确认接收、完成和中止。
    output reg write_abort,
    input write_abort_done, frame_done_pulse, write_req_ack,
    input [8:0] write_fifo_used,
    output reg [2:0] write_buf_idx, write_tail_idx,
    output reg [17:0] slot_tails,
    output write_req, write_en,
    output [31:0] write_data,
    output [10:0] write_stride,
    output [20:0] write_words, write_first_offset,
    output write_bottom_up,
    output reg [65:0] slot_widths, slot_strides,
    output reg [59:0] slot_heights,
    output SD_nCS, SD_DCLK, SD_MOSI,
    input SD_MISO
);
    `include "../site_font_id.vh"
    `include "../room_notes_font_id.vh"
    // endregion

    // region 02 状态、配置和加载条件
    localparam BOOT = 0, CFG_OPEN = 1, CFG_WAIT = 2, CFG_READ = 3, CFG_GAP = 4, CFG_CHECK = 5, NAME_ADDR = 6,
        NAME_WAIT = 7, NAME_GET = 8, IMAGE_OPEN = 9, IMAGE_WAIT = 10, LOAD_BEGIN = 11, LOAD_RUN = 12,
        ABORT_WAIT = 13, WAIT_REQUEST = 14, SELECT = 15, SELECT_NEXT = 16, RESPOND = 17, DECIDE = 18,
        APPLY_WAIT = 19, HALT = 20, SELECT_WAIT = 21, SCAN = 22;
    reg [4:0] state;
    reg [6:0] map_id0, map_id1, map_id2;
    reg reserved, allocating;
    reg [5:0] allocation;
    reg [6:0] wanted_id;
    reg wanted_bad, wanted_large;
    reg [14:0] cfg_pos;
    reg [5:0] cfg_sector;
    // Dynamic fonts require a complete v6 package, including after warm reset.
    // Legacy configurations cannot restore overwritten RAM and are rejected.
    wire cfg_large = 1'b1, cfg_extended = 1'b1;
    reg cfg_verified;
    reg [3:0] cfg_errors, cfg_header_errors;
    wire cfg_bad = (|cfg_errors) || (|cfg_header_errors);
    reg [15:0] checksum, expected_sum;
    reg [15:0] font_checksum, font_expected_sum;
    reg [7:0] font_byte0, font_byte1;
    reg [1:0] font_byte2;
    reg [7:0] previous_byte;
    (* syn_ramstyle="block_ram" *) reg [7:0] cfg_mem[0:8191];
    reg [12:0] mem_addr;
    reg [7:0] mem_q;
    wire sd_ready, sd_req, sd_valid, sd_end;
    wire [31:0] sd_addr;
    wire [7:0] sd_data;
    wire fs_idle, mounted, open_done, open_ok, file_valid, file_end;
    wire [31:0] file_size;
    wire [7:0] file_data;
    wire [3:0] fs_error;
    wire bmp_ready;
    reg source_started, ack_seen, done_seen, abort_seen;
    reg load_complete, open_done_q, open_ok_q, cfg_size_ok;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            load_complete <= 0;
            open_done_q <= 0;
            open_ok_q <= 0;
            cfg_size_ok <= 0;
        end else begin
            open_done_q <= open_done;
            open_ok_q <= open_ok;
            cfg_size_ok <= file_size == 27648;
            load_complete <= state == LOAD_RUN && source_started && bmp_ready && fs_idle &&
                (done_seen || ((ack_seen || write_req_ack) && frame_done_pulse));
        end
    end
    reg fs_open, fs_abort;
    reg [87:0] fs_name;
    wire bmp_req, bmp_we, bmp_write_req;
    wire [3:0] bmp_error;
    wire [10:0] bmp_width;
    wire [9:0] bmp_height;
    wire [31:0] bmp_sector;
    wire [23:0] bmp_pixel;
    reg bmp_start;
    wire image_stream = state == LOAD_BEGIN || state == LOAD_RUN || state == ABORT_WAIT;
    reg file_req;
    reg [31:0] file_sector;
    reg [7:0] bmp_byte;
    reg bmp_valid, bmp_end;
    // Break the state/mux -> BMP header and logical-sector validation paths.
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            file_req <= 0;
            file_sector <= 0;
            bmp_byte <= 0;
            bmp_valid <= 0;
            bmp_end <= 0;
        end else begin
            file_req <= state == CFG_READ || (image_stream && bmp_req);
            file_sector <= state == CFG_READ ? {26'd0, cfg_sector} : bmp_sector;
            bmp_byte <= file_data;
            bmp_valid <= file_valid && image_stream;
            bmp_end <= file_end && image_stream;
        end
    end
    assign write_req = bmp_write_req && reserved;
    assign write_en = bmp_we && reserved;
    assign write_data = {bmp_pixel, 8'd0};
    // endregion

    // region 03 共享文件系统与音频通路
    generate
        if (ENABLE_SD_AUDIO) begin : g_audio
            wire awant, aopen, aabort, aidle, aopened, aok, areq, avalid, aend, full, empty, write_sample,
                publish;
            wire [87:0] aname;
            wire [31:0] asize, asector;
            wire [3:0] aerror;
            wire [7:0] adata, sample_index;
            wire [15:0] sample_data;
            wire [8:0] publish_count;
            wire audio_context;
            shared_fat32_reader #(
                .TRIPLE_AUDIO(1)
            ) fs (
                .a_context(audio_context),
                .clk(clk),
                .rst(rst | !sd_ready),
                .sd_ready(sd_ready),
                .mounted(mounted),
                .audio_enable(config_ready),
                .i_open(fs_open),
                .i_name(fs_name),
                .i_abort(fs_abort),
                .i_req(file_req),
                .i_sector(file_sector),
                .i_idle(fs_idle),
                .i_open_done(open_done),
                .i_open_ok(open_ok),
                .i_size(file_size),
                .i_error(fs_error),
                .i_data(file_data),
                .i_valid(file_valid),
                .i_end(file_end),
                .a_want(awant),
                .a_open(aopen),
                .a_name(aname),
                .a_abort(aabort),
                .a_req(areq),
                .a_sector(asector),
                .a_idle(aidle),
                .a_open_done(aopened),
                .a_open_ok(aok),
                .a_size(asize),
                .a_error(aerror),
                .a_data(adata),
                .a_valid(avalid),
                .a_end(aend),
                .sd_req(sd_req),
                .sd_addr(sd_addr),
                .sd_data(sd_data),
                .sd_valid(sd_valid),
                .sd_end(sd_end)
            );
            sd_dual_audio player (
                .clk(clk),
                .rst(rst),
                .ready(config_ready),
                .music_on(audio_music),
                .event_code(audio_event),
                .fallback_event(audio_fallback),
                .error(audio_error),
                .context_select(audio_context),
                .want(awant),
                .file_open(aopen),
                .file_abort(aabort),
                .file_name(aname),
                .fs_idle(aidle),
                .open_done(aopened),
                .open_ok(aok),
                .file_size(asize),
                .fs_error(aerror),
                .file_req(areq),
                .file_sector(asector),
                .file_data(adata),
                .file_valid(avalid),
                .file_end(aend),
                .audio_clk(audio_clk),
                .audio_rst(audio_rst),
                .take(audio_take),
                .available(audio_available),
                .sample(audio_sample)
            );
        end else begin : g_legacy
            assign audio_available = 0;
            assign audio_sample = 0;
            assign audio_fallback = 0;
            assign audio_error = 0;
            fat32_named_file fs (
                .context_select(1'b0),
                .context_active(),
                .clk(clk),
                .rst(rst | !sd_ready),
                .sd_ready(sd_ready),
                .mounted(mounted),
                .open_done(open_done),
                .open_ok(open_ok),
                .file_size(file_size),
                .error_code(fs_error),
                .idle(fs_idle),
                .file_open(fs_open),
                .file_name(fs_name),
                .file_abort(fs_abort),
                .file_req(file_req),
                .file_sector(file_sector),
                .file_data(file_data),
                .file_valid(file_valid),
                .file_end(file_end),
                .sd_req(sd_req),
                .sd_addr(sd_addr),
                .sd_data(sd_data),
                .sd_valid(sd_valid),
                .sd_end(sd_end)
            );
        end
    endgenerate
    // endregion

    // region 04 BMP 解析与 SD 卡接口
    bmp_dynamic_read bmp (
        .clk(clk),
        .rst(rst),
        .ready(bmp_ready),
        .start(bmp_start),
        .abort(fs_abort),
        .allow_large(wanted_large),
        .actual_file_size(file_size),
        .error(bmp_error),
        .stream_ready(write_fifo_used <= 256),
        .write_req(bmp_write_req),
        .write_ack(write_req_ack && reserved),
        .image_width(bmp_width),
        .image_height(bmp_height),
        .image_stride(write_stride),
        .image_words(write_words),
        .first_offset(write_first_offset),
        .bottom_up(write_bottom_up),
        .sector_req(bmp_req),
        .sector(bmp_sector),
        .data(bmp_byte),
        .valid(bmp_valid),
        .sector_end(bmp_end),
        .pixel_valid(bmp_we),
        .pixel(bmp_pixel)
    );
    sd_card_top sd (
        .clk(clk),
        .rst(rst),
        .SD_nCS(SD_nCS),
        .SD_DCLK(SD_DCLK),
        .SD_MOSI(SD_MOSI),
        .SD_MISO(SD_MISO),
        .sd_init_done(sd_ready),
        .sd_sec_read(sd_req),
        .sd_sec_read_addr(sd_addr),
        .sd_sec_read_data(sd_data),
        .sd_sec_read_data_valid(sd_valid),
        .sd_sec_read_end(sd_end),
        .sd_sec_write(1'b0),
        .sd_sec_write_addr(32'd0),
        .sd_sec_write_data(8'd0),
        .sd_sec_write_data_req(),
        .sd_sec_write_end()
    );

    reg [7:0] resource_count;
    reg [1:0] floor_count;
    reg [4:0] slide_count;
    reg cfg_point_photos, cfg_wide_ids;
    always @(posedge clk or posedge rst)
        if (rst) begin
            wanted_bad <= 0;
            wanted_large <= 0;
        end else begin
            wanted_bad <= wanted_id >= resource_count;
            wanted_large <= (floor_count > 0 && wanted_id == map_id0) ||
                (floor_count > 1 && wanted_id == map_id1) || (floor_count > 2 && wanted_id == map_id2);
        end

    // endregion

    // region 05 槽位归属、年龄与保护掩码
    reg [5:0] footprint[0:5];
    reg [5:0] valid, held;
    reg [6:0] resource[0:5];
    reg seen_request, transaction_toggle, need_photo, phase, boot_image;
    reg [6:0] primary_id, photo_id;
    reg [7:0] transaction_tag;
    reg [3:0] name_pos;
    reg [31:0] timeout;
    // Residency is published only for complete valid roots; two-slot tails
    // become visible together with their root after the writer has finished.
    integer map_probe;
    reg [2:0] cached_maps_next;
    always @* begin
        cached_maps_next = 0;
        for (map_probe = 0; map_probe < 6; map_probe = map_probe + 1)
        if (valid[map_probe]) begin
            if (resource[map_probe] == map_id0) cached_maps_next[0] = 1;
            if (resource[map_probe] == map_id1) cached_maps_next[1] = 1;
            if (resource[map_probe] == map_id2) cached_maps_next[2] = 1;
        end
    end
    always @(posedge clk or posedge rst)
        if (rst) cached_maps <= 0;
        else cached_maps <= cached_maps_next;
    reg prefetch;
    reg [31:0] prefetch_keep;
    reg [5:0] hint_protected;
    reg primary_pin_valid;
    reg [2:0] primary_pin;
    reg [2:0] age[0:5];
    reg [2:0] victim_age;
    reg hit, free_found;
    reg [2:0] hit_slot, free_slot;
    integer k;
    reg [2:0] scan_slot, pair_first;
    reg pair_second;
    reg free_invalid;
    // valid marks image roots, not physical occupancy. A live map's tail must
    // compete at its owner's age instead of being preferred as an empty slot.
    // Valid footprints never overlap: allocation invalidates every old owner
    // before publishing a new root. OR the matching owner's age (one-hot).
    reg scan_occupied;
    reg [2:0] scan_age;
    integer owner_i;
    always @* begin
        scan_occupied = 0;
        scan_age = 0;
        for (owner_i = 0; owner_i < 6; owner_i = owner_i + 1) begin
            scan_occupied = scan_occupied | (valid[owner_i] && footprint[owner_i][scan_slot]);
            scan_age = scan_age | ({3{valid[owner_i] && footprint[owner_i][scan_slot]}} & age[owner_i]);
        end
    end
    reg touch;
    reg [2:0] touch_slot;
    integer a;
    // Update replacement metadata after the hit/completion decision. No slot
    // selection occurs until SELECT_WAIT/SCAN, so the age is ready in time.
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            for (a = 0; a < 6; a = a + 1) age[a] <= 0;
        end else if (touch) begin
            for (a = 0; a < 6; a = a + 1)
            if (a == touch_slot) age[a] <= 0;
            else if (age[a] != 5) age[a] <= age[a] + 1'b1;
        end
    end
    // Broker cancel also covers an obsolete foreground room photo, but never
    // interrupts its still-useful primary phase. Abort must drain before reuse.
    // 可取消的只有预取和前景请求的照片阶段（phase=1）；前景主图不受取消影响。
    wire cancel_load = prefetch_cancel && (prefetch || phase);
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            image_loading <= 0;
            loading_resource <= 0;
        end else begin
            image_loading <= state == NAME_ADDR || state == NAME_WAIT || state == NAME_GET ||
                state == IMAGE_OPEN || state == IMAGE_WAIT || state == LOAD_BEGIN || state == LOAD_RUN;
            loading_resource <= wanted_id;
        end
    end
    // 受保护的根槽：本事务占用 | 读控制器本帧正在扫描 | 最近一次上屏的主图。
    // 下面再把每个根的 footprint 展开，大地图的尾槽也一起受保护；
    // blocked_slots 另加预取请求附带的 keep 资源，分配新槽时一律避开。
    wire [5:0] protection_roots = held | (applied_valid ? applied_mask : 6'd0) |
        (primary_pin_valid ? (6'b1 << primary_pin) : 6'd0);
    reg [5:0] protected_slots, blocked_slots;
    integer protect_i;
    always @* begin
        protected_slots = protection_roots;
        blocked_slots = hint_protected;
        for (protect_i = 0; protect_i < 6; protect_i = protect_i + 1) begin
            if (protection_roots[protect_i]) protected_slots = protected_slots | footprint[protect_i];
            if (hint_protected[protect_i]) blocked_slots = blocked_slots | footprint[protect_i];
        end
        blocked_slots = blocked_slots | protected_slots;
    end
    // Header geometry is stable before SELECT_WAIT/SCAN (at least 7 clocks).
    // Register pair classification to remove its wide compare from allocation.
    reg need_pair;
    always @(posedge clk or posedge rst)
        if (rst) need_pair <= 0;
        else need_pair <= write_words > 307200;
    wire [5:0] candidate_mask = 6'b1 << scan_slot;
    wire [5:0] victim_mask = (6'b1 << free_slot) | (need_pair ? (6'b1 << pair_first) : 6'd0);
    // endregion

    // region 06 配置读口与请求辅助寄存
    reg [7:0] cfg_video_raw;
    reg cfg_legacy_zero;
    always @(posedge cfg_video_clk) begin
        cfg_video_raw <= cfg_mem[cfg_video_addr];
        cfg_legacy_zero <= !cfg_large && cfg_video_addr >= 1024;
    end
    assign cfg_video_data = cfg_legacy_zero ? 8'd0 : cfg_video_raw;
    wire [12:0] cfg_sd_addr = state == CFG_READ ? cfg_pos[12:0] : mem_addr;
    always @(posedge clk) begin
        mem_q <= cfg_mem[cfg_sd_addr];
        if (state == CFG_READ && file_valid && cfg_pos < 8192) cfg_mem[cfg_sd_addr] <= file_data;
    end
    // Match resource IDs before victim selection; one settle cycle follows a
    // new mailbox transaction so this register always describes that request.
    integer h;
    always @(posedge clk or posedge rst) begin
        if (rst) hint_protected <= 0;
        else
            for (h = 0; h < 6; h = h + 1)
            hint_protected[h] <= prefetch && valid[h] &&
                ((prefetch_keep[28] && resource[h] == prefetch_keep[6:0]) ||
                 (prefetch_keep[29] && resource[h] == prefetch_keep[13:7]) ||
                 (prefetch_keep[30] && resource[h] == prefetch_keep[20:14]) ||
                 (prefetch_keep[31] && resource[h] == prefetch_keep[27:21]));
    end
    // Decode filename shifts independently of cache-selection and completion logic.
    // Eleven NAME_GET bytes completely replace the old name; no miss-path clear.
    always @(posedge clk or posedge rst) begin
        if (rst) fs_name <= 0;
        else if (state == CFG_OPEN) fs_name <= 88'h5349544520202020434647;
        else if (state == NAME_GET) fs_name <= {fs_name[79:0], mem_q};
    end
    // endregion

    // region 07 启动、加载、取消和提交状态机
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= BOOT;
            config_ready <= 0;
            background_ready <= 0;
            error_code <= 0;
            fs_open <= 0;
            fs_abort <= 0;
            bmp_start <= 0;
            write_abort <= 0;
            write_buf_idx <= 0;
            write_tail_idx <= 0;
            slot_tails <= 0;
            pair_first <= 0;
            pair_second <= 0;
            response_toggle <= 0;
            response_ok <= 0;
            response_primary <= 0;
            response_photo <= 0;
            seen_request <= 0;
            transaction_toggle <= 0;
            cfg_pos <= 0;
            cfg_sector <= 0;
            cfg_point_photos <= 0;
            cfg_wide_ids <= 0;
            cfg_errors <= 0;
            cfg_header_errors <= 0;
            cfg_verified <= 0;
            checksum <= 0;
            expected_sum <= 0;
            font_checksum <= 0;
            font_expected_sum <= 0;
            font_byte0 <= 0;
            font_byte1 <= 0;
            font_byte2 <= 0;
            font_write_en <= 0;
            font_write_addr <= 0;
            font_write_data <= 0;
            previous_byte <= 0;
            resource_count <= 0;
            floor_count <= 0;
            slide_count <= 0;
            prefetch <= 0;
            prefetch_keep <= 0;
            primary_pin_valid <= 0;
            primary_pin <= 0;
            mem_addr <= 0;
            valid <= 0;
            held <= 0;
            need_photo <= 0;
            phase <= 0;
            boot_image <= 0;
            primary_id <= 0;
            photo_id <= 0;
            wanted_id <= 0;
            transaction_tag <= 0;
            name_pos <= 0;
            source_started <= 0;
            ack_seen <= 0;
            done_seen <= 0;
            abort_seen <= 0;
            timeout <= 0;
            scan_slot <= 0;
            hit <= 0;
            hit_slot <= 0;
            free_found <= 0;
            free_slot <= 0;
            free_invalid <= 0;
            victim_age <= 0;
            touch <= 0;
            touch_slot <= 0;
            reserved <= 0;
            allocating <= 0;
            allocation <= 0;
            map_id0 <= 0;
            map_id1 <= 0;
            map_id2 <= 0;
            slot_widths <= {6{11'd640}};
            slot_strides <= {6{11'd640}};
            slot_heights <= {6{10'd480}};
            for (k = 0; k < 6; k = k + 1) begin
                resource[k] <= 0;
                footprint[k] <= 6'b1 << k;
            end
        end else begin
            fs_open <= 0;
            fs_abort <= 0;
            bmp_start <= 0;
            write_abort <= 0;
            touch <= 0;
            font_write_en <= 0;
            // Settles while CFG_GAP waits for the file reader to drain and return idle.
            // Avoid a length/checksum comparison on the filename register enable path.
            cfg_verified <= !cfg_bad && cfg_pos == 27648 && checksum == expected_sum &&
                font_checksum == font_expected_sum;
            if (state == CFG_READ && file_valid) begin
                cfg_pos <= cfg_pos + 1'b1;
                previous_byte <= file_data;
                if (cfg_pos < 8190) checksum <= checksum + file_data;
                if (cfg_pos >= 8192 && cfg_pos < 27648) begin
                    font_checksum <= font_checksum + file_data;
                    if (cfg_pos < 24576) begin
                        // 4096 x 18-bit words, stored as little-endian uint32.
                        case (cfg_pos[1:0])
                            0: font_byte0 <= file_data;
                            1: font_byte1 <= file_data;
                            2: begin
                                font_byte2 <= file_data[1:0];
                                if (|file_data[7:2]) cfg_errors[0] <= 1;
                            end
                            3: begin
                                if (file_data != 0) cfg_errors[0] <= 1;
                                font_write_en <= 1;
                                font_write_addr <= cfg_pos[14:2] - 13'd2048;
                                font_write_data <= {font_byte2, font_byte1, font_byte0};
                            end
                        endcase
                    end else begin
                        // 1536 x 16-bit words. Address 4096 starts notes bank 0.
                        if (!cfg_pos[0]) font_byte0 <= file_data;
                        else begin
                            font_write_en <= 1;
                            font_write_addr <= 13'd4096 + {1'b0, cfg_pos[12:1]};
                            font_write_data <= {2'b0, file_data, font_byte0};
                        end
                    end
                end
                case (cfg_pos)
                    0: if (file_data != "S") cfg_header_errors[0] <= 1;
                    1: if (file_data != "G") cfg_header_errors[0] <= 1;
                    2: if (file_data != "C") cfg_header_errors[0] <= 1;
                    3: if (file_data != "1") cfg_header_errors[0] <= 1;
                    4: begin
                        cfg_point_photos <= 1;
                        cfg_wide_ids <= 1;
                        if (file_data != 6) cfg_header_errors[0] <= 1;
                    end
                    8: begin
                        floor_count <= file_data[1:0];
                        if (file_data < 1 || file_data > 3) cfg_header_errors[1] <= 1;
                    end
                    9: begin
                        resource_count <= file_data;
                        if (file_data < 1 || file_data > (cfg_extended ? 128 : cfg_wide_ids ? 64 : 16))
                            cfg_header_errors[1] <= 1;
                    end
                    10: begin
                        slide_count <= file_data[4:0];
                        if (file_data < 1 || file_data > 16) cfg_header_errors[1] <= 1;
                    end
                    11: if (file_data > 3) cfg_header_errors[1] <= 1;
                    12, 13, 14: if (file_data > 1) cfg_header_errors[2] <= 1;
                    16: if (file_data != SITE_FONT_ID[7:0]) cfg_header_errors[3] <= 1;
                    17: if (file_data != SITE_FONT_ID[15:8]) cfg_header_errors[3] <= 1;
                    18: if (file_data != SITE_FONT_ID[23:16]) cfg_header_errors[3] <= 1;
                    19: if (file_data != SITE_FONT_ID[31:24]) cfg_header_errors[3] <= 1;
                    20: if (cfg_large && file_data != NOTES_FONT_ID[7:0]) cfg_header_errors[3] <= 1;
                    21: if (cfg_large && file_data != NOTES_FONT_ID[15:8]) cfg_header_errors[3] <= 1;
                    22: if (cfg_large && file_data != NOTES_FONT_ID[23:16]) cfg_header_errors[3] <= 1;
                    23: if (cfg_large && file_data != NOTES_FONT_ID[31:24]) cfg_header_errors[3] <= 1;
                    24: font_expected_sum[7:0] <= file_data;
                    25: font_expected_sum[15:8] <= file_data;
                    26: if (file_data != 1) cfg_header_errors[0] <= 1;
                    // V5 optional title marker; zero preserves the built-in title.
                    1296: if (cfg_extended && file_data != 0 && file_data != 8'h54) cfg_errors[3] <= 1;
                    1022: if (!cfg_large) expected_sum[7:0] <= file_data;
                    1023: if (!cfg_large) expected_sum[15:8] <= file_data;
                    4094: if (cfg_large && !cfg_extended) expected_sum[7:0] <= file_data;
                    4095: if (cfg_large && !cfg_extended) expected_sum[15:8] <= file_data;
                    8190: if (cfg_extended) expected_sum[7:0] <= file_data;
                    8191: if (cfg_extended) expected_sum[15:8] <= file_data;
                    default: ;
                endcase
                if (cfg_pos >= 256 && cfg_pos < 304) begin
                    if (cfg_pos[3:0] == 0 && cfg_pos[5:4] < floor_count &&
                        (file_data < 1 || file_data > (cfg_extended ? 10 : 6)))
                        cfg_errors[1] <= 1;
                    if (cfg_pos[3:0] == 1) begin
                        if (file_data >= resource_count) cfg_errors[1] <= 1;
                        else
                            case (cfg_pos[5:4])
                                0: map_id0 <= file_data[6:0];
                                1: map_id1 <= file_data[6:0];
                                2: map_id2 <= file_data[6:0];
                                default: ;
                            endcase
                    end
                end
                if (cfg_pos >= 320 && cfg_pos < (cfg_extended ? 800 : 608)) begin
                    if (cfg_large && cfg_pos[3:0] == 6 && file_data > 1) cfg_errors[3] <= 1;
                    if (cfg_pos[3:0] == 0 && file_data >= resource_count) cfg_errors[1] <= 1;
                    if (cfg_pos[3:0] == 1 && cfg_point_photos &&
                        (!file_data[7] || (!cfg_extended && file_data[6]) ||
                         {1'b0, file_data[6:0]} >= resource_count))
                        cfg_errors[1] <= 1;
                    if (cfg_pos[3:0] == 3 && {file_data, previous_byte} > 1023) cfg_errors[2] <= 1;
                    if (cfg_pos[3:0] == 5 && {file_data, previous_byte} > 599) cfg_errors[2] <= 1;
                end
                if (cfg_pos >= (cfg_extended ? 1024 : 640) && cfg_pos < (cfg_extended ? 1296 : 808) &&
                    file_data[7])
                    cfg_errors[3] <= 1;
                if (cfg_pos >= 2048 && cfg_pos < 5888 && file_data >= 96) cfg_errors[3] <= 1;
                if (cfg_pos >= 832 && cfg_pos < 832 + slide_count && file_data >= resource_count)
                    cfg_errors[3] <= 1;
            end
            case (state)
                BOOT: if (mounted && fs_idle) state <= CFG_OPEN;
                CFG_OPEN: begin
                    fs_open <= 1;
                    state <= CFG_WAIT;
                end  // SITE    CFG
                CFG_WAIT:
                if (open_done_q) begin
                    if (!open_ok_q || !cfg_size_ok) begin
                        error_code <= 9;
                        state <= HALT;
                    end else begin
                        state <= CFG_READ;
                    end
                end
                CFG_READ: begin
                    // A bad FAT chain/sector can end without file_end. Abort the
                    // reader and report a config error instead of waiting forever.
                    if (fs_error != 0) begin
                        fs_abort <= 1;
                        error_code <= 9;
                        state <= HALT;
                    end else if (file_end) state <= CFG_GAP;
                end
                CFG_GAP:
                if (fs_idle) begin
                    if (cfg_sector < 53) begin
                        cfg_sector <= cfg_sector + 1'b1;
                        state <= CFG_READ;
                    end else state <= CFG_CHECK;
                end
                CFG_CHECK:
                if (!cfg_verified) begin
                    error_code <= 9;
                    state <= HALT;
                end else begin
                    config_ready <= 1;
                    background_ready <= 1;
                    state <= WAIT_REQUEST;
                end
                NAME_ADDR: begin
                    mem_addr <= (cfg_extended ? 13'd6144 : (wanted_id < 16 ? 13'd64 : 13'd3136)) +
                        ({6'd0, wanted_id} << 3) + ({6'd0, wanted_id} << 2) + name_pos;
                    state <= NAME_WAIT;
                end
                NAME_WAIT: state <= NAME_GET;
                NAME_GET: begin
                    if (name_pos == 10) state <= IMAGE_OPEN;
                    else begin
                        name_pos <= name_pos + 1'b1;
                        state <= NAME_ADDR;
                    end
                end
                IMAGE_OPEN:
                if (fs_idle) begin
                    fs_open <= 1;
                    state <= IMAGE_WAIT;
                end
                IMAGE_WAIT:
                if (open_done_q) begin
                    if (open_ok_q) state <= LOAD_BEGIN;
                    else begin
                        error_code <= 6;
                        response_ok <= 0;
                        state <= boot_image ? HALT : RESPOND;
                    end
                end
                LOAD_BEGIN:
                if (cancel_load) begin
                    response_ok <= 0;
                    state <= RESPOND;
                end else begin
                    bmp_start <= 1;
                    source_started <= 0;
                    ack_seen <= 0;
                    done_seen <= 0;
                    abort_seen <= 0;
                    timeout <= 0;
                    state <= LOAD_RUN;
                end
                LOAD_RUN: begin
                    if (!bmp_ready) source_started <= 1;
                    if (bmp_write_req && !reserved) begin
                        allocating <= 1;
                        pair_second <= 0;
                        state <= SELECT_WAIT;
                    end
                    if (write_req_ack) ack_seen <= 1;
                    if ((ack_seen || write_req_ack) && frame_done_pulse) done_seen <= 1;
                    timeout <= timeout + 1'b1;
                    if (cancel_load) begin
                        fs_abort <= 1;
                        write_abort <= 1;
                        state <= ABORT_WAIT;
                    end else if (load_complete) begin
                        valid[write_buf_idx] <= 1;
                        resource[write_buf_idx] <= wanted_id;
                        footprint[write_buf_idx] <= allocation;
                        slot_tails[write_buf_idx*3+:3] <= write_tail_idx;
                        slot_widths[write_buf_idx*11+:11] <= bmp_width;
                        slot_strides[write_buf_idx*11+:11] <= write_stride;
                        slot_heights[write_buf_idx*10+:10] <= bmp_height;
                        touch <= 1;
                        touch_slot <= write_buf_idx;
                        if (boot_image) begin
                            background_ready <= 1;
                            boot_image <= 0;
                            state <= WAIT_REQUEST;
                        end else begin
                            held[write_buf_idx] <= 1;
                            if (!phase) response_primary <= write_buf_idx;
                            else response_photo <= write_buf_idx;
                            state <= SELECT_NEXT;
                        end
                    end else if (bmp_error != 0 || timeout >= CLK_FREQ_HZ * 10 - 1 ||
                                 (fs_error != 0 && fs_error != 6)) begin
                        fs_abort <= 1;
                        write_abort <= 1;
                        state <= ABORT_WAIT;
                        error_code <= bmp_error != 0 ? bmp_error : fs_error != 0 ? fs_error : 4'hd;
                    end
                end
                ABORT_WAIT: begin
                    if (write_abort_done) abort_seen <= 1;
                    if ((abort_seen || write_abort_done) && bmp_ready && fs_idle) begin
                        response_ok <= 0;
                        state <= boot_image ? HALT : RESPOND;
                    end
                end
                WAIT_REQUEST:
                if (request_toggle != seen_request) begin
                    seen_request <= request_toggle;
                    transaction_toggle <= request_toggle;
                    transaction_tag <= request_tag;
                    reserved <= 0;
                    allocating <= 0;
                    pair_second <= 0;
                    primary_id <= request_primary;
                    photo_id <= request_photo;
                    need_photo <= request_need_photo;
                    phase <= 0;
                    wanted_id <= request_primary;
                    prefetch <= request_prefetch;
                    prefetch_keep <= request_keep;
                    response_ok <= 1;
                    held <= 0;
                    error_code <= 0;
                    state <= SELECT_WAIT;
                end
                // 分 6 拍查询槽，避免把 6 次比较串入同一组合路径；50 MHz 下扫描约 120 ns。
                SELECT_WAIT: begin
                    scan_slot <= 0;
                    hit <= 0;
                    hit_slot <= 0;
                    free_found <= 0;
                    free_slot <= 0;
                    free_invalid <= 0;
                    victim_age <= 0;
                    state <= SCAN;
                end
                SCAN: begin
                    if (valid[scan_slot] && resource[scan_slot] == wanted_id) begin
                        hit <= 1;
                        hit_slot <= scan_slot;
                    end
                    if (allocating && !(pair_second && scan_slot == pair_first) &&
                        !(candidate_mask & blocked_slots) &&
                        (!free_found || (!scan_occupied && !free_invalid) ||
                         (scan_occupied && !free_invalid && scan_age > victim_age))) begin
                        free_found <= 1;
                        free_slot <= scan_slot;
                        free_invalid <= !scan_occupied;
                        victim_age <= scan_age;
                    end
                    if (scan_slot == 5) state <= SELECT;
                    else scan_slot <= scan_slot + 1'b1;
                end
                SELECT:
                if (cancel_load) begin
                    if (allocating) begin
                        fs_abort <= 1;
                        write_abort <= 1;
                        abort_seen <= 0;
                        state <= ABORT_WAIT;
                    end else state <= RESPOND;
                    response_ok <= 0;
                end else if (wanted_bad) begin
                    response_ok <= 0;
                    error_code <= 9;
                    state <= RESPOND;
                end else if (hit && !allocating) begin
                    touch <= 1;
                    touch_slot <= hit_slot;
                    held[hit_slot] <= 1;
                    if (!phase) response_primary <= hit_slot;
                    else response_photo <= hit_slot;
                    state <= SELECT_NEXT;
                end else if (!allocating) begin
                    reserved <= 0;
                    name_pos <= 0;
                    state <= NAME_ADDR;
                end else if (free_found && need_pair && !pair_second) begin
                    pair_first <= free_slot;
                    pair_second <= 1;
                    state <= SELECT_WAIT;
                end else if (free_found && (victim_mask & blocked_slots) != 0) begin
                    pair_second <= 0;
                    state <= SELECT_WAIT;
                end else if (free_found) begin
                    write_buf_idx <= need_pair ? pair_first : free_slot;
                    write_tail_idx <= free_slot;
                    allocation <= victim_mask;
                    reserved <= 1;
                    allocating <= 0;
                    for (k = 0; k < 6; k = k + 1) if ((footprint[k] & victim_mask) != 0) valid[k] <= 0;
                    state <= LOAD_RUN;
                end else begin
                    fs_abort <= 1;
                    write_abort <= 1;
                    abort_seen <= 0;
                    response_ok <= 0;
                    state <= ABORT_WAIT;
                end
                SELECT_NEXT:
                if (!phase && need_photo) begin
                    phase <= 1;
                    wanted_id <= photo_id;
                    reserved <= 0;
                    allocating <= 0;
                    state <= SELECT_WAIT;
                end else begin
                    if (!need_photo) response_photo <= 0;
                    state <= RESPOND;
                end
                // 应答：翻转 response_toggle 使其等于本事务 toggle，broker 据此识别本笔结果。
                RESPOND: begin
                    response_toggle <= transaction_toggle;
                    state <= DECIDE;
                end
                // 等 broker 裁决。拒绝或预取：释放 held，已加载的图仍 valid，可供以后命中。
                DECIDE:
                if (decision_toggle == transaction_toggle) begin
                    if (decision_accept && response_ok && !prefetch) state <= APPLY_WAIT;
                    else begin
                        held <= 0;
                        state <= WAIT_REQUEST;
                    end
                end
                // 接受后等读控制器真正采用本笔场景（applied_tag 相同）才释放 held；
                // 此后由 applied_mask 保护正在扫描的槽，primary_pin 保护本次主图。
                APPLY_WAIT:
                if (applied_valid && applied_tag == transaction_tag) begin
                    primary_pin_valid <= 1;
                    primary_pin <= response_primary;
                    held <= 0;
                    state <= WAIT_REQUEST;
                end
                HALT: ;
                default: state <= HALT;
            endcase
            if (fs_error == 12 || (!mounted && fs_error != 0)) begin
                error_code <= fs_error;
                state <= HALT;
            end
        end
    end
    // endregion

endmodule
