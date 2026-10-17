`include "scene_frame_reader.v"
`timescale 1ns / 1ps
// 【说明】帧存读写外壳（ext_mem_clk），骨架来自例程：
//         写侧 frame_fifo_write + 写 FIFO（32 位×512），读侧 scene_frame_reader + 读 FIFO。
//         写 FIFO 跨 SD/内存域，读 FIFO 跨内存/视频域；读侧实例为 u_scene_reader。
// write_finish 来自写控制器末段收尾；读 FIFO 的 read_en/read_data 由视频时序侧消费。
module frame_read_write #(
    parameter MEM_DATA_BITS       = 32,
    parameter READ_DATA_BITS      = 32,
    parameter WRITE_DATA_BITS     = 32,
    parameter ADDR_BITS           = 21,
    parameter BURST_BITS          = 9,    //
    parameter BURST_SIZE          = 256,
    parameter WRITE_V_FLIP        = 1,    // 1: vertical flip when writing TF/BMP frame into SDRAM
    parameter FRAME_WIDTH         = 640,
    parameter FRAME_HEIGHT        = 480,
    parameter VERIFY_READ_RETURNS = 0
) (
    input  [10:0] image_stride,
    input  [20:0] image_first_offset,
    input         image_bottom_up,
    input  [17:0] slot_tails,
    input  [ 2:0] write_tail_index,
    input  [65:0] slot_widths, slot_strides,
    input  [59:0] slot_heights,
    input         slide_anim,
    input  [ 4:0] slide_phase,
    input  [ 2:0] slide_old,
    input  [12:0] scene_motion,
    input  [36:0] map_view,
    input         bilinear_enabled,
    input         scene_ready, photo_full, photo_blend,
    input         map_mode, map_zoom,
    input  [ 2:0] map_slot,
    input  [ 8:0] map_x,
    input  [ 7:0] map_y,
    input  [ 7:0] scene_tag,
    output        applied_pulse,
    output [ 7:0] applied_tag,
    output [ 5:0] applied_mask,
    output        applied_full,
    input  [ 2:0] scene_slide_slot, scene_bg_slot, scene_photo_slot,
    input  [ 7:0] scene_panel_height,
    output        reader_fault,
    input         rst,
    input         write_abort,
    input         mem_clk,             // external memory controller user interface clock
    input         Sdr_init_done,
    input         Sdr_init_ref_vld,
    input         Sdr_busy,


    output                       App_rd_en,
    output [    ADDR_BITS - 1:0] App_rd_addr,
    input                        Sdr_rd_en,    //read_data_valid
    input  [MEM_DATA_BITS - 1:0] Sdr_rd_dout,

    input read_clk,  // data read module clock
    input read_req,  // data read module read request,keep '1' until read_req_ack = '1'
    output [2:0] applied_buf_idx,
    output applied_buf_valid,
    output read_req_ack,  // data read module read request response
    output read_finish,  // data read module read request finish
    input [ADDR_BITS - 1:0] read_addr_0,  // data read module read request base address 0, used when read_addr_index = 0
    input [ADDR_BITS - 1:0] read_addr_1,  // data read module read request base address 1, used when read_addr_index = 1
    input [ADDR_BITS - 1:0] read_addr_2,  // data read module read request base address 1, used when read_addr_index = 2
    input [ADDR_BITS - 1:0] read_addr_3,  // data read module read request base address 1, used when read_addr_index = 3
    input [2:0] read_addr_index,  // select valid base address from read_addr_0 read_addr_1 read_addr_2 read_addr_3
    input [ADDR_BITS - 1:0] read_len,  // data read module read request data length
    input read_en,  // data read module read request for one data, read_data valid next clock
    output [READ_DATA_BITS  - 1:0] read_data,  // read data

    output                       App_wr_en,
    output [    ADDR_BITS - 1:0] App_wr_addr,
    output [MEM_DATA_BITS - 1:0] App_wr_din,
    output [                3:0] App_wr_dm,

    //
    input write_clk,  // data write module clock
    input write_req,  // data write module write request,keep '1' until read_req_ack = '1'
    output write_req_ack,  // data write module write request response
    output write_finish,  // data write module write request finish
    input [ADDR_BITS - 1:0] write_addr_0,  // data write module write request base address 0, used when write_addr_index = 0
    input [ADDR_BITS - 1:0] write_addr_1,  // data write module write request base address 1, used when write_addr_index = 1
    input [ADDR_BITS - 1:0] write_addr_2,  // data write module write request base address 1, used when write_addr_index = 2
    input [ADDR_BITS - 1:0] write_addr_3,  // data write module write request base address 1, used when write_addr_index = 3
    input [2:0] write_addr_index
        ,  // select valid base address from write_addr_0 write_addr_1 write_addr_2 write_addr_3
    input [ADDR_BITS - 1:0] write_addr_4, write_addr_5,
    input [ADDR_BITS - 1:0] write_len,  // data write module write request data length
    input write_en,  // data write module write request for one data
    input [WRITE_DATA_BITS - 1:0] write_data,  // write data
    output [8:0] write_fifo_used

);
    wire [BURST_BITS - 1:0] wrusedw;  // write used words
    wire [BURST_BITS - 1:0] rdusedw;  // read used words

    wire App_rd_busy;
    wire App_wr_busy;

    wire read_fifo_aclr;  // fifo Asynchronous clear
    wire write_fifo_aclr;  // fifo Asynchronous clear

    wire O_wr_busy;
    wire O_rd_busy;

    assign App_wr_busy = O_wr_busy;  //下个时钟写指令拉高
    assign App_rd_busy = O_rd_busy
        ;  //读指令还没有过去十个时钟;因为写指令优先，不需要在意下个时钟是否是读指令
    assign App_wr_dm = 4'b0000;

    //instantiate an asynchronous FIFO 
    wfifo_32_32_512 write_buf (
        .clkr      (mem_clk),                        // Read side clock
        .clkw      (write_clk),                      // Write side clock
        .rst       (write_fifo_aclr | write_abort),  // Asynchronous clear
        .we        (write_en),                       // Write Request
        .re        (App_wr_en),                      // Read Request
        .di        (write_data),                     // Input Data
        .empty_flag(),                               // Read side Empty flag
        .full_flag (),                               // Write side Full flag
        .wrusedw   (write_fifo_used),                // Write-clock-domain occupancy
        .rdusedw   (rdusedw),                        // Write Used Words
        .dout      (App_wr_din)
    );

    frame_fifo_write #(
        .SCATTERED_SLOTS (1),
        .DYNAMIC_GEOMETRY(1),
        .MEM_DATA_BITS   (MEM_DATA_BITS),
        .ADDR_BITS       (ADDR_BITS),
        .BURST_BITS      (BURST_BITS),
        .BURST_SIZE      (BURST_SIZE),
        .WRITE_V_FLIP    (WRITE_V_FLIP),
        .FRAME_WIDTH     (FRAME_WIDTH),
        .FRAME_HEIGHT    (FRAME_HEIGHT)
    ) frame_fifo_write_m0 (
        .write_tail_index  (write_tail_index),
        .image_stride      (image_stride),
        .image_first_offset(image_first_offset),
        .image_bottom_up   (image_bottom_up),
        .rst               (rst),
        .write_abort       (write_abort),
        .mem_clk           (mem_clk),
        .Sdr_init_done     (Sdr_init_done),
        .Sdr_init_ref_vld  (Sdr_init_ref_vld),
        .Sdr_busy          (Sdr_busy),
        .App_rd_busy       (App_rd_busy),
        .O_wr_busy         (O_wr_busy),

        .App_wr_en       (App_wr_en),
        .App_wr_addr     (App_wr_addr),
        .write_req       (write_req),
        .write_req_ack   (write_req_ack),
        .write_finish    (write_finish),
        .write_addr_0    (write_addr_0),
        .write_addr_1    (write_addr_1),
        .write_addr_2    (write_addr_2),
        .write_addr_3    (write_addr_3),
        .write_addr_4    (write_addr_4),
        .write_addr_5    (write_addr_5),
        .write_addr_index(write_addr_index),
        .write_len       (write_len),
        .fifo_aclr       (write_fifo_aclr),
        .rdusedw         (rdusedw)
    );

    wire scene_fifo_we;
    wire [31:0] scene_fifo_data;
    //instantiate an asynchronous FIFO 
    rfifo_32_32_512 read_buf (
        .clkr      (read_clk),         // Read side clock
        .clkw      (mem_clk),          // Write side clock
        .rst       (read_fifo_aclr),   // Asynchronous clear
        .we        (scene_fifo_we),    // Write Request
        .re        (read_en),          // Read Request
        .di        (scene_fifo_data),  // Input Data
        .empty_flag(),                 // Read side Empty flag
        .full_flag (),                 // Write side Full flag
        .wrusedw   (wrusedw),          // Read Used Words
        .rdusedw   (),                 // Write Used Words
        .dout      (read_data)
    );

    scene_frame_reader #(
        .DYNAMIC_GEOMETRY (1),
        .SCATTERED_SLOTS  (1),
        .BILINEAR_SUPPORT (1),
        .CROSSFADE_SUPPORT(1)
    ) u_scene_reader (
        .bilinear_enabled(bilinear_enabled),
        .slot_tails(slot_tails),
        .slot_widths(slot_widths),
        .slot_strides(slot_strides),
        .slot_heights(slot_heights),
        .slide_anim(slide_anim),
        .slide_phase(slide_phase),
        .slide_old(slide_old),
        .scene_tag(scene_tag),
        .applied_pulse(applied_pulse),
        .applied_tag(applied_tag),
        .applied_mask(applied_mask),
        .applied_full(applied_full),
        .scene_motion(scene_motion),
        .map_view(map_view),
        .map_mode(map_mode),
        .map_zoom(map_zoom),
        .map_slot(map_slot),
        .map_x(map_x),
        .map_y(map_y),
        .clk(mem_clk),
        .rst(rst),
        .init_done(Sdr_init_done),
        .refresh_busy(Sdr_init_ref_vld),
        .writer_busy(App_wr_busy),
        .core_busy(Sdr_busy),
        .read_req(read_req),
        .fifo_used(wrusedw),
        .rd_valid(Sdr_rd_en),
        .rd_data(Sdr_rd_dout),
        .scene_ready(scene_ready),
        .slide_slot(scene_slide_slot),
        .bg_slot(scene_bg_slot),
        .photo_slot(scene_photo_slot),
        .panel_height(scene_panel_height),
        .photo_full(photo_full),
        .photo_blend(photo_blend),
        .req_ack(read_req_ack),
        .fifo_clear(read_fifo_aclr),
        .rd_en(App_rd_en),
        .rd_addr(App_rd_addr),
        .fifo_we(scene_fifo_we),
        .fifo_data(scene_fifo_data),
        .busy(O_rd_busy),
        .applied_slot(applied_buf_idx),
        .applied_valid(applied_buf_valid),
        .fault(reader_fault)
    );
    assign read_finish = 1'b0;
endmodule
