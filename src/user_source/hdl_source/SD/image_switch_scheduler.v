// 【未使用】旧版按键排队切图调度器，已由 site_scene_broker.v 取代。
// 仍保留在工程文件列表中，综合时不会进入设计层次；阅读当前设计可跳过本文件。
`timescale 1ns/1ps

// Reusable image playback scheduler.
//
// Design rules:
//   1. Key presses are queued instead of being collapsed into one pending bit.
//   2. Only one image load transaction may be active at a time.
//   3. The display buffer changes only after both the source stream and the
//      complete SDRAM frame write have finished.
//   4. A source completion is accepted only after the loader was observed busy;
//      a frame completion is accepted only after this transaction was acked.
//   5. Automatic playback uses the same transaction path as manual playback.
module image_switch_scheduler #(
    parameter integer CLK_FREQ_HZ       = 100_000_000,
    parameter integer AUTO_INTERVAL_MS  = 1000,
    parameter integer LOAD_TIMEOUT_MS   = 5000,
    parameter integer LOAD_RETRY_LIMIT  = 1,
    parameter integer PENDING_WIDTH     = 4,
    parameter integer ENABLE_VIEW_CONTROL = 0,
    parameter integer ENABLE_READ_HANDOFF = 0
)(
    input  wire                         clk,
    input  wire                         rst,

    input  wire                         catalog_ready,
    input  wire [2:0]                   image_count,
    input  wire                         loader_ready,

    input  wire                         view_pause,
    input  wire [1:0]                   period_select,
    input  wire                         read_buffer_valid,
    input  wire [1:0]                   read_buffer_idx,
    output wire                         view_settled,

    input  wire                         key_next_pulse,
    input  wire                         key_auto_pulse,

    input  wire                         write_req_ack,
    input  wire                         frame_done_pulse,
    input  wire                         abort_done_pulse,

    output reg                          load_start,
    output reg                          load_abort,
    output reg                          load_commit,
    output reg                          load_busy,
    output reg  [1:0]                   load_image_idx,
    output reg  [1:0]                   display_image_idx,
    output reg  [1:0]                   write_buf_idx,
    output reg  [1:0]                   disp_buf_idx,
    output reg                          display_valid,
    output reg                          auto_play_en,
    output reg  [PENDING_WIDTH-1:0]     pending_count,
    output wire                         waiting_for_frame
);

localparam integer AUTO_INTERVAL_CYCLES = (CLK_FREQ_HZ / 1000) * AUTO_INTERVAL_MS;
localparam integer LOAD_TIMEOUT_CYCLES  = (CLK_FREQ_HZ / 1000) * LOAD_TIMEOUT_MS;
localparam [PENDING_WIDTH-1:0] PENDING_MAX = {PENDING_WIDTH{1'b1}};

reg [31:0] auto_cnt;
reg [31:0] load_timeout_cnt;
reg        auto_due;
reg        active_manual;
reg        source_started_seen;
reg        source_done_seen;
reg        write_ack_seen;
reg        write_done_seen;
reg        retry_pending;
reg        retry_manual;
reg        abort_wait;
reg [7:0]  retry_count;
reg [1:0]  sequence_image_idx;
reg [1:0]  startup_image_idx;

wire [1:0] next_image_idx;
wire [1:0] next_write_buf_idx;
wire       source_done_now;
wire       write_done_now;
wire       load_commit_now;
wire       load_timeout_now;
wire       manual_pop;
wire       manual_push;
wire       auto_tick;
wire paused = ENABLE_VIEW_CONTROL ? view_pause : 1'b0;
wire read_applied = !ENABLE_READ_HANDOFF ||
                    (read_buffer_valid && (read_buffer_idx == disp_buf_idx));
reg [31:0] selected_interval_cycles;
reg [1:0] last_period_select;
always @* begin
    case(period_select)
        2'd0: selected_interval_cycles = (CLK_FREQ_HZ / 1000) * 5000;
        2'd1: selected_interval_cycles = (CLK_FREQ_HZ / 1000) * 2000;
        2'd2: selected_interval_cycles = (CLK_FREQ_HZ / 1000) * 10000;
        default: selected_interval_cycles = (CLK_FREQ_HZ / 1000) * 30000;
    endcase
end
wire [31:0] interval_cycles = ENABLE_VIEW_CONTROL ? selected_interval_cycles : AUTO_INTERVAL_CYCLES;
assign view_settled = paused && display_valid && !load_busy && !abort_wait && !retry_pending && read_applied;

function [1:0] next_index_limited;
    input [1:0] cur;
    input [2:0] count;
    begin
        case (count)
            3'd0: next_index_limited = 2'd0;
            3'd1: next_index_limited = 2'd0;
            3'd2: next_index_limited = (cur == 2'd1) ? 2'd0 : (cur + 2'd1);
            3'd3: next_index_limited = (cur == 2'd2) ? 2'd0 : (cur + 2'd1);
            default: next_index_limited = (cur == 2'd3) ? 2'd0 : (cur + 2'd1);
        endcase
    end
endfunction

// Keep playback sequence position separate from the actually displayed image.
// A permanently bad image can then be skipped without exposing its half frame.
assign next_image_idx     = next_index_limited(sequence_image_idx, image_count);
assign next_write_buf_idx = (!display_valid || (disp_buf_idx != 2'd0)) ? 2'd0 : 2'd1;

// loader_ready is high before load_start is consumed.  Requiring a witnessed
// busy phase prevents that old high level from being mistaken for completion.
assign source_done_now = source_done_seen ||
                         (source_started_seen && loader_ready);

// Ignore a stale frame completion until the write side has acknowledged the
// request belonging to this transaction.
assign write_done_now = write_done_seen ||
                        ((write_ack_seen || write_req_ack) && frame_done_pulse);

assign load_commit_now = load_busy && source_done_now && write_done_now;
assign load_timeout_now = load_busy && ((LOAD_TIMEOUT_CYCLES <= 1) ||
                          (load_timeout_cnt >= LOAD_TIMEOUT_CYCLES - 1));
assign manual_pop       = ((load_commit_now && active_manual) ||
                          (load_timeout_now && active_manual &&
                           (retry_count >= LOAD_RETRY_LIMIT))) &&
                          (pending_count != {PENDING_WIDTH{1'b0}});
assign manual_push      = key_next_pulse && !paused && catalog_ready &&
                          (image_count != 3'd0) &&
                          ((pending_count != PENDING_MAX) || manual_pop);
assign auto_tick        = (interval_cycles <= 1) ? 1'b1 :
                          (auto_cnt >= interval_cycles - 1);
assign waiting_for_frame = load_busy && source_done_now && !write_done_now;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        load_start          <= 1'b0;
        load_abort          <= 1'b0;
        load_commit         <= 1'b0;
        load_busy           <= 1'b0;
        load_image_idx      <= 2'd0;
        display_image_idx   <= 2'd0;
        write_buf_idx       <= 2'd0;
        disp_buf_idx        <= 2'd0;
        display_valid       <= 1'b0;
        auto_play_en        <= 1'b0;
        pending_count       <= {PENDING_WIDTH{1'b0}};
        auto_cnt            <= 32'd0;
        load_timeout_cnt    <= 32'd0;
        auto_due            <= 1'b0;
        active_manual       <= 1'b0;
        source_started_seen <= 1'b0;
        source_done_seen    <= 1'b0;
        write_ack_seen      <= 1'b0;
        write_done_seen     <= 1'b0;
        retry_pending       <= 1'b0;
        retry_manual        <= 1'b0;
        abort_wait          <= 1'b0;
        retry_count         <= 8'd0;
        sequence_image_idx  <= 2'd0;
        startup_image_idx   <= 2'd0;
        last_period_select <= 2'd0;
    end else begin
        last_period_select <= period_select;
        load_start  <= 1'b0;
        load_abort  <= 1'b0;
        load_commit <= 1'b0;

        // Queue accounting handles a simultaneous press and successful commit
        // without losing either event.
        case ({manual_push, manual_pop})
            2'b10: pending_count <= pending_count + {{(PENDING_WIDTH-1){1'b0}}, 1'b1};
            2'b01: pending_count <= pending_count - {{(PENDING_WIDTH-1){1'b0}}, 1'b1};
            default: pending_count <= pending_count;
        endcase

        // Automatic playback is edge-controlled and its deadline is sticky.
        if (key_auto_pulse && catalog_ready && (image_count > 3'd1)) begin
            auto_play_en <= ~auto_play_en;
            auto_cnt     <= 32'd0;
            auto_due     <= 1'b0;
        end else if (!catalog_ready || !display_valid ||
                     (image_count < 3'd2) || !auto_play_en) begin
            auto_cnt <= 32'd0;
            auto_due <= 1'b0;
        end else if (manual_push) begin
            // A user request restarts the automatic dwell interval.
            auto_cnt <= 32'd0;
            auto_due <= 1'b0;
        end else if (load_busy || abort_wait || paused || !read_applied ||
                     (ENABLE_VIEW_CONTROL && period_select != last_period_select)) begin
            auto_cnt <= 32'd0;
            auto_due <= 1'b0;
        end else if (!auto_due) begin
            if (auto_tick) begin
                auto_cnt <= 32'd0;
                auto_due <= 1'b1;
            end else begin
                auto_cnt <= auto_cnt + 32'd1;
            end
        end

        if (abort_wait) begin
            // The memory-domain writer and asynchronous FIFO must finish
            // abort cleanup before any retry or later request can start.
            if (abort_done_pulse)
                abort_wait <= 1'b0;
        end else if (load_busy) begin
            if (!loader_ready)
                source_started_seen <= 1'b1;

            if (source_started_seen && loader_ready)
                source_done_seen <= 1'b1;

            if (write_req_ack)
                write_ack_seen <= 1'b1;

            if ((write_ack_seen || write_req_ack) && frame_done_pulse)
                write_done_seen <= 1'b1;

            if (load_commit_now) begin
                load_commit         <= 1'b1;
                load_busy           <= 1'b0;
                load_timeout_cnt    <= 32'd0;
                disp_buf_idx        <= write_buf_idx;
                display_image_idx   <= load_image_idx;
                sequence_image_idx  <= load_image_idx;
                display_valid       <= 1'b1;
                active_manual       <= 1'b0;
                source_started_seen <= 1'b0;
                source_done_seen    <= 1'b0;
                write_ack_seen      <= 1'b0;
                write_done_seen     <= 1'b0;
                retry_pending       <= 1'b0;
                retry_manual        <= 1'b0;
                retry_count         <= 8'd0;
            end else if (load_timeout_now) begin
                // Retry a transient failure a bounded number of times.  A
                // permanently bad target is then discarded so later K2/K4
                // events can still make progress.
                load_abort          <= 1'b1;
                abort_wait          <= 1'b1;
                load_busy           <= 1'b0;
                load_timeout_cnt    <= 32'd0;
                active_manual       <= 1'b0;
                source_started_seen <= 1'b0;
                source_done_seen    <= 1'b0;
                write_ack_seen      <= 1'b0;
                write_done_seen     <= 1'b0;
                if (retry_count < LOAD_RETRY_LIMIT) begin
                    retry_pending <= 1'b1;
                    retry_manual  <= active_manual;
                    retry_count   <= retry_count + 8'd1;
                end else begin
                    retry_pending <= 1'b0;
                    retry_manual  <= 1'b0;
                    retry_count   <= 8'd0;
                    // Advance the sequence past a permanently bad target but
                    // leave the old display buffer and its image index intact.
                    sequence_image_idx <= load_image_idx;
                    if (!display_valid)
                        startup_image_idx <= next_index_limited(load_image_idx,
                                                                image_count);
                end
            end else begin
                load_timeout_cnt <= load_timeout_cnt + 32'd1;
            end
        end else begin
            load_timeout_cnt <= 32'd0;

            if (catalog_ready && loader_ready && (image_count != 3'd0) &&
                (!display_valid || read_applied)) begin
                if (retry_pending) begin
                    // Keep the same image and write buffer selected by the
                    // failed attempt; only restart the transaction handshake.
                    load_start          <= 1'b1;
                    load_busy           <= 1'b1;
                    active_manual       <= retry_manual;
                    source_started_seen <= 1'b0;
                    source_done_seen    <= 1'b0;
                    write_ack_seen      <= 1'b0;
                    write_done_seen     <= 1'b0;
                    retry_pending       <= 1'b0;
                end else if (!display_valid) begin
                    load_image_idx      <= startup_image_idx;
                    write_buf_idx       <= 2'd0;
                    load_start          <= 1'b1;
                    load_busy           <= 1'b1;
                    active_manual       <= 1'b0;
                    source_started_seen <= 1'b0;
                    source_done_seen    <= 1'b0;
                    write_ack_seen      <= 1'b0;
                    write_done_seen     <= 1'b0;
                    retry_count         <= 8'd0;
                end else if (!paused && pending_count != {PENDING_WIDTH{1'b0}}) begin
                    load_image_idx      <= next_image_idx;
                    write_buf_idx       <= next_write_buf_idx;
                    load_start          <= 1'b1;
                    load_busy           <= 1'b1;
                    active_manual       <= 1'b1;
                    source_started_seen <= 1'b0;
                    source_done_seen    <= 1'b0;
                    write_ack_seen      <= 1'b0;
                    write_done_seen     <= 1'b0;
                    auto_cnt            <= 32'd0;
                    auto_due            <= 1'b0;
                    retry_count         <= 8'd0;
                end else if (!paused && auto_play_en && auto_due) begin
                    load_image_idx      <= next_image_idx;
                    write_buf_idx       <= next_write_buf_idx;
                    load_start          <= 1'b1;
                    load_busy           <= 1'b1;
                    active_manual       <= 1'b0;
                    source_started_seen <= 1'b0;
                    source_done_seen    <= 1'b0;
                    write_ack_seen      <= 1'b0;
                    write_done_seen     <= 1'b0;
                    auto_cnt            <= 32'd0;
                    auto_due            <= 1'b0;
                    retry_count         <= 8'd0;
                end
            end
        end
    end
end

endmodule
