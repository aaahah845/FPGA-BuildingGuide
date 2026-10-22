`ifndef SCENE_MOTION_V
`define SCENE_MOTION_V
// One scene at a time: outgoing content leaves before the incoming scene
// is committed. Bit 12: map-only vertical; 11: negative shift; 10: active.
// 【说明】页面/楼层切换动画的坐标变换：横向或纵向平移，返回平移后坐标与是否落在有效区域。
module scene_motion_xy(
    input [12:0] motion,
    input [9:0] x,y,
    output [9:0] vx,vy,
    output valid,
    output [9:0] blank_end,
    output signed [11:0] horizontal_shift
);
wire active=motion[10];
wire vertical=motion[12];
wire signed [11:0] delta=motion[11]?-$signed({2'b0,motion[9:0]}):$signed({2'b0,motion[9:0]});
wire affected=active && y<568 && (!vertical || (x>=8 && x<648 && y>=56 && y<536));
// Share a single add/subtract chain between the two motion axes.
wire [11:0] axis_position=vertical?{2'b0,y}:{2'b0,x};
wire [11:0] operand=motion[11]?{2'b0,motion[9:0]}:~{2'b0,motion[9:0]};
wire signed [11:0] translated=axis_position+operand+!motion[11];
wire signed [11:0] tx=affected&&!vertical?translated:$signed({2'b0,x});
wire signed [11:0] ty=affected&&vertical?translated:$signed({2'b0,y});
assign vx=tx[9:0];
assign vy=ty[9:0];
assign valid=!affected || (vertical?(ty>=56 && ty<536):(tx>=0 && tx<800));
assign blank_end=affected && !vertical && tx<0?delta[9:0]:vertical?10'd648:10'd800;
assign horizontal_shift=affected&&!vertical?delta:12'sd0;
endmodule
`endif
