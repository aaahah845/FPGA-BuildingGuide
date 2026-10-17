// 【未使用】旧版 4 帧常驻调度器，已由 sd_site_assets.v 的 6 槽缓存取代。
// 仍保留在工程文件列表中，综合时不会进入设计层次；阅读当前设计可跳过本文件。
`timescale 1ns/1ps
// Four immutable resident frames. No slot is overwritten after startup.
module resident_image_scheduler #(
 parameter integer CLK_FREQ_HZ=100000000, LOAD_TIMEOUT_MS=5000, LOAD_RETRY_LIMIT=1
)(input clk,rst,catalog_ready,loader_ready,input[2:0] image_count,
 input view_pause,input[1:0] period_select,input key_next_pulse,key_auto_pulse,
 input write_req_ack,frame_done_pulse,abort_done_pulse,
 output reg load_start,load_abort,load_commit,load_busy,
 output reg[1:0] load_image_idx,write_buf_idx,disp_buf_idx,
 output wire[1:0] display_image_idx,output reg display_valid,auto_play_en,
 output reg[3:0] resident_mask,output waiting_for_frame,view_settled);
 localparam WAIT=0,LAUNCH=1,LOAD=2,ABORT=3,ADVANCE=4,PLAY=5;
 reg[2:0] state;reg[2:0] cursor;reg[7:0] retries;
 reg source_started,source_done,ack_seen,done_seen;
 reg[31:0] timeout_count,auto_count;reg[1:0] period_d;
 reg[31:0] interval;
 wire source_finished=source_done || (source_started && loader_ready);
 wire write_finished=done_seen || ((ack_seen || write_req_ack) && frame_done_pulse);
 function[1:0] next_valid;input[1:0] current;input[3:0] mask;
 reg[1:0] a,b,c;begin a=current+1'b1;b=current+2'd2;c=current+2'd3;
 if(mask[a])next_valid=a;else if(mask[b])next_valid=b;else if(mask[c])next_valid=c;else next_valid=current;end endfunction
 function[1:0] first_valid;input[3:0] mask;begin
 if(mask[0])first_valid=0;else if(mask[1])first_valid=1;else if(mask[2])first_valid=2;else first_valid=3;end endfunction
 always @* case(period_select)
 0:interval=(CLK_FREQ_HZ/1000)*5000;
 1:interval=(CLK_FREQ_HZ/1000)*2000;
 2:interval=(CLK_FREQ_HZ/1000)*10000;
 default:interval=(CLK_FREQ_HZ/1000)*30000;endcase
 assign display_image_idx=disp_buf_idx;
 assign waiting_for_frame=load_busy && source_finished && !write_finished;
 assign view_settled=display_valid && view_pause;
 always @(posedge clk or posedge rst)begin
 if(rst)begin state<=WAIT;cursor<=0;retries<=0;resident_mask<=0;
 load_start<=0;load_abort<=0;load_commit<=0;load_busy<=0;
 load_image_idx<=0;write_buf_idx<=0;disp_buf_idx<=0;display_valid<=0;auto_play_en<=0;
 source_started<=0;source_done<=0;ack_seen<=0;done_seen<=0;timeout_count<=0;auto_count<=0;period_d<=0;
 end else begin
 load_start<=0;load_abort<=0;load_commit<=0;period_d<=period_select;
 case(state)
 WAIT:if(catalog_ready && image_count!=0)begin cursor<=0;state<=LAUNCH;end
 LAUNCH:if(loader_ready)begin
 load_image_idx<=cursor[1:0];write_buf_idx<=cursor[1:0];load_start<=1;load_busy<=1;
 source_started<=0;source_done<=0;ack_seen<=0;done_seen<=0;timeout_count<=0;state<=LOAD;end
 LOAD:begin
 if(!loader_ready)source_started<=1;
 if(source_started && loader_ready)source_done<=1;
 if(write_req_ack)ack_seen<=1;
 if((ack_seen || write_req_ack) && frame_done_pulse)done_seen<=1;
 if(source_finished && write_finished)begin
 resident_mask[cursor[1:0]]<=1;load_commit<=1;load_busy<=0;retries<=0;state<=ADVANCE;
 end else if(timeout_count>=(CLK_FREQ_HZ/1000)*LOAD_TIMEOUT_MS-1)begin
 load_abort<=1;load_busy<=0;state<=ABORT;
 end else timeout_count<=timeout_count+1'b1;
 end
 ABORT:if(abort_done_pulse)begin
 if(retries<LOAD_RETRY_LIMIT)begin retries<=retries+1'b1;state<=LAUNCH;end
 else begin retries<=0;state<=ADVANCE;end
 end
 ADVANCE:if(cursor+1>=image_count || cursor==3)begin
 display_valid<=|resident_mask;disp_buf_idx<=first_valid(resident_mask);state<=PLAY;
 end else begin cursor<=cursor+1'b1;state<=LAUNCH;end
 PLAY:begin
 if(key_auto_pulse && display_valid)auto_play_en<=!auto_play_en;
 if(!display_valid || view_pause || !auto_play_en || key_auto_pulse || period_d!=period_select)auto_count<=0;
 else if(auto_count>=interval-1)auto_count<=0;else auto_count<=auto_count+1'b1;
 if(display_valid && !view_pause && (key_next_pulse || (auto_play_en && auto_count>=interval-1)))begin
 disp_buf_idx<=next_valid(disp_buf_idx,resident_mask);auto_count<=0;end
 end
 default:state<=WAIT;
 endcase
 end end
endmodule
