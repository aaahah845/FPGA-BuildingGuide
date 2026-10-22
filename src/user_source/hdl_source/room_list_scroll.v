`ifndef ROOM_LIST_SCROLL_V
`define ROOM_LIST_SCROLL_V
// Six readable rows; at most one extra clipped row is drawn while moving.
// 【说明】房间列表滚动：选中第 7~10 间时，列表按每帧 14 像素向目标位置滚动。
module room_list_scroll(
    input clk,rst,frame_tick,
    input [1:0] floor_idx,
    input [3:0] room_idx,
    output reg [3:0] first_room,
    output wire [6:0] pixel_shift,
    output reg [8:0] position
);
reg [1:0] old_floor;
reg [8:0] target,base;
always @* begin
    target=room_idx>5?(room_idx==6?70:room_idx==7?140:room_idx==8?210:280):0;
    if(position>=280) begin
        first_room=4;
        base=280;
    end else if(position>=210) begin
        first_room=3;
        base=210;
    end else if(position>=140) begin
        first_room=2;
        base=140;
    end else if(position>=70) begin
        first_room=1;
        base=70;
    end else begin
        first_room=0;
        base=0;
    end
end
assign pixel_shift=position-base;
always @(posedge clk or posedge rst) begin
    if(rst) begin
        position<=0;
        old_floor<=0;
    end else if(frame_tick) begin
        old_floor<=floor_idx;
        if(old_floor!=floor_idx) position<=0;
        else if(position<target) position<=target-position<=14?target:position+14;
        else if(position>target) position<=position-target<=28?target:position-28;
    end
end
endmodule
`endif
