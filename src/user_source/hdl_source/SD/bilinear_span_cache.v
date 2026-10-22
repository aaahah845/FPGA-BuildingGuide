`ifndef BILINEAR_SPAN_CACHE_V
`define BILINEAR_SPAN_CACHE_V
// A source span is split into even/odd RAM banks. First interpolate its TOP
// row into a third RAM; then reuse the source banks for its BOTTOM row.
// Sampling overlaps SDRAM returns and accepts one output position per clock.
// Three multipliers are shared between horizontal passes; three blend Y.
// Fractions are Q0.8; the intermediate RGB retains four fractional bits.
// 【说明】双线性缓存（ext_mem_clk）：源像素按奇偶分两组 RAM，第一遍对上一行水平插值存入 top_words，
//         第二遍对下一行水平插值并与 top_words 垂直混合。权重 Q0.8，共用 6 个乘法器。
//         关闭双线性时 nearest_* 端口直接按索引取缓存像素（地图最近邻）。
module bilinear_span_cache #(parameter CROSSFADE_SUPPORT=0)(
    input clk,rst,clear,
    input blend_write,blend_read,
    input [6:0] blend_index,
    input [6:0] blend_write_index,
    input [31:0] blend_data,
    output [15:0] blend_pixel,
    input write_enable,
    input [7:0] write_index,
    input [31:0] write_data,
    input [7:0] nearest_index,
    output [31:0] nearest_data,
    input bilinear_mode,sample_valid,sample_bottom,sample_inside,
    input [7:0] sample_left,sample_right,sample_number,
    input [7:0] fraction_x,fraction_y,
    input [31:0] padding,
    output top_written,
    output pixel_valid,
    output [31:0] pixel_data
);
reg [31:0] even_words[0:127];
reg [31:0] odd_words[0:127];
reg [35:0] top_words[0:255];
reg [31:0] even_q,odd_q;
reg [11:0] hr3,hg3,hb3;
reg [35:0] top_q;
reg [7:0] number_q,number1,number2,number3;
wire [7:0] left_index=bilinear_mode?sample_left:nearest_index;
wire [7:0] right_index=bilinear_mode?sample_right:nearest_index;
wire [6:0] even_address=left_index[0]?right_index[7:1]:left_index[7:1];
wire [6:0] odd_address=left_index[0]?left_index[7:1]:right_index[7:1];
// Separate write/read processes permit simple-dual-port RAM inference.
// EG4 maps these three logical banks to six physical 9K RAM blocks.
always @(posedge clk)
    if(write_enable && !write_index[0]) even_words[write_index[7:1]]<=write_data;
always @(posedge clk)
    if(write_enable && write_index[0]) odd_words[write_index[7:1]]<=write_data;
always @(posedge clk)
    even_q<=even_words[even_address];
always @(posedge clk)
    odd_q<=odd_words[odd_address];
always @(posedge clk)
    if(CROSSFADE_SUPPORT && blend_write)
        top_words[{1'b1,blend_write_index}]<={20'd0,blend_data[31:27],blend_data[23:18],blend_data[15:11]};
    else if(top_written) top_words[number3]<={hr3,hg3,hb3};
// Read the stored top row at the end of horizontal interpolation.
// This aligns the RAM output with hr3/hg3/hb3 without three delay banks.
always @(posedge clk)
    top_q<=top_words[(CROSSFADE_SUPPORT && blend_read)?{1'b1,blend_index}:number2];
assign blend_pixel=top_q[15:0];

reg qodd,qsame,qbottom,qinside,qvalid;
reg [7:0] qfx,qfy;
wire [31:0] left_word=qodd?odd_q:even_q;
wire [31:0] right_word=qsame?left_word:qodd?even_q:odd_q;
assign nearest_data=left_word;
reg v1,v2,v3,v4,v5,v6,bot1,bot2,bot3,in1,in2,in3,in4,in5,in6;
reg [7:0] fx1,fy1,fy2,fy3,fy4;
reg [7:0] r1,g1,b1,r2,g2,b2;
reg signed [8:0] dr1,dg1,db1;
reg signed [17:0] hr2,hg2,hb2;
reg [11:0] vr4,vg4,vb4,vr5,vg5,vb5;
reg signed [12:0] dr4,dg4,db4;
reg signed [21:0] wr5,wg5,wb5,sr6,sg6,sb6;
wire signed [17:0] hsum_r=$signed({2'd0,r2,8'd0})+hr2+18'sd8;
wire signed [17:0] hsum_g=$signed({2'd0,g2,8'd0})+hg2+18'sd8;
wire signed [17:0] hsum_b=$signed({2'd0,b2,8'd0})+hb2+18'sd8;
always @(posedge clk) begin
    qodd<=left_index[0];
    qsame<=left_index==right_index;
    qbottom<=sample_bottom;
    qinside<=sample_inside;
    qfx<=fraction_x;
    qfy<=fraction_y;
    number_q<=sample_number;
    number1<=number_q;
    number2<=number1;
    number3<=number2;
    dr1<=$signed({1'b0,right_word[31:24]})-$signed({1'b0,left_word[31:24]});
    dg1<=$signed({1'b0,right_word[23:16]})-$signed({1'b0,left_word[23:16]});
    db1<=$signed({1'b0,right_word[15:8]})-$signed({1'b0,left_word[15:8]});
    r1<=left_word[31:24];
    g1<=left_word[23:16];
    b1<=left_word[15:8];
    fx1<=qfx;
    fy1<=qfy;
    bot1<=qbottom;
    in1<=qinside;
    hr2<=dr1*$signed({1'b0,fx1});
    hg2<=dg1*$signed({1'b0,fx1});
    hb2<=db1*$signed({1'b0,fx1});
    r2<=r1;
    g2<=g1;
    b2<=b1;
    fy2<=fy1;
    bot2<=bot1;
    in2<=in1;
    hr3<=hsum_r[15:4];
    hg3<=hsum_g[15:4];
    hb3<=hsum_b[15:4];
    fy3<=fy2;
    bot3<=bot2;
    in3<=in2;
    dr4<=bot3?($signed({1'b0,hr3})-$signed({1'b0,top_q[35:24]})):13'sd0;
    dg4<=bot3?($signed({1'b0,hg3})-$signed({1'b0,top_q[23:12]})):13'sd0;
    db4<=bot3?($signed({1'b0,hb3})-$signed({1'b0,top_q[11:0]})):13'sd0;
    vr4<=bot3?top_q[35:24]:hr3;
    vg4<=bot3?top_q[23:12]:hg3;
    vb4<=bot3?top_q[11:0]:hb3;
    fy4<=fy3;
    in4<=in3;
    wr5<=dr4*$signed({1'b0,fy4});
    wg5<=dg4*$signed({1'b0,fy4});
    wb5<=db4*$signed({1'b0,fy4});
    vr5<=vr4;
    vg5<=vg4;
    vb5<=vb4;
    in5<=in4;
    sr6<=$signed({2'd0,vr5,8'd0})+wr5+22'sd2048;
    sg6<=$signed({2'd0,vg5,8'd0})+wg5+22'sd2048;
    sb6<=$signed({2'd0,vb5,8'd0})+wb5+22'sd2048;
    in6<=in5;
end
always @(posedge clk or posedge rst) begin
    if(rst) begin
        qvalid<=0;
        v1<=0;
        v2<=0;
        v3<=0;
        v4<=0;
        v5<=0;
        v6<=0;
    end else if(clear) begin
        qvalid<=0;
        v1<=0;
        v2<=0;
        v3<=0;
        v4<=0;
        v5<=0;
        v6<=0;
    end else begin
        qvalid<=sample_valid;
        v1<=qvalid;
        v2<=v1;
        v3<=v2;
        v4<=v3 && (bot3 || fy3==0);
        v5<=v4;
        v6<=v5;
    end
end
assign pixel_valid=v6;
assign top_written=v3 && !bot3;
assign pixel_data=in6?{sr6[19:12],sg6[19:12],sb6[19:12],8'd0}:padding;
endmodule
`endif
