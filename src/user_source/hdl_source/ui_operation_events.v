`ifndef UI_OPERATION_EVENTS_V
`define UI_OPERATION_EVENTS_V
// State changes, not held keys or animation positions, produce one pulse.
// 【说明】ui_operation_events：选择、缩放、详情、占用、参数变化 → 短提示事件。
//         navigation_voice_events：页面或楼层切换在屏幕上稳定后 → 播报事件（4~8）。
module ui_operation_events(
    input clk,rst,ready,
    input [1:0] floor_idx,
    input [3:0] room_idx,
    input map_mode,detail,full,auto_play,
    input [1:0] zoom,
    input [11:0] pan_x,
    input [10:0] pan_y,
    input [29:0] occupied,
    input [1:0] settings_event,commit_event,
    output reg [1:0] event_code
);
// Navigation is announced once by navigation_voice_events at visible commit.
// Automatic viewport refits must not generate extra clicks.
wire [38:0] selection={room_idx,zoom,detail,full,auto_play,occupied};
reg [38:0] previous;
reg started;
always @(posedge clk or posedge rst) begin
    if(rst) begin
        previous<=0;
        started<=0;
        event_code<=0;
    end else begin
        previous<=selection;
        started<=ready;
        event_code<=0;
        if(ready && started) begin
            if(commit_event!=0) event_code<=commit_event;
            if(selection!=previous) event_code<=1;
            if(settings_event!=0) event_code<=settings_event;
        end
    end
end
endmodule
`endif

`ifndef NAVIGATION_VOICE_EVENTS_V
`define NAVIGATION_VOICE_EVENTS_V
// Announce only a committed, visible page/floor after its transition settles.
// Room/point/detail/settings changes remain the short cues handled above.
module navigation_voice_events(
    input clk,rst,scene_ready,transition_busy,frame_accept,
    input [1:0] floor_idx,
    input map_mode,
    output reg [3:0] event_code
);
reg armed,old_map;
reg [1:0] old_floor;
always @(posedge clk or posedge rst) begin
    if(rst) begin
        armed<=0;
        old_map<=0;
        old_floor<=0;
        event_code<=0;
    end else begin
        event_code<=0;
        if(!scene_ready) armed<=0;
        else if(frame_accept && !transition_busy) begin
            if(armed) begin
                if(map_mode!=old_map) event_code<=map_mode?4'd7:4'd8;
                else if(floor_idx!=old_floor && floor_idx<3) event_code<=4'd4+{2'd0,floor_idx};
            end
            armed<=1;
            old_map<=map_mode;
            old_floor<=floor_idx;
        end
    end
end
endmodule
`endif
