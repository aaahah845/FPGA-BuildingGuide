`ifndef ROOM_LIST_FADE_V
`define ROOM_LIST_FADE_V
// A floor is replaced only at zero opacity. New requests follow the latest floor.
// 【说明】房间列表淡入淡出：换楼层时先淡出到 0，再换内容并淡入。
module room_list_fade (
    input clk, rst, frame_tick, enabled,
    input [1:0] target_floor,
    input [3:0] target_room,
    output reg [1:0] shown_floor,
    output reg [3:0] shown_room,
    output reg [4:0] opacity
);
    reg fading_out;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            shown_floor <= 0;
            shown_room <= 0;
            opacity <= 16;
            fading_out <= 0;
        end else if (frame_tick) begin
            if (!enabled) begin
                shown_floor <= target_floor;
                shown_room <= target_room;
                opacity <= 16;
                fading_out <= 0;
            end else if (fading_out || target_floor != shown_floor) begin
                if (opacity > 2) begin
                    opacity <= opacity - 2;
                    fading_out <= 1;
                end else begin
                    opacity <= 0;
                    shown_floor <= target_floor;
                    shown_room <= target_room;
                    fading_out <= 0;
                end
            end else begin
                if (opacity < 16) opacity <= opacity + 2;
                shown_room <= target_room;
            end
        end
    end
endmodule
`endif
