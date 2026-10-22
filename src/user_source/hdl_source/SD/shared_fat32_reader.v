`ifndef SHARED_FAT32_READER_V
`define SHARED_FAT32_READER_V
`include "fat32_named_file.v"
// Two logical file cursors, one filesystem and one physical SD controller.
// Ownership only changes after an entire sector/lookup has drained to IDLE.
// 【说明】SD 共享仲裁：图片与两路音频共用一个 fat32_named_file，
//         只在文件系统空闲时切换所有者，切换粒度为整扇区或整次目录查找。
module shared_fat32_reader #(
    parameter TRIPLE_AUDIO=0
)(
    input a_context,
    input clk,rst,sd_ready,
    input audio_enable,
    output mounted,
    input i_open,i_abort,
    input [87:0] i_name,
    input i_req,
    input [31:0] i_sector,
    output i_idle,i_open_done,i_open_ok,
    output reg [31:0] i_size,
    output reg [3:0] i_error,
    output [7:0] i_data,
    output i_valid,i_end,
    input a_want,a_open,a_abort,
    input [87:0] a_name,
    input a_req,
    input [31:0] a_sector,
    output a_idle,a_open_done,a_open_ok,
    output [31:0] a_size,
    output [3:0] a_error,
    output [7:0] a_data,
    output a_valid,a_end,
    output sd_req,
    output [31:0] sd_addr,
    input [7:0] sd_data,
    input sd_valid,sd_end
);
reg owner,i_open_pending,i_abort_pending,a_abort_pending;
wire [1:0] active;
wire idle,opened,ok,valid,ended;
wire [31:0] size;
wire [3:0] err;
wire [7:0] data;
wire image_open=i_open|i_open_pending;
wire image_abort=i_abort|i_abort_pending;
wire [1:0] desired=owner?(TRIPLE_AUDIO?(a_context?2'd2:2'd1):2'd1):2'd0;
wire selected=(desired==active);
wire req=selected && (owner?a_req:i_req);
wire open_req=selected && (owner?a_open:image_open);
wire abort_req=selected && (owner?(a_abort|a_abort_pending):image_abort);
always @(posedge clk or posedge rst) begin
    if(rst) begin
        owner<=0;
        i_open_pending<=0;
        i_abort_pending<=0;
        a_abort_pending<=0;
        i_size<=0;
        i_error<=0;
    end else begin
        if(!active) begin
            i_size<=size;
            i_error<=err;
        end
        // Keep a one-cycle image command if audio won the idle boundary.
        if(i_open) i_open_pending<=1;
        if(i_abort) i_abort_pending<=1;
        if(a_abort) a_abort_pending<=1;
        if(!owner && !active && idle && image_open) i_open_pending<=0;
        if(!owner && !active && image_abort) i_abort_pending<=0;
        if(owner && selected && (a_abort|a_abort_pending)) a_abort_pending<=0;
        if(idle && !open_req && !req && !abort_req) begin
            if(!owner && audio_enable && (a_want|a_abort_pending)) owner<=1;
            else if(owner && !a_want && !a_abort_pending) owner<=0;
        end
    end
end
assign i_idle=idle && !owner && !active;
assign a_idle=idle && owner && selected;
assign i_open_done=opened && !active;
assign a_open_done=opened && active;
assign i_open_ok=ok;
assign a_open_ok=ok;
assign a_size=size;
assign a_error=active?err:0;
assign i_data=data;
assign a_data=data;
assign i_valid=valid && !active;
assign a_valid=valid && active;
assign i_end=ended && !active;
assign a_end=ended && active;
fat32_named_file #(
    .DUAL_CONTEXT(TRIPLE_AUDIO?2:1),
    .CONTEXT_BITS(2)
) fs(
    .clk(clk),
    .rst(rst),
    .sd_ready(sd_ready),
    .context_select(desired),
    .context_active(active),
    .mounted(mounted),
    .idle(idle),
    .file_open(open_req),
    .file_name(owner?a_name:i_name),
    .file_abort(abort_req),
    .file_req(req),
    .file_sector(owner?a_sector:i_sector),
    .open_done(opened),
    .open_ok(ok),
    .file_size(size),
    .error_code(err),
    .file_data(data),
    .file_valid(valid),
    .file_end(ended),
    .sd_req(sd_req),
    .sd_addr(sd_addr),
    .sd_data(sd_data),
    .sd_valid(sd_valid),
    .sd_end(sd_end)
);
endmodule
`endif
