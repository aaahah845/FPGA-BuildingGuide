`ifndef AV_SCENE_EVENTS_V
`define AV_SCENE_EVENTS_V
// Match compositor occupancy latching, then commit at an accepted HDMI SOF.
// 【说明】场景提交事件：在 HDMI 帧起点比较轮播、面板、占用变化。顶层只接入轮播输入。
module av_scene_events(
    input clk,rst,
    input compositor_vs,
    input axis_valid,axis_user,axis_ready,scene_ready,photo_full,
    input [7:0] panel_height,
    input [6:0] slide_slot,
    input [1:0] floor_idx,
    input [29:0] occupied,
    output reg [1:0] event_code
);
reg vs_d,armed,old_panel;
reg [29:0] occupied_frame,old_occupied;
reg [6:0] old_slide;
reg [1:0] old_floor,floor_frame;
wire panel_visible=(panel_height!=0);
wire [29:0] visible_mask=30'b1111111111 << (floor_frame*10);
always @(posedge clk or posedge rst) begin
    if(rst) begin
        vs_d<=0;
        armed<=0;
        old_panel<=0;
        occupied_frame<=0;
        old_occupied<=0;
        old_slide<=0;
        old_floor<=0;
        floor_frame<=0;
        event_code<=0;
    end else begin
        vs_d<=compositor_vs;
        event_code<=0;
        if(vs_d && !compositor_vs) begin
            occupied_frame<=occupied;
            floor_frame<=floor_idx;
        end
        if(axis_valid && axis_user && axis_ready) begin
            if(!scene_ready) armed<=0;
            else begin
                if(armed) begin
                    // Same-frame priority: visible occupancy > panel opening > slideshow.
                    if(!photo_full && floor_frame==old_floor &&
                        (((occupied_frame^old_occupied)&visible_mask)!=0)) event_code<=3;
                    else if(!old_panel && panel_visible) event_code<=2;
                    else if(!panel_visible && !photo_full && slide_slot!=old_slide) event_code<=1;
                end
                armed<=1;
                old_panel<=panel_visible;
                old_slide<=slide_slot;
                old_occupied<=occupied_frame;
                old_floor<=floor_frame;
            end
        end
    end
end
endmodule
`endif
