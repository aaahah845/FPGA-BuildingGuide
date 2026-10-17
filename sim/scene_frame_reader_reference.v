`timescale 1ns/1ps
// 800x600 scanout with immutable per-frame scene/filter descriptors.
// Nearest spans stream or repeat cached samples. Bilinear spans interpolate
// the first source row into a scratch bank, then blend the adjacent row.
// Fraction-zero rows need only one read pass. All SDRAM bursts are 4-aligned.
// ============================================================================
// scene_frame_reader：读控制器（ext_mem_clk = 100 MHz）
//
// 帧描述：视频侧每帧发 read_req。IDLE/ACK 状态把 109 位 descriptor
//   （槽号、动画、地图视野、面板高度、采样方式等）经两级采样锁存到 desc，
//   本帧内不变；同时发 applied_pulse，携带 scene_tag 与本帧使用的槽掩码
//   applied_mask，资源管理器据此保护正在扫描的槽。
//
// 每行切成若干段（span），每段一种模式：
//   SOLID  纯色填充，不读内存（图片区域外、动画露出的空白）
//   NATIVE 1:1 读出（全屏照片残留路径）
//   SHRINK 640×480 → 480×360（3/4），轮播与详情照片
//   ZOOM   地图，按 Q12 步长 map_step 逐像素前进
//   区域边界同时是突发边界，不同槽的地址不会混在一段内。
//
// 读内存：每段最多 64 像素（双线性 128），突发按 4 字对齐。发读命令前检查读
//   FIFO 已用量（普通 <439，滤波 <359），保证返回数据放得下；received 只在
//   rd_valid 时加 1。大图地址越过根槽末尾时跳到尾槽（tail_base）。
// 双线性：bilinear_span_cache 先对上一行做水平插值存入暂存 RAM，再读下一行，
//   水平插值后与暂存结果垂直混合；垂直小数为 0 时只读一行。
// 保护：未请求却收到 rd_valid，或等待返回超过 4096 拍，进入 HALT 并置 fault，
//   顶层数码管显示 E。
// 状态寄存器为独热码，ns[] 为各状态的次态条件。
// ============================================================================
module scene_frame_reader_reference #(
    parameter DYNAMIC_GEOMETRY=0,SCATTERED_SLOTS=0,BILINEAR_SUPPORT=0,EASED_TRANSITIONS=1
)(
    input bilinear_enabled,
    input [12:0] scene_motion,
    input [36:0] map_view,
    input [17:0] slot_tails,
    input [65:0] slot_widths,slot_strides,
    input [59:0] slot_heights,
    input clk,rst,init_done,refresh_busy,writer_busy,core_busy,
    input read_req,
    input [8:0] fifo_used,
    input rd_valid,
    input [31:0] rd_data,
    input slide_anim,
    input [4:0] slide_phase,
    input [2:0] slide_old,
    input scene_ready,
    input [2:0] slide_slot,bg_slot,photo_slot,
    input [7:0] panel_height,
    input photo_full,
    input map_mode,map_zoom,
    input [2:0] map_slot,
    input [8:0] map_x,
    input [7:0] map_y,
    input [7:0] scene_tag,
    output reg applied_pulse,
    output reg [7:0] applied_tag,
    output reg [5:0] applied_mask,
    output reg req_ack,
    output reg fifo_clear,
    output rd_en,
    output [20:0] rd_addr,
    output fifo_we,
    output [31:0] fifo_data,
    output busy,
    output reg [2:0] applied_slot,
    output reg applied_valid,
    output reg fault
);
// Explicit one-hot transitions keep the memory-clock control decode shallow.
localparam [27:0] IDLE=25'h1,ACK=25'h2,REGION=25'h4,SOURCE=25'h8,
    SPAN=20'h10,ADDR=20'h20,CHECK=20'h40,SEND=20'h80,DRAIN=20'h100,
    ADVANCE=20'h200,FILL=20'h400,REPEAT=20'h800,HALT=20'h1000,
    PREP=20'h2000,LIMIT=20'h4000,LAST=20'h8000,FLAGS=20'h10000,ENDX=20'h20000,SCALED=20'h40000;
localparam SOLID=0,NATIVE=1,SHRINK=2,ZOOM=3;
reg [2:0] slot;
// Active slot metadata is immutable until scanout releases the slot.
// Select only the current span's metadata, then sample it twice. REGION
// selects the slot; SPAN consumes geometry six clocks later. This avoids
// replicating all six cache entries in three banks of memory-clock flops.
reg [31:0] source_meta,source_sync;
reg [2:0] tail_meta,tail_sync;
reg [20:0] tail_base,tail_adjust,head_end,logical_address,head_address,tail_address;
reg second_segment;
reg [9:0] clamped_first,clamped_last;
reg map_outside;
wire [10:0] source_width=DYNAMIC_GEOMETRY?source_sync[21:11]:11'd640;
wire [10:0] source_stride=DYNAMIC_GEOMETRY?source_sync[10:0]:11'd640;
wire [9:0] source_height=DYNAMIC_GEOMETRY?source_sync[31:22]:10'd480;
reg [28:0] state;
reg [1:0] req_sync;
reg [108:0] desc_meta,desc_sync,desc_stage,desc;
reg [5:0] mask_stage;
reg [9:0] next_x;
reg [7:0] last_emit;
reg fifo_room_output,fifo_room_read,fifo_room_filter;
always @(posedge clk or posedge rst)
    if(rst) begin
        fifo_room_output<=0;
        fifo_room_read<=0;
        fifo_room_filter<=0;
    end else begin
        fifo_room_output<=fifo_used<9'd479;
        fifo_room_read<=fifo_used<9'd439;
        fifo_room_filter<=fifo_used<9'd359;
    end
wire [5:0] descriptor_mask=!desc_sync[18]?6'd0:desc_sync[17]?(6'b1<<desc_sync[8:6]):
    ((6'b1<<(desc_sync[19]?desc_sync[23:21]:desc_sync[2:0])) |
    (desc_sync[16:9]!=0?(6'b1<<desc_sync[8:6]):6'd0) |
    (!desc_sync[19] && desc_sync[57]?(6'b1<<desc_sync[51:49]):6'd0));
wire [108:0] descriptor={BILINEAR_SUPPORT && bilinear_enabled,scene_motion,map_view,slide_anim,slide_phase,slide_old,scene_tag,map_y,map_x,map_slot,map_zoom,map_mode,scene_ready,photo_full,panel_height,photo_slot,bg_slot,slide_slot};
`include "../eased_motion_table.vh"
reg [9:0] x,y,lx,ly,sx,sy,last_sx,last_lx,edge_delta,edge_reg,photo_top,photo_bottom;
reg [9:0] vx,vy,blank_end;
reg view_valid;
reg signed [11:0] horizontal_shift,physical_edge;
reg [9:0] axis_position;
reg motion_affected;
reg signed [11:0] motion_addend,motion_delta,translated;
wire [8:0] panel_remaining=9'd210-{1'b0,desc[16:9]};
wire [9:0] panel_drop={panel_remaining,1'b0}+(panel_remaining>>1);
wire [9:0] photo_y=vy-panel_drop;
reg photo_row,map_row,carousel_row,full_row,before_boundary;
reg photo_hit,map_hit,carousel_hit,full_hit;
reg [9:0] logical_edge;
reg [9:0] qx,qy,qlast,zx,zy,zlast;

reg [1:0] mode,phase,region_mode;
reg [7:0] span_pixels,emitted;
reg [7:0] span_words,sent,received,target,last_word;
reg drained,watchdog_near,watchdog_expired;
reg [20:0] address,row_offset;
reg [4:0] quiet;
reg [11:0] watchdog;
wire [31:0] zoom_q;
// The full declared input domain needs at most 26 signed bits:
// center <= 4095*2048, delta <= 703*16383, plus 127 steps.
// This retains the Q12 fraction without a redundant three-bit carry tail.
reg signed [25:0] map_fx,map_fy,map_lfx,map_emit;
reg signed [10:0] map_dx,map_dy,map_ldx;
reg signed [25:0] map_product_x,map_product_y,map_product_last;
wire [13:0] map_step=desc[94:81];
wire signed [25:0] cx_fixed=$signed({1'b0,desc[80:69],11'b0});
wire signed [25:0] cy_fixed=$signed({1'b0,desc[68:58],11'b0});
wire signed [25:0] source_limit=$signed({1'b0,source_width,12'b0});
wire signed [25:0] height_limit=$signed({1'b0,source_height,12'b0});
reg [10:0] source_last_x,last_received_x;
wire [9:0] first_map_x=map_fx<0?0:map_fx>=source_limit?source_last_x[9:0]:map_fx>>>12;
wire [9:0] last_map_x=map_lfx<0?0:map_lfx>=source_limit?source_last_x[9:0]:map_lfx>>>12;
wire [7:0] map_index=(map_emit>>>12)-{sx[9:2],2'b0};
wire signed [25:0] map_next=map_emit+$signed({1'b0,map_step});
wire [7:0] zoom_prefetch_index=(state[11] && fifo_room_output)?((map_next>>>12)-{sx[9:2],2'b0}):map_index;
// Source bounds are integer pixels; the Q12 fractional bits never enter
// the comparison. Reject high/sign bits before the bounded width compare.
wire map_pixel_valid=(map_emit[25:23]==0) && map_emit[22:12]<source_width;

wire [4:0] zoom_index=emitted[5:2]*3+({1'b0,emitted[1:0]}*3>>2);
wire returning=(state[7] || state[8]) && received<sent;
wire [1:0] shrink_y_phase=ly[1:0]-qy[1:0]*2'd3;
wire filter_active=BILINEAR_SUPPORT && desc[108] && (mode==SHRINK || mode==ZOOM);
reg second_pass,filter_running,filter_pending;
reg [7:0] filter_issued,top_emitted,filter_fy;
reg [9:0] filter_sx;
reg [1:0] filter_phase;
wire single_row=filter_fy==0;
// Out-of-map samples become padding, so their cache address is irrelevant.
// Keep visibility and availability checks parallel: clamping a coordinate,
// adding its neighbour and comparing returned words in series is too slow.
always @(posedge clk)
    source_last_x<=source_width-11'd1;
wire [9:0] filter_raw_x=mode==ZOOM?map_emit[21:12]:filter_sx;
wire [7:0] filter_offset=filter_raw_x[7:0]-{sx[7:2],2'b0};
wire [7:0] filter_right_offset=filter_offset+({1'b0,filter_raw_x}==source_last_x?8'd0:8'd1);
wire filter_inside=mode!=ZOOM || map_pixel_valid;
// The delayed sample_inside flag selects padding at the cache output.
// Out-of-image RAM addresses are therefore don't-care values; removing
// these two muxes keeps the bounds comparator off the RAM address path.
wire [7:0] filter_left=filter_offset;
wire [7:0] filter_right=filter_right_offset;
// Compare both coordinate sources in parallel, then select their ready bit.
// Keeping these cones separate removes the mode mux from the comparator input.
(* keep *) wire map_data_ready=last_received_x>{1'b0,map_emit[21:12]} ||
    ({1'b0,map_emit[21:12]}==source_last_x && last_received_x=={1'b0,map_emit[21:12]});
(* keep *) wire photo_data_ready=last_received_x>{1'b0,filter_sx} ||
    ({1'b0,filter_sx}==source_last_x && last_received_x=={1'b0,filter_sx});
wire filter_data_ready=received!=0 && (mode==ZOOM?map_data_ready:photo_data_ready);
wire [7:0] span_first_group=mode==ZOOM?clamped_first[9:2]:sx[9:2];
wire [7:0] span_groups=clamped_last[9:2]-span_first_group+8'd1;
wire [7:0] filter_fx=mode==ZOOM?map_emit[11:4]:filter_phase==0?8'd0:filter_phase==1?8'd85:8'd171;
wire filter_sample=filter_active && filter_running && filter_pending &&
    (!filter_inside || filter_data_ready) && ((!second_pass && !single_row) || fifo_room_output) && !(state[28] && req_sync[1]);
wire filtered_valid,top_written;
wire [31:0] filtered_data;
wire filter_done=emitted==span_pixels;
wire top_done=top_emitted==span_pixels;
// next_x/edge_reg settle many clocks before ADVANCE consumes this flag.
reg fast_span;
always @(posedge clk)
    fast_span<=next_x<edge_reg && next_x<10'd800;
wire keep=!filter_active && mode!=ZOOM && received==target && emitted<span_pixels;
reg [9:0] boundary,slide_offset,old_origin;
reg [9:0] edge_x,gx,gy;
reg [9:0] x8,x80,x320,x288,xbound,xold,y60,y56,y48,y120;
always @(posedge clk) begin
    x8<=vx-10'd8;
    x80<=vx-80;
    x320<=vx-304;
    x288<=vx-288;
    xbound<=vx-boundary;
    xold<=vx+old_origin;
    y60<=vy-60;
    y56<=vy-56;
    y48<=vy-64;
    y120<=photo_y-136;
end
reg [1:0] gm;
reg [2:0] gs;
// Region boundaries are also burst boundaries; a panel never leaks map
// addresses into its photo and an animation never mixes its two slots.
always @* begin
    edge_x=800;
    gx=0;
    gy=0;
    gm=SOLID;
    gs=0;
    if(desc[17]) begin
        if(full_row) begin
            if(vx<80) edge_x=80;
            else if(vx<720) begin
                edge_x=720;
            end
        end
    end else begin
        if(map_row && vx<648) begin
            if(vx<8) edge_x=8;
            else begin
                edge_x=648;
            end
        end else if(carousel_row) begin
            if(vx<304) edge_x=304;
            else if(vx<784) begin
                edge_x=784;

                if(desc[57]) begin
                    if(before_boundary) edge_x=boundary;
                end
            end
        end
        if(photo_row) begin
            if(vx<288) begin
                if(edge_x>288) edge_x=288;
            end else if(vx<768) begin
                edge_x=768;
            end
        end
    end
    // The hit tests were registered in the existing FLAGS stage. Slot/mode
    // and coordinate selection therefore share one short priority mux, without an extra
    // scanout cycle or a coordinate comparator on the slot-register input.
    if(full_hit) begin
        gm=NATIVE;
        gs=desc[8:6];
        gx=x80;
        gy=y60;
    end else if(photo_hit) begin
        gm=SHRINK;
        gs=desc[8:6];
        gx=x288;
        gy=y120;
    end else if(map_hit) begin
        gm=ZOOM;
        gs=desc[23:21];
        gx=x8;
        gy=y56;
    end else if(carousel_hit) begin
        gm=SHRINK;
        gs=desc[57] && before_boundary?desc[51:49]:desc[2:0];
        gx=desc[57]?(before_boundary?xold:xbound):x320;
        gy=y48;
    end
end
function[20:0] base;
    input [2:0] idx;
    begin
        case(idx)
            0:base=0;
            1:base=307200;
            2:base=614400;
            3:base=921600;
            4:base=1228800;
            5:base=1536000;
            default:base=0;
        endcase
    end
endfunction
assign rd_en=state[7];
assign rd_addr=address;
assign busy=state[7] || state[8];
// Register both the pixel and its enable before the asynchronous FIFO.
// The 32-word headroom also covers this one pending output word.
wire push_pixel=((state[10] || state[11]) && fifo_room_output) || (rd_valid && returning && keep) || filtered_valid;
wire [31:0] padding=desc[19]?32'hdadcd900:32'hf3f5f900;
wire [31:0] push_data=filtered_valid?filtered_data:state[10]?padding:state[11]?(map_pixel_valid?zoom_q:padding):rd_data;
bilinear_span_cache filter_cache(
    .clk(clk),
    .rst(rst),
    .clear(fifo_clear || state[12]),
    .write_enable(rd_valid && returning && (filter_active || mode==ZOOM)),
    .write_index(received),
    .write_data(rd_data),
    .nearest_index(zoom_prefetch_index),
    .nearest_data(zoom_q),
    .bilinear_mode(filter_active),
    .sample_valid(filter_sample),
    .sample_bottom(second_pass),
    .sample_inside(filter_inside),
    .sample_left(filter_left),
    .sample_right(filter_right),
    .sample_number(filter_issued),
    .fraction_x(filter_fx),
    .fraction_y(filter_fy),
    .padding(padding),
    .top_written(top_written),
    .pixel_valid(filtered_valid),
    .pixel_data(filtered_data)
);
reg pixel_pending;
reg [31:0] pixel_data;
assign fifo_we=pixel_pending && !fifo_clear;
assign fifo_data=pixel_data;
always @(posedge clk or posedge rst)
    if(rst) pixel_pending<=0;
    else if(fifo_clear) pixel_pending<=0;
    else pixel_pending<=push_pixel;
// Invalid data need not be held/reset. Removing its CE avoids routing
// the full pixel-valid comparison onto every data-register enable.
always @(posedge clk)
    pixel_data<=push_data;
always @(posedge clk or posedge rst) begin
    if(rst) begin
        req_sync<=0;
        desc_meta<=0;
        desc_sync<=0;
        desc_stage<=0;
        mask_stage<=0;
        tail_meta<=0;
        tail_sync<=0;
        source_meta<={10'd480,11'd640,11'd640};
        source_sync<={10'd480,11'd640,11'd640};
    end else begin
        req_sync<={req_sync[0],read_req};
        desc_meta<=descriptor;
        desc_sync<=desc_meta;
        desc_stage<=desc_sync;
        mask_stage<=descriptor_mask;
        tail_meta<=slot_tails[slot*3+:3];
        tail_sync<=tail_meta;
        source_meta<={slot_heights[slot*10+:10],slot_widths[slot*11+:11],slot_strides[slot*11+:11]};
        source_sync<=source_meta;
    end
end

// Free-running arithmetic settles while the region/span states advance.
// The consumer still waits through SOURCE/SCALED/PREP, so no stale result
// is consumed. Unconditional DSP/data registers avoid reset/enable muxes.
always @(posedge clk) begin
    map_dx<=$signed({1'b0,lx})-11'sd320;
    map_dy<=$signed({1'b0,ly})-11'sd240;
    map_ldx<=$signed({1'b0,last_lx})-11'sd320;
    qx<=lx/10'd3;
    qy<=ly/10'd3;
    qlast<=last_lx/10'd3;
    map_product_x<=map_dx*$signed({1'b0,map_step});
    map_product_last<=map_ldx*$signed({1'b0,map_step});
    map_product_y<=map_dy*$signed({1'b0,map_step});
    map_fx<=cx_fixed+map_product_x;
    map_lfx<=cx_fixed+map_product_last;
    map_fy<=cy_fixed+map_product_y;
end
always @(posedge clk) begin
    tail_base<=base(tail_sync);
    tail_adjust<=base(tail_sync)-21'd307200;
    head_end<=base(slot)+21'd307199;
end
wire fatal_now=(rd_valid && !returning) || watchdog_expired;
wire invalid_desc=desc_stage[18] && (desc_stage[2:0]>=6 || desc_stage[8:6]>=6 || desc_stage[23:21]>=6 || (desc_stage[57] && desc_stage[51:49]>=6));
wire check_fill=mode==SOLID && fifo_room_read;
wire check_send=(filter_active?fifo_room_filter:fifo_room_read) && !writer_busy && !refresh_busy && !core_busy;
wire end_span=fifo_room_output && emitted==last_emit;
wire end_read=drained && quiet>=10;
wire recover_frame=state[12] && req_sync[1] && quiet>=16 && !core_busy && !refresh_busy && !rd_valid;
wire [28:0] ns;
assign ns[0]=(state[0] && !(req_sync[1] && init_done)) || (state[1] && !req_sync[1] && !desc_stage[18]) || (state[9] && !req_sync[1] && next_x==800 && y==599);
assign ns[1]=(state[0] && req_sync[1] && init_done) || (state[1] && req_sync[1]) || ((state[6] || state[9] || state[10] || state[11] || state[28]) && req_sync[1]) || recover_frame;
assign ns[2]=state[23];
assign ns[19]=state[16];
assign ns[22]=state[19];
assign ns[23]=state[22];
assign ns[3]=state[17];
assign ns[24]=state[18];
assign ns[27]=state[24];
assign ns[4]=state[27];
assign ns[5]=state[4] || (state[8] && end_read && filter_active && !single_row && !second_pass && top_done);
assign ns[25]=state[5];
assign ns[26]=state[25];
assign ns[6]=state[26] || (state[6] && !req_sync[1] && !check_fill && !check_send);
assign ns[7]=(state[6] && !req_sync[1] && !check_fill && check_send) || (state[7] && sent!=last_word);
assign ns[8]=(state[7] && sent==last_word) || (state[8] && (!end_read || (filter_active && !single_row && !second_pass && !top_done)));
assign ns[9]=((state[10] || state[11]) && end_span && !req_sync[1]) || (state[8] && end_read && !filter_active && mode!=ZOOM) ||
    (state[8] && end_read && filter_active && (second_pass || single_row) && filter_done) || (state[28] && filter_done && !req_sync[1]);
assign ns[10]=(state[6] && !req_sync[1] && check_fill) || (state[10] && !end_span && !req_sync[1]);
assign ns[11]=(state[8] && end_read && mode==ZOOM && !filter_active) || (state[11] && !end_span && !req_sync[1]);
assign ns[28]=(state[8] && end_read && filter_active && (second_pass || single_row) && !filter_done) || (state[28] && !filter_done && !req_sync[1]);
assign ns[12]=(state[12] && !recover_frame) || (state[1] && !req_sync[1] && invalid_desc);
assign ns[13]=state[1] && !req_sync[1] && desc_stage[18] && !invalid_desc;
assign ns[20]=state[2];
assign ns[21]=state[20];
assign ns[14]=state[21];
assign ns[15]=state[14] || (state[9] && !req_sync[1] && fast_span);
assign ns[16]=state[13] || (state[9] && !req_sync[1] && !fast_span && !(next_x==800 && y==599));
assign ns[17]=state[15];
assign ns[18]=state[3];
always @(posedge clk or posedge rst)
    if(rst) state<=IDLE;
    else state<=fatal_now?HALT:ns;

always @(posedge clk or posedge rst) begin
    if(rst) begin
        photo_hit<=0;
        map_hit<=0;
        carousel_hit<=0;
        full_hit<=0;
        last_received_x<=0;
        region_mode<=SOLID;
        second_pass<=0;
        filter_running<=0;
        filter_pending<=0;
        filter_issued<=0;
        top_emitted<=0;
        filter_fy<=0;
        filter_sx<=0;
        filter_phase<=0;
        before_boundary<=0;
        logical_edge<=800;
        logical_address<=0;
        head_address<=0;
        tail_address<=0;
        second_segment<=0;
        clamped_first<=0;
        clamped_last<=0;
        map_outside<=0;
        axis_position<=0;
        motion_affected<=0;
        motion_addend<=0;
        motion_delta<=0;
        translated<=0;

        vx<=0;
        vy<=0;
        blank_end<=800;
        view_valid<=0;
        horizontal_shift<=0;
        physical_edge<=800;
        map_emit<=0;
        next_x<=0;
        last_emit<=0;
        desc<=0;
        req_ack<=0;
        fifo_clear<=1;
        applied_slot<=0;
        applied_valid<=0;
        applied_pulse<=0;
        applied_tag<=0;
        applied_mask<=0;
        fault<=0;
        x<=0;
        y<=0;
        lx<=0;
        ly<=0;
        sx<=0;
        sy<=0;
        last_sx<=0;
        last_lx<=0;
        edge_delta<=0;
        edge_reg<=0;
        photo_top<=300;
        photo_bottom<=300;
        photo_row<=0;
        map_row<=0;
        carousel_row<=0;
        full_row<=0;
        boundary<=800;
        slide_offset<=0;
        old_origin<=0;
        slot<=0;
        mode<=0;
        phase<=0;
        span_pixels<=32;
        emitted<=0;
        span_words<=32;
        sent<=0;
        received<=0;
        target<=0;
        address<=0;
        row_offset<=0;
        quiet<=0;
        watchdog<=0;
        last_word<=31;
        drained<=0;
        watchdog_near<=0;
        watchdog_expired<=0;

    end else begin
        applied_pulse<=0;
        if(fifo_clear || state[9] || state[12]) filter_running<=0;
        if(top_written) top_emitted<=top_emitted+1'b1;
        if(filtered_valid) emitted<=emitted+1'b1;
        if(filter_sample) begin
            // Stop on the final accepted sample. The registered budget bit removes
            // the span-length comparator from every sample consumer's enable path.
            if(filter_issued==last_emit) filter_pending<=0;
            filter_issued<=filter_issued+1'b1;
            if(mode==ZOOM) map_emit<=map_next;
            else begin
                filter_sx<=filter_sx+(filter_phase==2?2:1);
                filter_phase<=filter_phase==2?0:filter_phase+1'b1;
            end
        end
        drained<=received==span_words;
        watchdog_near<=watchdog==4093 && !rd_valid;
        watchdog_expired<=watchdog_near && !rd_valid;
        if(rd_en || (state[12] && (rd_valid || core_busy || refresh_busy))) quiet<=0;
        else if(quiet<31) quiet<=quiet+1'b1;
        if(state[8] && received!=span_words && !rd_valid) watchdog<=watchdog+1'b1;
        else watchdog<=0;
        if(rd_valid && returning) begin
            received<=received+1'b1;
            last_received_x<=last_received_x+1'b1;
            if(keep) begin
                emitted<=emitted+1'b1;
                target<=target+((mode==SHRINK && phase==2)?2:1);
                if(mode==SHRINK) phase<=phase==2?0:phase+1'b1;
            end
        end
        (* parallel_case *) case(1'b1)
            state[0]:if(req_sync[1] && init_done) begin
                req_ack<=1;
                fifo_clear<=1;
            end
            state[1]:if(!req_sync[1]) begin
                req_ack<=0;
                fifo_clear<=0;
                desc<=desc_stage;
                x<=0;
                y<=0;
                applied_slot<=desc_stage[2:0];
                applied_valid<=desc_stage[18];
                applied_pulse<=1;
                applied_tag<=desc_stage[48:41];
                applied_mask<=mask_stage;
                slide_offset<=EASED_TRANSITIONS?eased_slide_position(desc_stage[56:52]):({1'b0,desc_stage[56:52],4'b0}+{2'b0,desc_stage[56:52],3'b0});

                if(desc_stage[18] && (desc_stage[2:0]>=6 || desc_stage[8:6]>=6 || desc_stage[23:21]>=6 || (desc_stage[57] && desc_stage[51:49]>=6))) begin
                    fault<=1;
                    applied_valid<=0;
                    applied_mask<=0;
                end
            end
            state[13]: begin
                boundary<=784-slide_offset;
                old_origin<=slide_offset-304;
                photo_top<=136+panel_drop;
                photo_bottom<=496+panel_drop;
                motion_addend<=desc[106]?$signed({2'b0,desc[104:95]}):-$signed({2'b0,desc[104:95]});
                motion_delta<=desc[106]?-$signed({2'b0,desc[104:95]}):$signed({2'b0,desc[104:95]});
            end
            state[16]: begin
                axis_position<=desc[107]?y:x;
                motion_affected<=desc[105] && y<568 && (!desc[107] || (x>=8 && x<648 && y>=56 && y<536));
            end
            state[19]:translated<=$signed({2'b0,axis_position})+motion_addend;
            state[22]: begin
                vx<=motion_affected && !desc[107]?translated[9:0]:x;
                vy<=motion_affected && desc[107]?translated[9:0]:y;
                view_valid<=!motion_affected || (desc[107]?(translated>=12'sd56 && translated<12'sd536):(translated>=0 && translated<12'sd800));
                blank_end<=motion_affected && !desc[107] && translated<0 ? desc[104:95] : (desc[107]?10'd648:10'd800);
                horizontal_shift<=motion_affected && !desc[107]?motion_delta:12'sd0;
            end
            state[23]: begin
                before_boundary<=vx<boundary;
                photo_row<=!desc[17] && desc[16:9]!=0 && vy>=photo_top && vy<photo_bottom && y<568;
                map_row<=desc[19] && vy>=56 && vy<536;
                carousel_row<=!desc[19] && vy>=64 && vy<424;
                full_row<=vy>=60 && vy<540;
                full_hit<=desc[17] && vy>=60 && vy<540 && vx>=80 && vx<720;
                photo_hit<=!desc[17] && desc[16:9]!=0 && vy>=photo_top && vy<photo_bottom && y<568 && vx>=288 && vx<768;
                map_hit<=!desc[17] && desc[19] && vy>=56 && vy<536 && vx>=8 && vx<648;
                carousel_hit<=!desc[17] && !desc[19] && vy>=64 && vy<424 && vx>=304 && vx<784;
            end
            state[2]: begin
                lx<=gx;
                ly<=gy;
                mode<=view_valid?gm:SOLID;
                region_mode<=view_valid?gm:SOLID;
                slot<=gs;
                logical_edge<=edge_x;
                second_pass<=0;
            end
            // Keep translation, region selection, edge addition, clipping and length
            // subtraction in separate cycles. All arithmetic is explicitly bounded.
            state[20]:physical_edge<=$signed({2'b0,logical_edge})+horizontal_shift;
            state[21]:edge_reg<=!view_valid ? blank_end : (physical_edge>12'sd800 ? 10'd800 : physical_edge[9:0]);
            state[14]: begin
                edge_delta<=edge_reg-x;
            end
            state[15]: begin
                span_pixels<=edge_delta<(filter_active?128:64)?edge_delta:(filter_active?128:64);
                second_pass<=0;
            end
            state[17]: begin
                next_x<=x+span_pixels;
                last_emit<=span_pixels-1'b1;
                last_lx<=lx+span_pixels-1'b1;
            end

            state[18]: begin
                case(mode)
                    SHRINK: begin
                        sx<=lx+qx;
                        sy<=ly+qy;
                        last_sx<=last_lx+qlast;
                        phase<=lx[1:0]-qx[1:0]*2'd3;
                        filter_fy<=shrink_y_phase==0?0:shrink_y_phase==1?85:171;
                    end
                    ZOOM:;
                    default: begin
                        sx<=lx;
                        sy<=ly;
                        last_sx<=last_lx;
                        phase<=0;
                    end
                endcase
            end

            state[27]: begin
                clamped_first<=first_map_x;
                clamped_last<=mode==ZOOM?last_map_x:last_sx;
                // Both map and photo coordinates have settled in earlier setup cycles.
                // Reuse this flag for every mode, keeping range comparisons off mode's
                // high-fanout register input in the following SPAN cycle.
                map_outside<=mode==ZOOM ?
                    (map_fy<0 || map_fy>=height_limit || map_lfx<0 || map_fx>=source_limit) :
                    (sy>=source_height || last_sx>=source_width);
            end
            state[4]: begin
                // The raw clamp, neighbour extension and aligned length occupy separate
                // existing setup clocks; the SDRAM issue schedule is unchanged.
                clamped_last<=clamped_last+(filter_active && clamped_last<source_last_x?10'd1:10'd0);
                if(mode==ZOOM) begin
                    sx<={clamped_first[9:2],2'b0};
                    sy<=map_fy[21:12];
                    filter_fy<=map_fy[11:4];
                    row_offset<=map_fy[21:12]*source_stride;
                end else begin
                    target<={5'd0,sx[1:0]};
                    row_offset<=sy*source_stride;
                end
                if(map_outside) mode<=SOLID;
            end
            state[5]: begin
                span_words<={span_groups[5:0],2'b0};
                logical_address<=row_offset+{sx[9:2],2'b00};
            end
            state[25]: begin
                last_word<=span_words-1'b1;
                head_address<=base(slot)+logical_address;
                tail_address<=tail_adjust+logical_address;
                second_segment<=SCATTERED_SLOTS && logical_address>=21'd307200;
            end
            state[26]:address<=second_segment?tail_address:head_address;
            state[6]:if(req_sync[1]) begin
                req_ack<=1;
                fifo_clear<=1;
            end else if(mode==SOLID && fifo_room_read) begin
                emitted<=0;
            end else if(check_send) begin
                sent<=0;
                received<=0;
                emitted<=0;
                map_emit<=map_fx;
                last_received_x<={1'b0,sx[9:2],2'b0}-11'd1;
                filter_pending<=span_pixels!=0;
                filter_issued<=0;
                filter_sx<=sx;
                filter_phase<=phase;
                filter_running<=filter_active;
                if(!second_pass) top_emitted<=0;
            end
            (state[10] | state[11]):if(req_sync[1]) begin
                req_ack<=1;
                fifo_clear<=1;
            end else if(fifo_room_output) begin
                emitted<=emitted+1'b1;
                if(state[11]) map_emit<=map_emit+$signed({1'b0,map_step});
            end
            // No memory responses remain in FILTER_WAIT. A new frame may discard the
            // unfinished old span even if its output FIFO has stopped being consumed.
            state[28]:if(req_sync[1]) begin
                req_ack<=1;
                fifo_clear<=1;
            end
            state[7]: begin
                sent<=sent+1'b1;
                address<=SCATTERED_SLOTS && address==head_end?tail_base:address+1'b1;
            end
            state[8]:if(end_read && filter_active && !single_row && !second_pass && top_done) begin
                second_pass<=1;
                filter_running<=0;
                if(sy<source_height-1) row_offset<=row_offset+source_stride;
            end
            state[9]:if(req_sync[1]) begin
                req_ack<=1;
                fifo_clear<=1;
            end else if(next_x==800) begin
                x<=0;
                if(y!=599) begin
                    y<=y+1'b1;
                end
            end else begin
                x<=next_x;
                if(fast_span) begin
                    lx<=lx+span_pixels;
                    edge_delta<=edge_reg-next_x;
                    mode<=region_mode;
                end
            end
            state[12]: begin
                req_ack<=recover_frame;
                fifo_clear<=1;
                applied_valid<=0;
            end
            default:;
        endcase
        if((rd_valid && !returning) || watchdog_expired) begin
            fault<=1;
            applied_valid<=0;
        end
    end
end
endmodule
