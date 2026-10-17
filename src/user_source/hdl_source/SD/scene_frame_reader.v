`include "../scene_motion.v"
`include "bilinear_span_cache.v"
`timescale 1ns / 1ps
// ============================================================================
// scene_frame_reader：按屏幕顺序产生像素，运行在 ext_mem_clk（100 MHz）。
//
// 帧请求：视频域拉高 read_req，本模块应答 req_ack 并清读 FIFO；请求撤销后，
// 从 desc_stage 锁存 110 位帧描述，同时发布 applied_pulse/tag/mask。
// 描述包含槽号、场景、动画、视野、滤波和大图混合状态，一帧内保持不变。
// 槽几何和尾槽编号只采样当前段所用槽，由资源保护保证扫描期间内容稳定。
//
// 每条扫描行按区域切成 span。SOLID 输出底色，NATIVE 按 1:1 读取原生照片，
// SHRINK 用于 640×480 到 480×360，ZOOM 用 Q12 源坐标步长读取地图。
// 区域边界决定段长；根槽末端之后按 tail_base 跳到大图尾槽。
//
// SEND 连续给出读使能和地址，只有 rd_valid 返回一字时 received 才递增。
// 发起前按 FIFO 余量预留整段空间；DRAIN 等所有返回及收尾间隔完成。
// 最近邻地图缓存源像素后重复取样；双线性先水平插值上一行存暂存区，
// 再处理下一行并做垂直混合。垂直权重为零时只读一行。
//
// 大图过渡帧分两遍取得背景与原生照片，复用局部缓存保存背景 RGB565。
// 覆盖区内将两者打包进同一个 32 位 FIFO 字：高 16 位背景、低 16 位照片；
// 区域外以及稳定显示时仍用原 RGB888 字布局，后续合成器完成 alpha 混合。
//
// 意外返回、读超时或无效描述会进入 HALT 并记录 fault；新帧可在读通路
// 静默后恢复扫描，fault 保留至复位。state 使用独热码，ns[] 描述次态条件。
// ============================================================================
// region 01 接口
module scene_frame_reader #(
    parameter DYNAMIC_GEOMETRY = 0,
    SCATTERED_SLOTS = 0,
    BILINEAR_SUPPORT = 0,
    EASED_TRANSITIONS = 1,
    CROSSFADE_SUPPORT = 0
) (
    input bilinear_enabled,
    input [12:0] scene_motion,
    input [36:0] map_view,
    input [17:0] slot_tails,
    input [65:0] slot_widths, slot_strides,
    input [59:0] slot_heights,
    input clk, rst, init_done, refresh_busy, writer_busy, core_busy,
    // 帧级握手；req_ack 确认请求，applied_* 标识实际锁存的场景。
    input read_req,
    input [8:0] fifo_used,
    // SDRAM 返回接口：rd_data 只在 rd_valid 为 1 时计入本段。
    input rd_valid,
    input [31:0] rd_data,
    input slide_anim,
    input [4:0] slide_phase,
    input [2:0] slide_old,
    input scene_ready,
    input [2:0] slide_slot, bg_slot, photo_slot,
    input [7:0] panel_height,
    input photo_full, photo_blend,
    input map_mode, map_zoom,
    input [2:0] map_slot,
    input [8:0] map_x,
    input [7:0] map_y,
    input [7:0] scene_tag,
    output reg applied_pulse,
    output reg [7:0] applied_tag,
    output reg [5:0] applied_mask,
    output applied_full,
    output reg req_ack,
    output reg fifo_clear,
    output rd_en,
    output [20:0] rd_addr,
    // 读 FIFO 写端；fifo_we 与 fifo_data 同拍，过渡帧采用下述双 RGB565 布局。
    output fifo_we,
    output [31:0] fifo_data,
    output busy,
    output reg [2:0] applied_slot,
    output reg applied_valid,
    output reg fault
);
    // endregion

    // region 02 状态编码与帧描述
    // Explicit one-hot transitions keep the memory-clock control decode shallow.
    localparam [27:0] IDLE = 25'h1, ACK = 25'h2, REGION = 25'h4, SOURCE = 25'h8, SPAN = 20'h10, ADDR = 20'h20,
        CHECK = 20'h40, SEND = 20'h80, DRAIN = 20'h100, ADVANCE = 20'h200, FILL = 20'h400, REPEAT = 20'h800,
        HALT = 20'h1000, PREP = 20'h2000, LIMIT = 20'h4000, LAST = 20'h8000, FLAGS = 20'h10000,
        ENDX = 20'h20000, SCALED = 20'h40000;
    localparam SOLID = 0, NATIVE = 1, SHRINK = 2, ZOOM = 3;
    reg [2:0] slot;
    // Active slot metadata is immutable until scanout releases the slot.
    // Select only the current span's metadata, then sample it twice. REGION
    // selects the slot; SPAN consumes geometry six clocks later. This avoids
    // replicating all six cache entries in three banks of memory-clock flops.
    reg [31:0] source_meta, source_sync;
    reg [2:0] tail_meta, tail_sync;
    reg [20:0] tail_base, tail_adjust, head_end, logical_address, head_address, tail_address;
    reg second_segment;
    reg [9:0] clamped_first, clamped_last;
    reg map_outside;
    wire [10:0] source_width = DYNAMIC_GEOMETRY ? source_sync[21:11] : 11'd640;
    wire [10:0] source_stride = DYNAMIC_GEOMETRY ? source_sync[10:0] : 11'd640;
    wire [9:0] source_height = DYNAMIC_GEOMETRY ? source_sync[31:22] : 10'd480;
    reg [28:0] state;
    reg [1:0] req_sync;
    reg [109:0] desc_meta, desc_sync, desc_stage, desc;
    reg overlay_pass, blend_inside;
    reg [9:0] blend_end;
    wire blend_capture = desc[109] && blend_inside && !overlay_pass;
    wire layout_full = desc[17] || overlay_pass;
    wire [15:0] blend_pixel;
    // 已锁存帧描述中的 full 状态，保持到下一次接帧；当前调度器保留此反馈端口。
    assign applied_full = desc[17];
    reg [5:0] mask_stage;
    reg [9:0] next_x;
    reg [7:0] last_emit;
    reg fifo_room_output, fifo_room_read, fifo_room_filter;
    always @(posedge clk or posedge rst)
        if (rst) begin
            fifo_room_output <= 0;
            fifo_room_read <= 0;
            fifo_room_filter <= 0;
        end else begin
            fifo_room_output <= fifo_used < 9'd479;
            fifo_room_read <= fifo_used < 9'd439;
            fifo_room_filter <= fifo_used < 9'd359;
        end
    wire [5:0] descriptor_mask = !desc_sync[18] ?
        6'd0 : ((6'b1 << (desc_sync[19] ? desc_sync[23:21] : desc_sync[2:0])) |
                (desc_sync[16:9] != 0 ? (6'b1 << desc_sync[8:6]) : 6'd0) |
                (!desc_sync[19] && desc_sync[57] ? (6'b1 << desc_sync[51:49]) : 6'd0));
    wire [109:0] descriptor = {
        CROSSFADE_SUPPORT && photo_blend,
        BILINEAR_SUPPORT && bilinear_enabled,
        scene_motion,
        map_view,
        slide_anim,
        slide_phase,
        slide_old,
        scene_tag,
        map_y,
        map_x,
        map_slot,
        map_zoom,
        map_mode,
        scene_ready,
        photo_full,
        panel_height,
        photo_slot,
        bg_slot,
        slide_slot
    };
    `include "../eased_motion_table.vh"
    // endregion

    // region 03 屏幕坐标、源图坐标与边界
    reg [9:0] x, y, lx, ly, sx, sy, last_sx, last_lx, edge_delta, edge_reg, photo_top, photo_bottom;
    reg [9:0] vx, vy, blank_end;
    reg view_valid;
    reg signed [11:0] horizontal_shift, physical_edge;
    reg [9:0] axis_position;
    reg motion_affected;
    reg signed [11:0] motion_addend, motion_delta, translated;
    wire [8:0] panel_remaining = 9'd210 - {1'b0, desc[16:9]};
    wire [9:0] panel_drop = {panel_remaining, 1'b0} + (panel_remaining >> 1);
    wire [9:0] photo_y = vy - panel_drop;
    reg photo_row, map_row, carousel_row, full_row, before_boundary;
    reg photo_hit, map_hit, carousel_hit, full_hit;
    reg [9:0] background_edge;
    reg before_photo, before_native, before_native_end;
    reg [9:0] logical_edge;
    reg [9:0] qx, qy, qlast, zx, zy, zlast;

    reg [1:0] mode, phase, region_mode;
    reg [7:0] span_pixels, emitted;
    reg [7:0] span_words, sent, received, target, last_word;
    reg drained, watchdog_near, watchdog_expired;
    reg [20:0] address, row_offset;
    reg [20:0] row_product;  // 下一拍 SPAN 使用的行首偏移
    reg [4:0] quiet;
    reg [11:0] watchdog;
    wire [31:0] zoom_q;
    // The full declared input domain needs at most 26 signed bits:
    // center <= 4095*2048, delta <= 703*16383, plus 127 steps.
    // This retains the Q12 fraction without a redundant three-bit carry tail.
    reg signed [25:0] map_fx, map_fy, map_lfx, map_emit;
    reg signed [10:0] map_dx, map_dy, map_ldx;
    reg signed [25:0] map_product_x, map_product_y, map_product_last;
    wire [13:0] map_step = desc[94:81];
    wire signed [25:0] cx_fixed = $signed({1'b0, desc[80:69], 11'b0});
    wire signed [25:0] cy_fixed = $signed({1'b0, desc[68:58], 11'b0});
    wire signed [25:0] source_limit = $signed({1'b0, source_width, 12'b0});
    wire signed [25:0] height_limit = $signed({1'b0, source_height, 12'b0});
    reg [10:0] source_last_x, last_received_x;
    // 与 map_fx/map_lfx 同拍计算越界标志，避免把宽比较器放到后续像素选择路径。
    // source_limit 的低 12 位为零；中心使用半像素单位，预先寄存 limit_minus_cx，
    // 再比较 map_product_[x/last] 的高位。坐标为负直接检查符号位。
    reg signed [13:0] limit_minus_cx;
    reg fx_over, lfx_over;
    wire [9:0] first_map_x = map_fx[25] ? 0 : fx_over ? source_last_x[9:0] : map_fx >>> 12;
    wire [9:0] last_map_x = map_lfx[25] ? 0 : lfx_over ? source_last_x[9:0] : map_lfx >>> 12;
    wire [7:0] map_index = (map_emit >>> 12) - {sx[9:2], 2'b0};
    wire signed [25:0] map_next = map_emit + $signed({1'b0, map_step});
    wire [7:0] zoom_prefetch_index = (state[11] && fifo_room_output) ? ((map_next >>> 12) - {sx[9:2], 2'b0}) :
        map_index;
    // Source bounds are integer pixels; the Q12 fractional bits never enter
    // the comparison. Reject high/sign bits before the bounded width compare.
    // map_valid 与 map_emit 的更新保持配套：载入起点时用符号位及 fx_over；
    // 前进时比较 -step <= map_emit < source_limit-step，两个边界先寄存。
    // 这样采样有效性不再等待坐标加法、宽比较和像素选择串行完成。
    reg map_valid;
    reg signed [14:0] neg_step;
    reg signed [23:0] limit_minus_step;
    wire map_pixel_valid = map_valid;

    wire [4:0] zoom_index = emitted[5:2] * 3 + ({1'b0, emitted[1:0]} * 3 >> 2);
    wire returning = (state[7] || state[8]) && received < sent;
    wire [1:0] shrink_y_phase = ly[1:0] - qy[1:0] * 2'd3;
    // Mixed frames use nearest sampling for the retained detail layer. This
    // leaves the existing interpolation scratch RAM available and bounds SDRAM
    // bandwidth while two layouts are read. Stable views keep the selected filter.
    // For the mixed map layer, zero interpolation fractions reuse the streaming
    // sampler as a nearest sampler. This overlaps source returns with output;
    // waiting for the whole map span and then REPEAT would exhaust FIFO headroom.
    // endregion

    // region 04 最近邻和双线性采样控制
    wire filter_active = BILINEAR_SUPPORT &&
        ((desc[109] && blend_inside) ? mode == ZOOM : desc[108] && (mode == SHRINK || mode == ZOOM));
    // Mode settles in REGION/SPAN, several setup clocks before SEND. Decode
    // the return destination early so mode/filter decode is not in the SDRAM
    // response-to-counter/cache enable path. No returned pixel is delayed.
    reg direct_read;
    always @(posedge clk) direct_read <= !filter_active && mode != ZOOM;
    reg second_pass, filter_running, filter_pending;
    reg [7:0] filter_issued, top_emitted, filter_fy;
    reg [9:0] filter_sx;
    reg [1:0] filter_phase;
    // 垂直权重为零时省去下一行读取。filter_fy 在地址准备阶段确定，
    // single_row 延迟一拍后才供 SEND/DRAIN 和采样控制使用。
    reg single_row;
    // Out-of-map samples become padding, so their cache address is irrelevant.
    // Keep visibility and availability checks parallel: clamping a coordinate,
    // adding its neighbour and comparing returned words in series is too slow.
    always @(posedge clk) source_last_x <= source_width - 11'd1;
    wire [9:0] filter_raw_x = mode == ZOOM ? map_emit[21:12] : filter_sx;
    wire [7:0] filter_offset = filter_raw_x[7:0] - {sx[7:2], 2'b0};
    wire [7:0] filter_right_offset = filter_offset + ({1'b0, filter_raw_x} == source_last_x ? 8'd0 : 8'd1);
    wire filter_inside = mode != ZOOM || map_pixel_valid;
    // The delayed sample_inside flag selects padding at the cache output.
    // Out-of-image RAM addresses are therefore don't-care values; removing
    // these two muxes keeps the bounds comparator off the RAM address path.
    wire [7:0] filter_left = filter_offset;
    wire [7:0] filter_right = filter_right_offset;
    // Compare both coordinate sources in parallel, then select their ready bit.
    // Keeping these cones separate removes the mode mux from the comparator input.
    (* keep *)
    wire map_data_ready = last_received_x > {1'b0, map_emit[21:12]} ||
        ({1'b0, map_emit[21:12]} == source_last_x && last_received_x == {1'b0, map_emit[21:12]});
    (* keep *) wire photo_data_ready = last_received_x > {1'b0, filter_sx} ||
        ({1'b0, filter_sx} == source_last_x && last_received_x == {1'b0, filter_sx});
    wire filter_data_ready = received != 0 && (mode == ZOOM ? map_data_ready : photo_data_ready);
    wire [7:0] span_first_group = mode == ZOOM ? clamped_first[9:2] : sx[9:2];
    wire [7:0] span_groups = clamped_last[9:2] - span_first_group + 8'd1;
    wire [7:0] filter_fx = (desc[109] && blend_inside) ? 8'd0 :
        mode == ZOOM ? map_emit[11:4] : filter_phase == 0 ? 8'd0 : filter_phase == 1 ? 8'd85 : 8'd171;
    wire filter_sample = filter_active && filter_running && filter_pending &&
        (!filter_inside || filter_data_ready) && ((!second_pass && !single_row) || fifo_room_output) &&
        !(state[28] && req_sync[1]);
    wire filtered_valid, top_written;
    wire [31:0] filtered_data;
    wire filter_done = emitted == span_pixels;
    wire top_done = top_emitted == span_pixels;
    // next_x/edge_reg settle many clocks before ADVANCE consumes this flag.
    reg fast_span;
    always @(posedge clk) fast_span <= !desc[109] && next_x < edge_reg && next_x < 10'd800;
    wire keep = direct_read && received == target && emitted < span_pixels;
    reg [9:0] boundary, slide_offset, old_origin;
    reg [9:0] edge_x, gx, gy;
    reg [9:0] x8, x80, x320, x288, xbound, xold, y60, y56, y48, y120;
    always @(posedge clk) begin
        x8 <= vx - 10'd8;
        x80 <= vx - 80;
        x320 <= vx - 304;
        x288 <= vx - 288;
        xbound <= vx - boundary;
        xold <= vx + old_origin;
        y60 <= vy - 60;
        y56 <= vy - 56;
        y48 <= vy - 64;
        y120 <= photo_y - 136;
    end
    reg [1:0] gm;
    reg [2:0] gs;
    // Region boundaries are also burst boundaries; a panel never leaks map
    // addresses into its photo and an animation never mixes its two slots.
    always @* begin
        edge_x = 800;
        gx = 0;
        gy = 0;
        gm = SOLID;
        gs = 0;
        // Background boundaries are registered alongside the hit tests. The
        // following priority stage only clips against the two photo rectangles.
        edge_x = background_edge;
        if (photo_row && before_photo && background_edge > 288) edge_x = 288;
        if (photo_hit) edge_x = 768;
        if (full_hit) edge_x = 720;
        // A mixed span must lie completely inside or outside the native photo.
        // The second pass reuses exactly the first pass length and scratch indices.
        if ((desc[109] || desc[17]) && !overlay_pass && full_row) begin
            if (before_native && edge_x > 80) edge_x = 80;
            else if (before_native_end && edge_x > 720) edge_x = 720;
        end
        // The capture pass already clipped this span to the native rectangle.
        if (overlay_pass) edge_x = blend_end;
        // The hit tests were registered in the existing FLAGS stage. Slot/mode
        // and coordinate selection therefore share one short priority mux, without an extra
        // scanout cycle or a coordinate comparator on the slot-register input.
        if (full_hit) begin
            gm = NATIVE;
            gs = desc[8:6];
            gx = x80;
            gy = y60;
        end else if (photo_hit) begin
            gm = SHRINK;
            gs = desc[8:6];
            gx = x288;
            gy = y120;
        end else if (map_hit) begin
            gm = ZOOM;
            gs = desc[23:21];
            gx = x8;
            gy = y56;
        end else if (carousel_hit) begin
            gm = SHRINK;
            gs = desc[57] && before_boundary ? desc[51:49] : desc[2:0];
            gx = desc[57] ? (before_boundary ? xold : xbound) : x320;
            gy = y48;
        end
    end
    // endregion

    // region 05 物理槽地址、局部缓存与 FIFO 输出
    function [20:0] base;
        input [2:0] idx;
        begin
            case (idx)
                0: base = 0;
                1: base = 307200;
                2: base = 614400;
                3: base = 921600;
                4: base = 1228800;
                5: base = 1536000;
                default: base = 0;
            endcase
        end
    endfunction
    assign rd_en = state[7];
    assign rd_addr = address;
    assign busy = state[7] || state[8];
    // Register both the pixel and its enable before the asynchronous FIFO.
    // The 32-word headroom also covers this one pending output word.
    wire push_pixel = ((state[10] || state[11]) && fifo_room_output) || (rd_valid && returning && keep) ||
        filtered_valid;
    wire [31:0] padding = desc[19] ? 32'hdadcd900 : 32'hf3f5f900;
    wire [31:0] push_data = filtered_valid ? filtered_data :
        state[10] ? padding : state[11] ? (map_pixel_valid ? zoom_q : padding) : rd_data;
    reg capture_pending;
    reg [6:0] capture_index;
    reg pixel_pending, pixel_paired, pixel_overlay;
    reg [31:0] pixel_data;
    // Stage scratch writes after pixel selection. This separates the SDRAM
    // outstanding-count comparison from the RAM's write-enable timing cone.
    always @(posedge clk or posedge rst)
        if (rst) capture_pending <= 0;
        else capture_pending <= push_pixel && blend_capture && !fifo_clear;
    always @(posedge clk) capture_index <= emitted[6:0];
    bilinear_span_cache #(
        .CROSSFADE_SUPPORT(CROSSFADE_SUPPORT)
    ) filter_cache (
        .blend_write(capture_pending),
        .blend_read(overlay_pass),
        .blend_write_index(capture_index),
        .blend_index(emitted[6:0]),
        .blend_data(pixel_data),
        .blend_pixel(blend_pixel),
        .clk(clk),
        .rst(rst),
        .clear(fifo_clear || state[12]),
        .write_enable(rd_valid && returning && !direct_read),
        .write_index(received),
        .write_data(rd_data),
        .nearest_index(zoom_prefetch_index),
        .nearest_data(zoom_q),
        .bilinear_mode(filter_active),
        .sample_valid(filter_sample),
        .sample_bottom(second_pass),
        .sample_inside(filter_inside),
        .sample_left(filter_left),
        .sample_right(filter_right),
        .sample_number(filter_issued),
        .fraction_x(filter_fx),
        .fraction_y(filter_fy),
        .padding(padding),
        .top_written(top_written),
        .pixel_valid(filtered_valid),
        .pixel_data(filtered_data)
    );
    wire [15:0] packed_pixel = {pixel_data[31:27], pixel_data[23:18], pixel_data[15:11]};
    assign fifo_we = pixel_pending && !fifo_clear;
    // Only transition frames carry two RGB565 pixels in the existing 32-bit FIFO.
    // Normal detail and the settled full photo retain the original RGB888 word.
    assign fifo_data = !pixel_paired ? pixel_data :
        pixel_overlay ? {blend_pixel, packed_pixel} : {packed_pixel, 16'hffbe};
    always @(posedge clk) begin
        pixel_paired <= desc[109] && blend_inside;
        pixel_overlay <= overlay_pass;
    end
    always @(posedge clk or posedge rst)
        if (rst) pixel_pending <= 0;
        else if (fifo_clear) pixel_pending <= 0;
        else pixel_pending <= push_pixel && !blend_capture;
    // Invalid data need not be held/reset. Removing its CE avoids routing
    // the full pixel-valid comparison onto every data-register enable.
    always @(posedge clk) pixel_data <= push_data;
    // endregion

    // region 06 请求跨域、几何采样与地址流水线
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            req_sync <= 0;
            desc_meta <= 0;
            desc_sync <= 0;
            desc_stage <= 0;
            mask_stage <= 0;
            tail_meta <= 0;
            tail_sync <= 0;
            source_meta <= {10'd480, 11'd640, 11'd640};
            source_sync <= {10'd480, 11'd640, 11'd640};
        end else begin
            req_sync <= {req_sync[0], read_req};
            desc_meta <= descriptor;
            desc_sync <= desc_meta;
            desc_stage <= desc_sync;
            mask_stage <= descriptor_mask;
            tail_meta <= slot_tails[slot*3+:3];
            tail_sync <= tail_meta;
            source_meta <= {slot_heights[slot*10+:10], slot_widths[slot*11+:11], slot_strides[slot*11+:11]};
            source_sync <= source_meta;
        end
    end

    // Free-running arithmetic settles while the region/span states advance.
    // The consumer still waits through SOURCE/SCALED/PREP, so no stale result
    // is consumed. Unconditional DSP/data registers avoid reset/enable muxes.
    always @(posedge clk) begin
        map_dx <= $signed({1'b0, lx}) - 11'sd320;
        map_dy <= $signed({1'b0, ly}) - 11'sd240;
        map_ldx <= $signed({1'b0, last_lx}) - 11'sd320;
        qx <= lx / 10'd3;
        qy <= ly / 10'd3;
        qlast <= last_lx / 10'd3;
        map_product_x <= map_dx * $signed({1'b0, map_step});
        map_product_last <= map_ldx * $signed({1'b0, map_step});
        map_product_y <= map_dy * $signed({1'b0, map_step});
        map_fx <= cx_fixed + map_product_x;
        map_lfx <= cx_fixed + map_product_last;
        map_fy <= cy_fixed + map_product_y;
        // 越界标志与 map_fx/map_lfx 同拍得到。
        limit_minus_cx <= $signed({2'b0, source_width, 1'b0}) - $signed({1'b0, desc[80:69]});
        fx_over <= $signed(map_product_x[25:11]) >= limit_minus_cx;
        lfx_over <= $signed(map_product_last[25:11]) >= limit_minus_cx;
        // 下一采样位置仍在图内的两个边界。
        neg_step <= -$signed({1'b0, map_step});
        limit_minus_step <= $signed({1'b0, source_width, 12'b0}) - $signed({1'b0, map_step});
        // 下一行读取是否可以省略。
        single_row <= filter_fy == 0;
        // SPAN(state[4]) 所需的行首偏移提前一拍算好。state[4] 只能由
        // PREP(state[27]) 进入，其间 mode、sy、map_fy 与 source_stride 均不变。
        row_product <= (mode == ZOOM ? map_fy[21:12] : sy) * source_stride;
    end
    always @(posedge clk) begin
        tail_base <= base(tail_sync);
        tail_adjust <= base(tail_sync) - 21'd307200;
        head_end <= base(slot) + 21'd307199;
    end
    // endregion

    // region 07 状态转换与异常边界
    wire fatal_now = (rd_valid && !returning) || watchdog_expired;
    wire invalid_desc = desc_stage[18] && (desc_stage[2:0] >= 6 || desc_stage[8:6] >= 6 || desc_stage[
                                           23:21] >= 6 || (desc_stage[57] && desc_stage[51:49] >= 6));
    wire check_fill = mode == SOLID && fifo_room_read;
    wire check_send = ((filter_active || desc[109]) ? fifo_room_filter : fifo_room_read) && !writer_busy &&
        !refresh_busy && !core_busy;
    wire end_span = fifo_room_output && emitted == last_emit;
    wire end_read = drained && quiet >= 10;
    wire recover_frame = state[12] && req_sync[1] && quiet >= 16 && !core_busy && !refresh_busy && !rd_valid;
    wire [28:0] ns;
    assign
        ns[0] = (state[0] && !(req_sync[1] && init_done)) || (state[1] && !req_sync[1] && !desc_stage[18]) ||
        (state[9] && !req_sync[1] && !blend_capture && next_x == 800 && y == 599);
    assign ns[1] = (state[0] && req_sync[1] && init_done) || (state[1] && req_sync[1]) ||
        ((state[6] || state[9] || state[10] || state[11] || state[28]) && req_sync[1]) || recover_frame;
    assign ns[2] = state[23];
    assign ns[19] = state[16];
    assign ns[22] = state[19];
    assign ns[23] = state[22];
    assign ns[3] = state[17];
    assign ns[24] = state[18];
    assign ns[27] = state[24];
    assign ns[4] = state[27];
    assign ns[5] = state[4] ||
        (state[8] && end_read && filter_active && !single_row && !second_pass && top_done);
    assign ns[25] = state[5];
    assign ns[26] = state[25];
    assign ns[6] = state[26] || (state[6] && !req_sync[1] && !check_fill && !check_send);
    assign ns[7] = (state[6] && !req_sync[1] && !check_fill && check_send) || (state[7] && sent != last_word);
    assign ns[8] = (state[7] && sent == last_word) ||
        (state[8] && (!end_read || (filter_active && !single_row && !second_pass && !top_done)));
    assign ns[9] = ((state[10] || state[11]) && end_span && !req_sync[1]) ||
        (state[8] && end_read && !filter_active && mode != ZOOM) ||
        (state[8] && end_read && filter_active && (second_pass || single_row) && filter_done) ||
        (state[28] && filter_done && !req_sync[1]);
    assign ns[10] = (state[6] && !req_sync[1] && check_fill) || (state[10] && !end_span && !req_sync[1]);
    assign ns[11] = (state[8] && end_read && mode == ZOOM && !filter_active) ||
        (state[11] && !end_span && !req_sync[1]);
    assign ns[28] = (state[8] && end_read && filter_active && (second_pass || single_row) && !filter_done) ||
        (state[28] && !filter_done && !req_sync[1]);
    assign ns[12] = (state[12] && !recover_frame) || (state[1] && !req_sync[1] && invalid_desc);
    assign ns[13] = state[1] && !req_sync[1] && desc_stage[18] && !invalid_desc;
    assign ns[20] = state[2];
    assign ns[21] = state[20];
    assign ns[14] = state[21];
    assign ns[15] = state[14] || (state[9] && !req_sync[1] && fast_span);
    assign ns[16] = state[13] ||
        (state[9] && !req_sync[1] && (blend_capture || (!fast_span && !(next_x == 800 && y == 599))));
    assign ns[17] = state[15];
    assign ns[18] = state[3];
    always @(posedge clk or posedge rst)
        if (rst) state <= IDLE;
        else state <= fatal_now ? HALT : ns;

    // endregion

    // region 08 各状态的数据寄存与扫描推进
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            overlay_pass <= 0;
            blend_inside <= 0;
            blend_end <= 0;
            photo_hit <= 0;
            background_edge <= 800;
            before_photo <= 0;
            before_native <= 0;
            before_native_end <= 0;
            map_hit <= 0;
            carousel_hit <= 0;
            full_hit <= 0;
            last_received_x <= 0;
            region_mode <= SOLID;
            second_pass <= 0;
            filter_running <= 0;
            filter_pending <= 0;
            filter_issued <= 0;
            top_emitted <= 0;
            filter_fy <= 0;
            filter_sx <= 0;
            filter_phase <= 0;
            before_boundary <= 0;
            logical_edge <= 800;
            logical_address <= 0;
            head_address <= 0;
            tail_address <= 0;
            second_segment <= 0;
            clamped_first <= 0;
            clamped_last <= 0;
            map_outside <= 0;
            axis_position <= 0;
            motion_affected <= 0;
            motion_addend <= 0;
            motion_delta <= 0;
            translated <= 0;

            vx <= 0;
            vy <= 0;
            blank_end <= 800;
            view_valid <= 0;
            horizontal_shift <= 0;
            physical_edge <= 800;
            map_emit <= 0;
            map_valid <= 1;  // 初始 map_emit=0 位于默认宽度 640 内
            next_x <= 0;
            last_emit <= 0;
            desc <= 0;
            req_ack <= 0;
            fifo_clear <= 1;
            applied_slot <= 0;
            applied_valid <= 0;
            applied_pulse <= 0;
            applied_tag <= 0;
            applied_mask <= 0;
            fault <= 0;
            x <= 0;
            y <= 0;
            lx <= 0;
            ly <= 0;
            sx <= 0;
            sy <= 0;
            last_sx <= 0;
            last_lx <= 0;
            edge_delta <= 0;
            edge_reg <= 0;
            photo_top <= 300;
            photo_bottom <= 300;
            photo_row <= 0;
            map_row <= 0;
            carousel_row <= 0;
            full_row <= 0;
            boundary <= 800;
            slide_offset <= 0;
            old_origin <= 0;
            slot <= 0;
            mode <= 0;
            phase <= 0;
            span_pixels <= 32;
            emitted <= 0;
            span_words <= 32;
            sent <= 0;
            received <= 0;
            target <= 0;
            address <= 0;
            row_offset <= 0;
            quiet <= 0;
            watchdog <= 0;
            last_word <= 31;
            drained <= 0;
            watchdog_near <= 0;
            watchdog_expired <= 0;

        end else begin
            applied_pulse <= 0;
            if (fifo_clear || state[9] || state[12]) filter_running <= 0;
            if (top_written) top_emitted <= top_emitted + 1'b1;
            if (filtered_valid) emitted <= emitted + 1'b1;
            if (filter_sample) begin
                // Stop on the final accepted sample. The registered budget bit removes
                // the span-length comparator from every sample consumer's enable path.
                if (filter_issued == last_emit) filter_pending <= 0;
                filter_issued <= filter_issued + 1'b1;
                if (mode == ZOOM) begin
                    map_emit <= map_next;
                    map_valid <= map_emit >= neg_step && map_emit < limit_minus_step;
                end else begin
                    filter_sx <= filter_sx + (filter_phase == 2 ? 2 : 1);
                    filter_phase <= filter_phase == 2 ? 0 : filter_phase + 1'b1;
                end
            end
            drained <= received == span_words;
            watchdog_near <= watchdog == 4093 && !rd_valid;
            watchdog_expired <= watchdog_near && !rd_valid;
            if (rd_en || (state[12] && (rd_valid || core_busy || refresh_busy))) quiet <= 0;
            else if (quiet < 31) quiet <= quiet + 1'b1;
            if (state[8] && received != span_words && !rd_valid) watchdog <= watchdog + 1'b1;
            else watchdog <= 0;
            if (rd_valid && returning) begin
                received <= received + 1'b1;
                last_received_x <= last_received_x + 1'b1;
                if (keep) begin
                    emitted <= emitted + 1'b1;
                    target <= target + ((mode == SHRINK && phase == 2) ? 2 : 1);
                    if (mode == SHRINK) phase <= phase == 2 ? 0 : phase + 1'b1;
                end
            end
            (* parallel_case *) case (1'b1)
                state[0]:
                if (req_sync[1] && init_done) begin
                    req_ack <= 1;
                    fifo_clear <= 1;
                end
                state[1]:
                if (!req_sync[1]) begin
                    req_ack <= 0;
                    fifo_clear <= 0;
                    desc <= desc_stage;
                    overlay_pass <= 0;
                    x <= 0;
                    y <= 0;
                    applied_slot <= desc_stage[2:0];
                    applied_valid <= desc_stage[18];
                    applied_pulse <= 1;
                    applied_tag <= desc_stage[48:41];
                    applied_mask <= mask_stage;
                    slide_offset <= EASED_TRANSITIONS ? eased_slide_position(
                        desc_stage[56:52]
                    ) : ({1'b0, desc_stage[56:52], 4'b0} + {2'b0, desc_stage[56:52], 3'b0});

                    if (desc_stage[18] && (desc_stage[2:0] >= 6 || desc_stage[8:6] >= 6 || desc_stage[
                                           23:21] >= 6 || (desc_stage[57] && desc_stage[51:49] >= 6))) begin
                        fault <= 1;
                        applied_valid <= 0;
                        applied_mask <= 0;
                    end
                end
                state[13]: begin
                    boundary <= 784 - slide_offset;
                    old_origin <= slide_offset - 304;
                    photo_top <= 136 + panel_drop;
                    photo_bottom <= 496 + panel_drop;
                    motion_addend <= desc[106] ? $signed(
                        {2'b0, desc[104:95]}
                    ) : -$signed(
                        {2'b0, desc[104:95]}
                    );
                    motion_delta <= desc[106] ? -$signed(
                        {2'b0, desc[104:95]}
                    ) : $signed(
                        {2'b0, desc[104:95]}
                    );
                end
                state[16]: begin
                    axis_position <= desc[107] ? y : x;
                    motion_affected <= desc[105] && y < 568 &&
                        (!desc[107] || (x >= 8 && x < 648 && y >= 56 && y < 536));
                end
                state[19]: translated <= $signed({2'b0, axis_position}) + motion_addend;
                state[22]: begin
                    vx <= motion_affected && !desc[107] ? translated[9:0] : x;
                    vy <= motion_affected && desc[107] ? translated[9:0] : y;
                    view_valid <= !motion_affected ||
                        (desc[107] ? (translated >= 12'sd56 && translated < 12'sd536) :
                         (translated >= 0 && translated < 12'sd800));
                    blank_end <= motion_affected && !desc[107] && translated < 0 ?
                        desc[104:95] : (desc[107] ? 10'd648 : 10'd800);
                    horizontal_shift <= motion_affected && !desc[107] ? motion_delta : 12'sd0;
                end
                state[23]: begin
                    before_boundary <= vx < boundary;
                    photo_row <= desc[16:9] != 0 && vy >= photo_top && vy < photo_bottom && y < 568;
                    map_row <= desc[19] && vy >= 56 && vy < 536;
                    carousel_row <= !desc[19] && vy >= 64 && vy < 424;
                    full_row <= vy >= 60 && vy < 540;
                    blend_inside <= vy >= 60 && vy < 540 && vx >= 80 && vx < 720;
                    full_hit <= layout_full && vy >= 60 && vy < 540 && vx >= 80 && vx < 720;
                    photo_hit <= desc[16:9] != 0 && vy >= photo_top && vy < photo_bottom && y < 568 &&
                        vx >= 288 && vx < 768;
                    map_hit <= desc[19] && vy >= 56 && vy < 536 && vx >= 8 && vx < 648;
                    carousel_hit <= !desc[19] && vy >= 64 && vy < 424 && vx >= 304 && vx < 784;
                    before_photo <= vx < 288;
                    before_native <= vx < 80;
                    before_native_end <= vx < 720;
                    if (desc[19] && vy >= 56 && vy < 536 && vx < 648)
                        background_edge <= vx < 8 ? 10'd8 : 10'd648;
                    else if (!desc[19] && vy >= 64 && vy < 424 && vx < 784)
                        background_edge <= vx < 304 ?
                            10'd304 : (desc[57] && vx < boundary) ? boundary : 10'd784;
                    else background_edge <= 800;
                end
                state[2]: begin
                    lx <= gx;
                    ly <= gy;
                    mode <= view_valid ? gm : SOLID;
                    region_mode <= view_valid ? gm : SOLID;
                    slot <= gs;
                    logical_edge <= edge_x;
                    second_pass <= 0;
                end
                // Keep translation, region selection, edge addition, clipping and length
                // subtraction in separate cycles. All arithmetic is explicitly bounded.
                state[20]: physical_edge <= $signed({2'b0, logical_edge}) + horizontal_shift;
                state[21]:
                edge_reg <= !view_valid ?
                    blank_end : (physical_edge > 12'sd800 ? 10'd800 : physical_edge[9:0]);
                state[14]: begin
                    edge_delta <= edge_reg - x;
                end
                state[15]: begin
                    span_pixels <= edge_delta < ((filter_active || desc[109]) ? 128 : 64) ?
                        edge_delta : ((filter_active || desc[109]) ? 128 : 64);
                    second_pass <= 0;
                end
                state[17]: begin
                    next_x <= x + span_pixels;
                    last_emit <= span_pixels - 1'b1;
                    last_lx <= lx + span_pixels - 1'b1;
                end

                state[18]: begin
                    case (mode)
                        SHRINK: begin
                            sx <= lx + qx;
                            sy <= ly + qy;
                            last_sx <= last_lx + qlast;
                            phase <= lx[1:0] - qx[1:0] * 2'd3;
                            filter_fy <= shrink_y_phase == 0 ? 0 : shrink_y_phase == 1 ? 85 : 171;
                        end
                        ZOOM: ;
                        default: begin
                            sx <= lx;
                            sy <= ly;
                            last_sx <= last_lx;
                            phase <= 0;
                        end
                    endcase
                end

                state[27]: begin
                    clamped_first <= first_map_x;
                    clamped_last <= mode == ZOOM ? last_map_x : last_sx;
                    // Both map and photo coordinates have settled in earlier setup cycles.
                    // Reuse this flag for every mode, keeping range comparisons off mode's
                    // high-fanout register input in the following SPAN cycle.
                    map_outside <= mode == ZOOM ?
                        (map_fy < 0 || map_fy >= height_limit || map_lfx[25] || fx_over) :
                        (sy >= source_height || last_sx >= source_width);
                end
                state[4]: begin
                    // The raw clamp, neighbour extension and aligned length occupy separate
                    // existing setup clocks; the SDRAM issue schedule is unchanged.
                    clamped_last <= clamped_last +
                        (filter_active && clamped_last < source_last_x ? 10'd1 : 10'd0);
                    // 行首乘积已在准备阶段寄存，本拍直接使用 row_product。
                    row_offset <= row_product;
                    if (mode == ZOOM) begin
                        sx <= {clamped_first[9:2], 2'b0};
                        sy <= map_fy[21:12];
                        filter_fy <= (desc[109] && blend_inside) ? 8'd0 : map_fy[11:4];
                    end else begin
                        target <= {5'd0, sx[1:0]};
                    end
                    if (map_outside) mode <= SOLID;
                end
                state[5]: begin
                    span_words <= {span_groups[5:0], 2'b0};
                    logical_address <= row_offset + {sx[9:2], 2'b00};
                end
                state[25]: begin
                    last_word <= span_words - 1'b1;
                    head_address <= base(slot) + logical_address;
                    tail_address <= tail_adjust + logical_address;
                    second_segment <= SCATTERED_SLOTS && logical_address >= 21'd307200;
                end
                state[26]: address <= second_segment ? tail_address : head_address;
                state[6]:
                if (req_sync[1]) begin
                    req_ack <= 1;
                    fifo_clear <= 1;
                end else if (mode == SOLID && fifo_room_read) begin
                    emitted <= 0;
                end else if (check_send) begin
                    sent <= 0;
                    received <= 0;
                    emitted <= 0;
                    map_emit <= map_fx;
                    map_valid <= !map_fx[25] && !fx_over;
                    last_received_x <= {1'b0, sx[9:2], 2'b0} - 11'd1;
                    filter_pending <= span_pixels != 0;
                    filter_issued <= 0;
                    filter_sx <= sx;
                    filter_phase <= phase;
                    filter_running <= filter_active;
                    if (!second_pass) top_emitted <= 0;
                end
                (state[10] | state[11]):
                if (req_sync[1]) begin
                    req_ack <= 1;
                    fifo_clear <= 1;
                end else if (fifo_room_output) begin
                    emitted <= emitted + 1'b1;
                    if (state[11]) begin
                        map_emit <= map_emit + $signed({1'b0, map_step});
                        map_valid <= map_emit >= neg_step && map_emit < limit_minus_step;
                    end
                end
                // No memory responses remain in FILTER_WAIT. A new frame may discard the
                // unfinished old span even if its output FIFO has stopped being consumed.
                state[28]:
                if (req_sync[1]) begin
                    req_ack <= 1;
                    fifo_clear <= 1;
                end
                state[7]: begin
                    sent <= sent + 1'b1;
                    address <= SCATTERED_SLOTS && address == head_end ? tail_base : address + 1'b1;
                end
                state[8]:
                if (end_read && filter_active && !single_row && !second_pass && top_done) begin
                    second_pass <= 1;
                    filter_running <= 0;
                    if (sy < source_height - 1) row_offset <= row_offset + source_stride;
                end
                state[9]:
                if (req_sync[1]) begin
                    req_ack <= 1;
                    fifo_clear <= 1;
                end else if (blend_capture) begin
                    overlay_pass <= 1;
                    blend_end <= next_x;
                end else if (next_x == 800) begin
                    overlay_pass <= 0;
                    x <= 0;
                    if (y != 599) begin
                        y <= y + 1'b1;
                    end
                end else begin
                    overlay_pass <= 0;
                    x <= next_x;
                    if (fast_span) begin
                        lx <= lx + span_pixels;
                        edge_delta <= edge_reg - next_x;
                        mode <= region_mode;
                    end
                end
                state[12]: begin
                    req_ack <= recover_frame;
                    fifo_clear <= 1;
                    applied_valid <= 0;
                end
                default:   ;
            endcase
            if ((rd_valid && !returning) || watchdog_expired) begin
                fault <= 1;
                applied_valid <= 0;
            end
        end
    end
    // endregion

endmodule
