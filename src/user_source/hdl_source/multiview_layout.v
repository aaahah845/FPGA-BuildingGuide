// 【未使用】早期多视图布局，当前未例化。
// 仍保留在工程文件列表中，综合时不会进入设计层次；阅读当前设计可跳过本文件。
`timescale 1ns/1ps
// Commit one scene descriptor at frame request; it remains stable until the
// next frame. The memory reader latches it only when the request is withdrawn.
module multiview_layout(input clk,rst,frame_request,assets_ready,
 input[3:0] resident_mask,input[1:0] slide_idx,floor_idx,input[2:0] room_idx,
 input detail_requested,full_requested,
 input map_requested,zoom_requested,pan_requested,input[8:0] origin_x,input[7:0] origin_y,
 output reg map_mode,map_zoom,map_pan,output reg[1:0] map_slot,
 output reg[8:0] map_x,output reg[7:0] map_y,
 output reg ready,full,output reg[7:0] half_height,
 output reg[1:0] slide,bg,photo,floor,output reg[2:0] room);
 `include "guide_site_config.vh"
 reg request_d;
 reg[1:0] wanted_photo;
 function[1:0] valid_slot;input[1:0] wanted;input[3:0] mask;begin
 if(mask[wanted])valid_slot=wanted;else if(mask[0])valid_slot=0;
 else if(mask[1])valid_slot=1;else if(mask[2])valid_slot=2;else valid_slot=3;end endfunction
 always @* wanted_photo=site_photo(floor_idx*5'd6+room_idx);
 always @(posedge clk or posedge rst)begin
 if(rst)begin map_mode<=0;map_zoom<=0;map_pan<=0;map_slot<=0;map_x<=0;map_y<=0;request_d<=0;ready<=0;full<=0;half_height<=0;slide<=0;bg<=0;photo<=0;floor<=0;room<=0;end
 else begin request_d<=frame_request;
 if(frame_request && !request_d)begin
 floor<=floor_idx;room<=room_idx;
 map_mode<=map_requested;map_zoom<=zoom_requested;map_pan<=pan_requested;
 map_slot<=valid_slot(site_map_slot(floor_idx),resident_mask);map_x<=origin_x;map_y<=origin_y;
 ready<=assets_ready;slide<=valid_slot(slide_idx,resident_mask);
 bg<=valid_slot(SITE_BACKGROUND,resident_mask);photo<=valid_slot(wanted_photo,resident_mask);
 full<=detail_requested && full_requested;
 if(detail_requested)begin if(half_height<150)half_height<=half_height+15;end
 else if(half_height!=0)half_height<=half_height-15;
 end end end
endmodule
