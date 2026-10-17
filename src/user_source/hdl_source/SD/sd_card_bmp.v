// 【未使用】旧版资源加载顶层，已由 SD/sd_site_assets.v 取代。
// 仍保留在工程文件列表中，综合时不会进入设计层次；阅读当前设计可跳过本文件。
// Tang Dynasty may rewrite its generated .al/.prj source lists when the GUI
// saves a project.  Include the reusable scheduler from this already-managed
// source file so the scheduler cannot silently disappear from synthesis.
`include "image_switch_scheduler.v"
`include "resident_image_scheduler.v"
`include "fat32_file_reader.v"

module sd_card_bmp #(
    parameter integer CLK_FREQ_HZ       = 100_000_000,
    parameter [31:0]  SCAN_START_SECTOR = 32'd0,
    parameter [31:0]  SCAN_MAX_SECTOR   = 32'd131071,
    parameter [2:0]   SCAN_TARGET_COUNT = 3'd4,
    parameter integer LOAD_TIMEOUT_MS   = 5000,
    parameter integer LOAD_RETRY_LIMIT  = 1,
    parameter integer AUTO_INTERVAL_MS  = 1000,
    parameter integer PENDING_WIDTH     = 4,
    parameter integer ENABLE_VIEW_CONTROL = 0,
    parameter integer ENABLE_READ_HANDOFF = 0
)(
    input                       clk,
    input                       rst,
    input                       view_pause,
    input [1:0]                 period_select,
    input                       read_buffer_valid,
    input [1:0]                 read_buffer_idx,
    output                      view_settled,
    input                       key_next_pulse,
    input                       key_auto_pulse,
    input  [15:0]               bmp_width,
    input  [15:0]               bmp_height,
    output [3:0]                resident_mask,
    output                      display_valid,
    output                      auto_play_active,
    output      [1:0]           displayed_image_idx,
    output      [3:0]           state_code,
    output                      write_abort,
    input                       write_abort_done,

    input                       frame_done_pulse,
    input  [8:0]                write_fifo_used,
    output     [1:0]            write_buf_idx,
    output     [1:0]            disp_buf_idx,

    output                      write_req,
    input                       write_req_ack,
    output                      write_en,
    output [31:0]               write_data,
    output                      SD_nCS,
    output                      SD_DCLK,
    output                      SD_MOSI,
    input                       SD_MISO
);

wire             sd_sec_read;
wire [31:0]      sd_sec_read_addr;
wire [7:0]       sd_sec_read_data;
wire             sd_sec_read_data_valid;
wire             sd_sec_read_end;
wire [3:0]       state_code_i;
wire             bmp_data_wr_en;
wire [23:0]      bmp_data;
wire             sd_init_done;
wire             bmp_ready;
wire catalog_ready,fs_idle;
wire [2:0] img_found_count;
wire [3:0] fs_error;
wire bmp_sec_read,bmp_sec_valid,bmp_sec_end;
wire [31:0] bmp_sec_addr;
wire [7:0] bmp_sec_data;
wire load_start_pulse;
wire loader_ready=bmp_ready && fs_idle;

wire             load_abort;
wire             load_commit;
wire             load_busy;
wire [1:0]       load_idx;
wire [1:0]       display_image_idx;
wire             auto_play_en;
wire scheduler_display_valid;
wire [PENDING_WIDTH-1:0] pending_count;
wire             waiting_for_frame;

wire write_stream_ready;
wire control_rst;

assign write_en   = bmp_data_wr_en;
assign write_data = {bmp_data[23:16], bmp_data[15:8], bmp_data[7:0], 8'b0};
assign state_code = fs_error!=0 ? fs_error :
    ((scheduler_display_valid && !resident_mask[0]) ? 4'hd : (waiting_for_frame ? 4'd5 : state_code_i));
// Do not silently replace a failed BACK.BMP with a room photograph.
assign display_valid=scheduler_display_valid && resident_mask[0];
assign write_abort = load_abort;
assign auto_play_active = auto_play_en;
assign displayed_image_idx = display_image_idx;

assign control_rst = rst | ~sd_init_done;
// 一个 SD 扇区最多产生 171 个 RGB 像素；低于半满才启动下一扇区。
assign write_stream_ready = (write_fifo_used <= 9'd256);

fat32_file_reader u_fat32(
 .clk(clk),.rst(control_rst),.sd_ready(sd_init_done),
 .catalog_ready(catalog_ready),.image_count(img_found_count),.error_code(fs_error),.idle(fs_idle),
 .file_open(load_start_pulse),.file_index(load_idx),.file_abort(load_abort),
 .file_req(bmp_sec_read),.file_sector(bmp_sec_addr),.file_data(bmp_sec_data),.file_valid(bmp_sec_valid),.file_end(bmp_sec_end),
 .sd_req(sd_sec_read),.sd_addr(sd_sec_read_addr),.sd_data(sd_sec_read_data),.sd_valid(sd_sec_read_data_valid),.sd_end(sd_sec_read_end));

resident_image_scheduler #(.CLK_FREQ_HZ(CLK_FREQ_HZ),
 .LOAD_TIMEOUT_MS(LOAD_TIMEOUT_MS),.LOAD_RETRY_LIMIT(LOAD_RETRY_LIMIT)) u_resident (
 .clk(clk),.rst(control_rst),.catalog_ready(catalog_ready),.image_count(img_found_count),
 .loader_ready(loader_ready),.view_pause(view_pause),.period_select(period_select),
 .key_next_pulse(key_next_pulse),.key_auto_pulse(key_auto_pulse),
 .write_req_ack(write_req_ack),.frame_done_pulse(frame_done_pulse),.abort_done_pulse(write_abort_done),
 .load_start(load_start_pulse),.load_abort(load_abort),.load_commit(load_commit),.load_busy(load_busy),
 .load_image_idx(load_idx),.display_image_idx(display_image_idx),
 .write_buf_idx(write_buf_idx),.disp_buf_idx(disp_buf_idx),.display_valid(scheduler_display_valid),
 .auto_play_en(auto_play_en),.resident_mask(resident_mask),.waiting_for_frame(waiting_for_frame),
 .view_settled(view_settled));

bmp_read bmp_read_m0(
    .clk                    (clk),
    .rst                    (rst),
    .ready                  (bmp_ready),

    .scan_start             (1'b0),
    .scan_start_sector      (32'd0),
    .scan_max_sector        (32'd0),
    .scan_target_count      (3'd0),
    .scan_done              (),
    .scan_found_valid       (),
    .scan_found_sector      (),
    .scan_found_total       (),

    .load_start             (load_start_pulse),
    .load_abort             (load_abort),
    .load_sector            (32'd0),
    .write_stream_ready     (write_stream_ready),

    .sd_init_done           (sd_init_done),
    .state_code             (state_code_i),
    .bmp_width              (bmp_width),
    .bmp_height             (bmp_height),
    .write_req              (write_req),
    .write_req_ack          (write_req_ack),
    .sd_sec_read            (bmp_sec_read),
    .sd_sec_read_addr       (bmp_sec_addr),
    .sd_sec_read_data       (bmp_sec_data),
    .sd_sec_read_data_valid (bmp_sec_valid),
    .sd_sec_read_end        (bmp_sec_end),
    .bmp_data_wr_en         (bmp_data_wr_en),
    .bmp_data               (bmp_data)
);

sd_card_top sd_card_top_m0(
    .clk                    (clk),
    .rst                    (rst),
    .SD_nCS                 (SD_nCS),
    .SD_DCLK                (SD_DCLK),
    .SD_MOSI                (SD_MOSI),
    .SD_MISO                (SD_MISO),
    .sd_init_done           (sd_init_done),
    .sd_sec_read            (sd_sec_read),
    .sd_sec_read_addr       (sd_sec_read_addr),
    .sd_sec_read_data       (sd_sec_read_data),
    .sd_sec_read_data_valid (sd_sec_read_data_valid),
    .sd_sec_read_end        (sd_sec_read_end),
    .sd_sec_write           (1'b0),
    .sd_sec_write_addr      (32'd0),
    .sd_sec_write_data      (),
    .sd_sec_write_data_req  (),
    .sd_sec_write_end       ()
);

endmodule
