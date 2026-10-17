`timescale 1ns/1ps
// Independent overlay scoreboard with encrypted SDRAM command/return timing,
// concurrent writes and refresh. Known address-pattern data replaces SDRAM
// electrical data. Mixed frames keep RGB888/bilinear outside the native photo;
// frame 6 checks the settled full photo with the retained map/detail border.
module tb_vendor_crossfade;
reg bilinear=0,frame_bilinear=0;
reg clk=0,rst=1,req=0;always #5 clk=~clk;
wire ack,clear,re,we,fault,rbusy;wire[20:0]addr;wire[31:0]word;wire[5:0]mask;
wire app_pulse,app_valid;wire[7:0]app_tag;wire[2:0]app_slot;
wire r_ack,r_clear,r_re,r_we,r_fault,r_busy;wire[20:0]r_addr;wire[31:0]r_word;wire[5:0]r_mask;
wire r_app_pulse,r_app_valid;wire[7:0]r_app_tag;wire[2:0]r_app_slot;
reg anim=0,full=0,mixed=1,native_hit=0;reg[4:0]phase=0;integer boundary;
reg[12:0]motion=0;reg map=1;reg[7:0]half=0;wire rv;wire[31:0]return_word;reg[2:0]tail_slot=5;reg[13:0]step=6554;
reg[11:0]cx2=1024;reg[10:0]cy2=600;reg[10:0]mw=1024;reg[9:0]mh=600;reg check_expected=1;
reg[8:0]used=0;integer i,n=0,f=0,x,y,xx,yy,sx,sy,drop,slot,total=0,compared=0;
reg[31:0]expected;reg visible;
integer direct_checks=0,direct_returns=0,cached_returns=0;
integer sample_checks=0,filter_running_checks=0,filter_samples=0,first_pass_samples=0;
integer native_count=0,retained_count=0,boundary_checks=0;
wire legacy_filter_sample=dut.filter_active && dut.filter_running && dut.filter_pending &&
    (!dut.filter_inside || dut.filter_data_ready) &&
    ((!dut.second_pass && !dut.single_row) || dut.fifo_room_output) &&
    !(dut.state[28] && dut.req_sync[1]);
function[31:0]pattern;input[20:0]a;reg[7:0]r,g,b;begin
r=a[7:0]^a[16:9];g=a[10:3]^a[19:12];b=a[15:8]^a[7:0];pattern={r,g,b,8'd0};end endfunction
function[31:0]sample;input integer sl,xx,yy;integer a;begin
a=yy*(sl==3?1024:640)+xx;
if(sl==3 && a>=307200)a=tail_slot*307200+a-307200;else a=sl*307200+a;
sample=pattern(a);end endfunction
function[7:0]blend;input[7:0]a,b,c,d;input integer fx,fy;integer top,bottom;begin
top=(a*(256-fx)+b*fx+8)>>4;bottom=(c*(256-fx)+d*fx+8)>>4;
blend=(top*(256-fy)+bottom*fy+2048)>>12;end endfunction
reg[31:0]p00,p01,p10,p11;integer wx,wy,sw,sh,x1,y1,local_x,local_y;
wire init,cbusy,refresh,core_refresh,reserve,refreq,wbusy,wack,wdone,wen;
wire[20:0]waddr;reg wreq=0;wire shift;assign #5 shift=clk;
wire sclk,ras,cas,swe;wire[1:0]bank;wire[10:0]saddr;wire[3:0]dm;wire[31:0]dq,unused_data;
assign refresh=reserve|core_refresh;
sdram_refresh_guard #(.PERIOD(3125)) guard(.clk(clk),.rst(rst),.init_done(init),.core_busy(cbusy),.core_refresh_busy(core_refresh),.app_rd_en(re),.app_wr_en(wen),.busy(reserve),.request(refreq));
sdr_as_ram #(.self_refresh_open(0)) core(.Sdr_clk(clk),.Sdr_clk_sft(shift),.Rst(rst),.Sdr_init_done(init),.Sdr_init_ref_vld(core_refresh),.Sdr_busy(cbusy),.App_ref_req(refreq),
.App_wr_en(wen),.App_wr_addr(waddr),.App_wr_dm(4'd0),.App_wr_din(32'h12345678),.App_rd_en(re),.App_rd_addr(addr),.Sdr_rd_en(rv),.Sdr_rd_dout(unused_data),
.SDRAM_CLK(sclk),.SDR_RAS(ras),.SDR_CAS(cas),.SDR_WE(swe),.SDR_BA(bank),.SDR_ADDR(saddr),.SDR_DM(dm),.SDR_DQ(dq));
reg[8:0]writer_used=0;integer feed_tick=0;wire writer_clear;
always @(posedge clk)begin
 if(rst || writer_clear)begin writer_used<=0;feed_tick<=0;end
 else begin
 feed_tick<=feed_tick==47?0:feed_tick+1;
 case({feed_tick==47 && writer_used<400,wen})
 2'b10:writer_used<=writer_used+1'b1;
 2'b01:writer_used<=writer_used-1'b1;
 endcase
 if(wen && writer_used==0)$fatal(1,"write FIFO underflow");
 end
end
frame_fifo_write #(.DYNAMIC_GEOMETRY(1),.SCATTERED_SLOTS(1),.BURST_SIZE(256)) writer(
.image_stride(11'd1024),.image_first_offset(21'd613376),.image_bottom_up(1'b1),.write_tail_index(3'd2),
.mem_clk(clk),.rst(rst),.write_abort(1'b0),.Sdr_init_done(init),.Sdr_init_ref_vld(refresh),.Sdr_busy(cbusy),.App_rd_busy(rbusy),.O_wr_busy(wbusy),
.App_wr_en(wen),.App_wr_addr(waddr),.write_req(wreq),.write_req_ack(wack),.write_finish(wdone),
.write_addr_0(21'd0),.write_addr_1(21'd307200),.write_addr_2(21'd614400),.write_addr_3(21'd921600),.write_addr_4(21'd1228800),.write_addr_5(21'd1536000),
.write_addr_index(3'd0),.write_len(21'd614400),.fifo_aclr(writer_clear),.rdusedw(writer_used));
reg[20:0]queue[0:4095];integer iq=0,oq=0,writes=0,refs=0;reg prev_re=0,prev_we=0;
assign return_word=pattern(queue[oq%4096]);
always @(posedge clk)if(!rst)begin
 if(re)begin
  if(iq-oq>=4096)$fatal(1,"SDRAM command queue overflow");
  queue[iq%4096]=addr;iq=iq+1;
 end
 if(rv)begin if(oq>=iq)$fatal(1,"orphan controller return");oq<=oq+1;end
 if(re && wen)$fatal(1,"read/write overlap");
 if(wen)writes=writes+1;if(refreq)refs=refs+1;prev_re=re;prev_we=wen;
end
initial begin wait(!rst);wait(init);@(negedge clk);wreq=1;wait(wack);repeat(8)@(negedge clk);wreq=0;end
// DUT drives the shared SDRAM controller; expected coordinates are independent.
`define READER_PORTS \
 .bilinear_enabled(bilinear),.clk(clk),.rst(rst),.scene_motion(motion),.map_view({step,cx2,cy2}),.slot_tails({3'd0,3'd0,tail_slot,9'd0}), \
 .slot_widths({{2{11'd640}},mw,{3{11'd640}}}),.slot_strides({{2{11'd640}},mw,{3{11'd640}}}),.slot_heights({{2{10'd480}},mh,{3{10'd480}}}), \
 .init_done(init),.refresh_busy(refresh),.writer_busy(wbusy),.core_busy(cbusy),.read_req(req),.fifo_used(used),.rd_valid(rv),.rd_data(return_word), \
 .slide_anim(anim),.slide_phase(phase),.slide_old(3'd1),.scene_ready(1'b1),.slide_slot(3'd0),.bg_slot(3'd0),.photo_slot(3'd4), \
 .panel_height(half),.photo_full(full),.map_mode(map),.map_zoom(1'b0),.map_slot(3'd3),.map_x(9'd0),.map_y(8'd0),.scene_tag(8'd1)
scene_frame_reader #(.DYNAMIC_GEOMETRY(1),.SCATTERED_SLOTS(1),.BILINEAR_SUPPORT(1),.CROSSFADE_SUPPORT(1)) dut(`READER_PORTS,.photo_blend(mixed),
 .req_ack(ack),.fifo_clear(clear),.rd_en(re),.rd_addr(addr),.fifo_we(we),.fifo_data(word),.busy(rbusy),.fault(fault),
 .applied_pulse(app_pulse),.applied_tag(app_tag),.applied_mask(mask),.applied_slot(app_slot),.applied_valid(app_valid));
// 帧 0~11 保留原回归的逐像素期望值（地图中心固定为 512,300、宽 1024）
always @(posedge clk)begin
 if(!rst)begin
  sample_checks=sample_checks+1;
  if(dut.filter_sample!==legacy_filter_sample)
   $fatal(1,"FILTER SAMPLE MISMATCH frame=%0d state=%h old=%b new=%b first_pass=%b",f,dut.state,legacy_filter_sample,dut.filter_sample,(!dut.second_pass && !dut.single_row));
  if(dut.filter_running)begin
   filter_running_checks=filter_running_checks+1;
   if(dut.filter_active!==1'b1)$fatal(1,"FILTER RUNNING WITHOUT ACTIVE frame=%0d state=%h",f,dut.state);
  end
  if(dut.filter_sample)begin
   filter_samples=filter_samples+1;
   if(!dut.second_pass && !dut.single_row)first_pass_samples=first_pass_samples+1;
  end
 end
 if(!rst && init && dut.returning)begin
  direct_checks=direct_checks+1;
  if(dut.direct_read!==(!dut.filter_active && dut.mode!=3))
   $fatal(1,"DIRECT READ MISMATCH frame=%0d state=%h mode=%0d filter=%b direct=%b",f,dut.state,dut.mode,dut.filter_active,dut.direct_read);
  if(rv)begin
   if(dut.direct_read)direct_returns=direct_returns+1;
   else cached_returns=cached_returns+1;
  end
 end
 if(!rst && fault)$fatal(1,"reader fault");
 if(!rst && we)begin
 x=n%800;y=n/800;xx=x;yy=y;visible=1;slot=-1;sx=0;sy=0;
 native_hit=x>=80 && x<720 && y>=60 && y<540;
 if(motion[10] && y<568)begin
  if(!motion[12])begin xx=x+(motion[11]?motion[9:0]:-motion[9:0]);visible=xx>=0 && xx<800;end
  else if(x>=8 && x<648 && y>=56 && y<536)begin yy=y+(motion[11]?motion[9:0]:-motion[9:0]);visible=yy>=56 && yy<536;end
 end
 drop=(210-half)*2+(210-half)/2;
 if(visible && full && native_hit)begin
  slot=4;sx=x-80;sy=y-60;
 end else if(visible && half!=0 && xx>=288 && xx<768 && yy>=136+drop && yy<496+drop && y<568)begin
  slot=4;sx=(xx-288)*4/3;sy=(yy-136-drop)*4/3;
 end else if(visible && !map && xx>=304 && xx<784 && yy>=64 && yy<424)begin
  boundary=784-82;slot=0;sx=(xx-304)*4/3;sy=(yy-64)*4/3;
  if(anim)begin
   if(xx<boundary)begin slot=1;sx=(xx-304+82)*4/3;end
   else sx=(xx-boundary)*4/3;
  end
 end
 if(visible && !(full && native_hit) && map && xx>=8 && xx<648 && yy>=56 && yy<536 && !(half!=0 && xx>=288 && xx<768 && yy>=136+drop && yy<496+drop && y<568))begin
  sx=(512*4096+(xx-8-320)*step)>>>12;sy=(300*4096+(yy-56-240)*step)>>>12;
  slot=sx>=0 && sx<1024 && sy>=0 && sy<600?3:-1;
 end
 expected=slot<0?(map?32'hdadcd900:32'hf3f5f900):pattern(slot==3?(sy*1024+sx>=307200?tail_slot*307200+sy*1024+sx-307200:3*307200+sy*1024+sx):slot*307200+sy*640+sx);
 if(frame_bilinear && slot>=0 && !(full && native_hit) && !(mixed && native_hit))begin
 sw=slot==3?1024:640;sh=slot==3?600:480;
 if(slot==3)begin
 wx=((512*4096+(xx-8-320)*step)&4095)>>4;
 wy=((300*4096+(yy-56-240)*step)&4095)>>4;
 end else begin
 local_y=slot==4?yy-136-drop:yy-64;
 local_x=slot==4?xx-288:(anim?(xx<boundary?xx-304+82:xx-boundary):xx-304);
 wx=local_x%3==0?0:local_x%3==1?85:171;wy=local_y%3==0?0:local_y%3==1?85:171;
 end
 x1=sx+1<sw?sx+1:sx;y1=sy+1<sh?sy+1:sy;
 p00=sample(slot,sx,sy);p01=sample(slot,x1,sy);p10=sample(slot,sx,y1);p11=sample(slot,x1,y1);
 expected={blend(p00[31:24],p01[31:24],p10[31:24],p11[31:24],wx,wy),blend(p00[23:16],p01[23:16],p10[23:16],p11[23:16],wx,wy),blend(p00[15:8],p01[15:8],p10[15:8],p11[15:8],wx,wy),8'd0};
 end
 if(f==0 && n==200000)bilinear=1;
 if(mixed && native_hit)begin
  p00=pattern(4*307200+(y-60)*640+x-80);
  expected={expected[31:27],expected[23:18],expected[15:11],p00[31:27],p00[23:18],p00[15:11]};
 end
 if(check_expected && word!==expected)$fatal(1,"frame=%d x=%d y=%d got=%h expected=%h",f,x,y,word,expected);
 if(mask!==((map?6'b001000:6'b000001)|(anim?6'b000010:0)|(half!=0?6'b010000:0)))$fatal(1,"active slot protection changed");
 if(native_hit)native_count=native_count+1;else retained_count=retained_count+1;
 if(x==79 || x==80 || x==719 || x==720 || y==59 || y==60 || y==539 || y==540)boundary_checks=boundary_checks+1;
 n=n+1;total=total+1;
 end
end
integer consumed=0,cx,cy;reg consume_start=0;
always @(negedge clk)begin used=n-consumed;if(n-consumed<0 || n-consumed>511)$fatal(1,"DISPLAY FIFO RANGE ERROR");end
initial forever begin
 wait(consume_start);#600000;
 for(cy=0;cy<600;cy=cy+1)begin
 for(cx=0;cx<800;cx=cx+1)begin
 if(consumed>=n)$fatal(1,"DISPLAY FIFO UNDERFLOW frame=%0d x=%d y=%d",f,cx,cy);
 consumed=consumed+1;#25;
 end
 #6400;
 end
 wait(!consume_start);
end
time started;integer first_frame=3,last_frame=4;
initial begin
 $value$plusargs("FIRST_FRAME=%d",first_frame);$value$plusargs("LAST_FRAME=%d",last_frame);
 repeat(5)@(negedge clk);rst=0;wait(init);
 for(f=first_frame;f<last_frame;f=f+1)begin
 motion=0;half=0;map=1;anim=0;phase=0;full=0;bilinear=f!=0 && f!=11;frame_bilinear=bilinear;
 cx2=1024;cy2=600;mw=1024;mh=600;check_expected=f<12;
 case(f)
 0:begin tail_slot=5;step=6554;end
 1:begin tail_slot=5;step=4096;motion={3'b101,10'd144};end
 2:begin tail_slot=1;step=2048;half=104;end
 3:begin tail_slot=1;step=6554;half=210;end
 4:begin tail_slot=1;step=6554;half=104;end
 5:begin tail_slot=5;step=6554;half=180;end
 6:begin tail_slot=5;step=6554;full=1;end
 7:begin map=0;anim=1;phase=7;end
 8:begin map=0;half=210;end
 9:begin tail_slot=1;step=6554;motion={3'b111,10'd144};end
 10:begin tail_slot=5;step=6554;end
 11:begin tail_slot=1;step=2731;end
 // 新增：视野越过左/上边界、右/下边界，跨槽大图，其他宽高
 12:begin tail_slot=5;step=4096;cx2=200;cy2=1000;end
 13:begin tail_slot=5;step=4096;cx2=200;cy2=1000;bilinear=0;frame_bilinear=0;end
 14:begin tail_slot=1;step=2048;cx2=1950;cy2=1150;end
 15:begin tail_slot=1;step=2731;cx2=101;cy2=37;half=104;end
 16:begin tail_slot=5;step=3000;mw=900;mh=500;cx2=1700;cy2=950;motion={3'b111,10'd96};end
 17:begin tail_slot=5;step=4096;mw=640;mh=480;cx2=640;cy2=480;bilinear=0;frame_bilinear=0;end
 endcase
 half=210;full=f==6;mixed=!full;motion=0;anim=0;bilinear=1;frame_bilinear=1;
 native_count=0;retained_count=0;boundary_checks=0;
 n=0;consumed=0;req=1;wait(ack);repeat(8)@(negedge clk);req=0;started=$time;consume_start=1;
 wait(n==480000 && consumed==480000);consume_start=0;repeat(1000)@(negedge clk);
 if(iq!=oq)$fatal(1,"memory return accounting mismatch");
 if(native_count!=307200 || retained_count!=172800 || boundary_checks!=5584)
  $fatal(1,"overlay coverage mismatch native=%0d retained=%0d boundary=%0d",native_count,retained_count,boundary_checks);
 if($time-started>16666667)$fatal(1,"frame throughput below 60 Hz");
 $display("MIXED_VENDOR_FRAME %0d full=%0d pixels=%0d native=%0d retained=%0d boundary=%0d time_ns=%0t",f,full,n,native_count,retained_count,boundary_checks,$time-started);
 end
 if(writes<1000 || refs<100)$fatal(1,"insufficient concurrent write/refresh traffic");
 $display("DIRECT_READ_EQUIVALENCE returning_cycles=%0d direct_valid_returns=%0d cached_valid_returns=%0d",direct_checks,direct_returns,cached_returns);
 $display("FILTER_SAMPLE_EQUIVALENCE checked_cycles=%0d running_cycles=%0d samples=%0d first_pass_samples=%0d",sample_checks,filter_running_checks,filter_samples,first_pass_samples);
 $display("PASS: %0d overlay pixels with encrypted SDRAM command timing, concurrent writer/refresh and retained RGB888/bilinear border",total);$finish;
end
initial begin #600000000;$fatal(1,"lockstep timeout");end
endmodule
