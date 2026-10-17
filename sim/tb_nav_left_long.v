`timescale 1ns/1ps
module tb_nav_left_long;
reg clk=0;always #5 clk=~clk;reg rst=1,frame=0,cfgwe=0;reg[12:0]ca=0;reg[7:0]cd=0;
reg[6:0]nav=0;reg[3:0]keys=15,sw=15;reg panel=0,ready=1;
wire[1:0]fl,cursor,level,field;wire[3:0]room;wire selecting,map,visible,detail,settings,pan,full,wave,music,pending,nextp,autop;
wire[2:0]state;wire[3:0]bright,volume;wire[29:0]occupied;wire[15:0]elapsed;wire[11:0]tx;wire[10:0]ty;
integer nexts=0,autos=0,ticks=0;always @(negedge clk)begin ticks=ticks+1;frame=ticks%20==0;if(nextp)nexts=nexts+1;if(autop)autos=autos+1;end
integer second_reference=0;
always @(posedge clk)begin
 if(rst)second_reference<=0;
 else begin
 if(dut.second_tick !== (second_reference==9999))$fatal(1,"shared second timer changed cycle alignment");
 second_reference<=second_reference==9999?0:second_reference+1;
 end
end
guide_scene_control #(.EXTERNAL_NAV(1),.RUNTIME_CONFIG(1),.DEFER_MAP_ENTRY(1),.CLK_FREQ_HZ(10000),.DEBOUNCE_MS(1),.LONG_PRESS_MS(100)) dut(
.clk(clk),.rst(rst),.frame_request(frame),.cfg_we(cfgwe),.cfg_addr(ca),.cfg_data(cd),
.key_next_n(keys[0]),.key_floor_n(keys[1]),.key_room_n(keys[2]),.key_auto_occ_n(keys[3]),.nav_keys_n(nav),.switches(sw),.panel_active(panel),.photo_view_active(1'b0),.map_entry_ready(ready),.map_entry_pending(pending),
.display_floor_idx(fl),.display_room_idx(room),.floor_idx(fl),.selected_room_idx(room),.floor_cursor(cursor),.floor_selecting(selecting),.map_mode(map),.selection_visible(visible),.control_state(state),
.room_occupied(occupied),.selected_elapsed_bcd(elapsed),.map_available(map),.map_width(11'd960),.map_height(10'd563),.map_level(level),.period_select(),.map_zoom(),.map_x(),.map_y(),.map_view(),.map_scale(),.settings_event(),.nearest_room_valid(),.nearest_room_idx(),.map_target_x2(tx),.map_target_y2(ty),
.detail_requested(detail),.photo_full_requested(full),.settings_open(settings),.settings_field(field),.brightness(bright),.volume(volume),.spectrum_enabled(wave),.music_enabled(music),.pan_mode(pan),.next_pulse(nextp),.auto_toggle_pulse(autop));
integer i,j,f,n;reg[11:0]before_x;reg[10:0]before_y;reg[7:0]cfg[0:8191];
integer selected_before,expected_x,expected_y;
function integer closest;input integer cx,cy;integer k,dx,dy,d,best;begin
 closest=0;best=2147483647;
 for(k=0;k<10;k=k+1)begin
 dx=2*(cfg[322+k*16]+256*cfg[323+k*16])-cx;
 dy=2*(cfg[324+k*16]+256*cfg[325+k*16])-cy;
 d=dx*dx+dy*dy;if(d<best)begin best=d;closest=k;end
 end
end endfunction
task settle_pan;begin repeat(1600)@(negedge clk);ck(room==closest(dut.nav_cx,dut.nav_cy),"pan selects closest actual centre");end endtask
task key;input integer k;begin @(negedge clk);nav[k]=0;repeat(30)@(negedge clk);nav[k]=1;repeat(60)@(negedge clk);end endtask
task holdkey;input integer k;begin @(negedge clk);nav[k]=0;repeat(1100)@(negedge clk);nav[k]=1;repeat(60)@(negedge clk);end endtask
task flip;input integer k;integer b;begin
 if(k==1)begin @(negedge clk);sw[k]=!sw[k];repeat(80)@(negedge clk);end
 else begin
 b=k==0?5:k==2?6:4;
 @(negedge clk);nav[b]=0;repeat(80)@(negedge clk);
 nav[b]=1;repeat(80)@(negedge clk);
 end
end endtask
task ck;input condition;input[799:0]msg;begin if(condition!==1'b1)$fatal(1,"%s state=%d room=%d floor=%d",msg,state,room,fl);end endtask

integer a0,n0,j0,context_events=0,settings_events=0;
reg[1:0] lv0,field0; reg[3:0] bright0,volume0,room0;
reg wave0,music0; reg[11:0] tx0; reg[10:0] ty0;
always @(negedge clk) begin
    if(dut.context_changed) context_events=context_events+1;
    if(dut.settings_event) settings_events=settings_events+1;
end
// 在真正接收事件的时钟边沿检查 SW2/长左的共同上下文通知，避免只验证最终状态。
always @(posedge clk) begin
    if(!rst && dut.mode_toggle_event && !dut.sw_event[0] && !dut.sw_event[2] &&
       !settings && !detail && !panel) begin
        #1; if(!dut.context_changed) $fatal(1,"mode toggle must set context_changed");
    end
end
task longleft; begin
    @(negedge clk);nav[1]=0;
    repeat(2300)@(negedge clk); // 超过两个长按阈值，仍只能触发一次。
    nav[1]=1;repeat(100)@(negedge clk);
end endtask
task unchanged; input[799:0] label; begin
    ck(autos==a0 && nexts==n0,label);
end endtask
initial begin
$readmemh("rooms10_cfg.hex",cfg);
for(i=0;i<8192;i=i+1)begin @(negedge clk);cfgwe=1;ca=i;cd=cfg[i];end
@(negedge clk);cfgwe=0;rst=0;
repeat(2300)@(negedge clk);ck(state==0 && !map && autos==0 && nexts==0,"held at startup cannot fire");
nav=127;repeat(100)@(negedge clk);
a0=autos;n0=nexts;j0=context_events;longleft;
ck(state==0 && !map && autos==a0+1 && nexts==n0 && context_events==j0+1,"PAGE long left toggles autoplay once; no release click");
key(1);ck(nexts==n0+1 && autos==a0+1,"PAGE short left remains next picture");
flip(1);ck(autos==a0+2,"SW2 index function preserved");
key(3);key(2);room0=room;a0=autos;n0=nexts;longleft;
ck(state==1 && room==room0 && autos==a0+1 && nexts==n0,"ROOM long left autoplay without selection change");
key(1);ck(nexts==n0+1,"ROOM short left remains next picture");

flip(0);ck(settings,"SET opens settings");panel=1;
repeat(4)begin
    a0=autos;n0=nexts;field0=field;bright0=bright;volume0=volume;wave0=wave;music0=music;j0=settings_events;
    longleft;
    ck(settings && field==field0 && bright==bright0 && volume==volume0 && wave==wave0 && music==music0 && settings_events==j0,"long left inert in each settings field and on release");
    unchanged("settings cannot toggle autoplay or next");key(2);
end
key(1);ck(bright==7,"short left still adjusts parameter");
flip(2);panel=0;ck(!settings && state==1,"RST closes settings");
flip(3);panel=1;ck(detail,"MID opens detail");
a0=autos;n0=nexts;longleft;ck(detail && state==1,"detail blocks long left");unchanged("detail blocks autoplay and next");
flip(2);ck(!detail,"RST closes detail");
longleft;ck(state==1 && !detail,"panel closing animation blocks long left");unchanged("panel animation blocks events");
panel=0;repeat(100)@(negedge clk);

// 地图尚未进入时仍按当前索引页解释；返回后旧的长按不能追入新状态。
ready=0;key(0);ck(pending && !map,"pending map begins");
a0=autos;n0=nexts;longleft;ck(pending && !map && autos==a0+1 && nexts==n0,"pending index retains SW2 semantics");
@(negedge clk);nav[1]=0;repeat(100)@(negedge clk);a0=autos;n0=nexts;
flip(2);repeat(2200)@(negedge clk);nav[1]=1;repeat(100)@(negedge clk);
ck(state==0 && !pending && !map,"RST cancels map and held gesture");unchanged("held gesture not transferred across context");
ready=1;key(0);ck(map && state==0,"enter map PAGE");
a0=autos;n0=nexts;longleft;ck(map && state==0,"map PAGE ignores long left including release");unchanged("map PAGE no autoplay");
key(1);ck(!map && state==0,"map PAGE short left still returns index");
key(0);key(3);ck(map && state==2,"map FLOOR");
a0=autos;n0=nexts;longleft;ck(map && state==2,"FLOOR long left cannot enter POINT on release");unchanged("FLOOR no autoplay");
key(1);ck(state==3,"FLOOR short left selects point");
repeat(1600)@(negedge clk);
lv0=level;tx0=tx;ty0=ty;a0=autos;n0=nexts;j0=context_events;longleft;
ck(state==4 && pan && level==lv0 && tx==tx0 && ty==ty0 && context_events==j0+1,"POINT long left enters PAN once without zoom/pan");unchanged("POINT mode switch has no carousel event");
longleft;ck(state==3 && !pan && level==lv0 && tx==tx0 && ty==ty0,"PAN long left returns POINT without release pan");unchanged("PAN mode switch has no carousel event");
room0=room;key(1);ck(state==3 && room==room0,"POINT short left ignored as before");
holdkey(0);repeat(1600)@(negedge clk);ck(level==1,"long right zoom preserved");
lv0=level;tx0=tx;ty0=ty;longleft;ck(state==4 && level==lv0 && tx==tx0 && ty==ty0,"long left preserves enlarged viewport");
before_x=tx;key(1);ck(tx<before_x,"PAN short left still moves viewport");
repeat(1600)@(negedge clk);tx0=tx;ty0=ty;longleft;
ck(state==3 && level==lv0 && tx==tx0 && ty==ty0,"return POINT retains pan destination");
flip(1);ck(state==4 && level==lv0,"SW2 enters PAN at current zoom");
flip(1);ck(state==3 && level==lv0,"SW2 returns POINT at current zoom");
flip(3);panel=1;a0=autos;n0=nexts;longleft;
ck(detail && state==3 && level==lv0,"map detail blocks long left");unchanged("map detail no carousel");
flip(2);longleft;ck(state==3 && !detail,"map panel closing blocks long left");panel=0;

// 同一接收拍 SW2 与长按到期相遇：SW2 的 cancel 使手势作废，只切换一次。
@(negedge clk);force dut.sw_event=4'b0010;force dut.long_key=4'b0010;
@(negedge clk);release dut.sw_event;release dut.long_key;
repeat(100)@(negedge clk);ck(state==4 && pan,"coincident mode events enter common branch once");
longleft;ck(state==3,"long left remains usable after coincident events");

// 用真实输入验证 SW2 到来时取消正在累计的长左，避免后来再次反转。
@(negedge clk);nav[1]=0;repeat(100)@(negedge clk);flip(1);
repeat(2200)@(negedge clk);nav[1]=1;repeat(100)@(negedge clk);
ck(state==4 && pan,"SW2 cancels unfinished left gesture without late reversal");
flip(2);flip(2);key(1);ck(state==0 && !map,"restore index");

// 板载 KEY2 与外接左键共享同一路手势识别。
a0=autos;n0=nexts;holdkey(1);ck(autos==a0+1 && nexts==n0,"external left still active");
a0=autos;@(negedge clk);keys[1]=0;repeat(2300)@(negedge clk);keys[1]=1;repeat(100)@(negedge clk);
ck(autos==a0+1 && nexts==n0,"board KEY2 follows same long-left rule");
$display("PASS: long-left PAGE/ROOM autoplay, symmetric POINT/PAN, SW2 coexistence, context cancellation, release exclusion, all settings fields, detail/animation blocking, legacy short keys");
$finish;
end
initial begin #10000000;$fatal(1,"timeout");end
endmodule
