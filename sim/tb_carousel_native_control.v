`timescale 1ns/1ps
module tb_carousel_native_control;
wire native_request;
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
.key_next_n(keys[0]),.key_floor_n(keys[1]),.key_room_n(keys[2]),.key_auto_occ_n(keys[3]),.nav_keys_n(nav),.switches(sw),.carousel_native_requested(native_request),.panel_active(panel),.photo_view_active(1'b0),.map_entry_ready(ready),.map_entry_pending(pending),
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
@(negedge clk);cfgwe=0;sw=0;rst=0;
repeat(2300)@(negedge clk);nav=127;repeat(100)@(negedge clk);
ck(!native_request && !map && state==0,"boot ordinary layout");
key(3);ck(state==1,"ordinary room selection");
a0=autos;flip(1);ck(native_request && state==0 && autos==a0,"SW2 changes layout and clears hidden selection");
key(3);ck(state==0,"native layout does not select hidden rooms");
flip(3);ck(!detail,"native confirm does not open hidden room");
longleft;ck(autos==a0+1,"long left retains autoplay");
n0=nexts;key(1);ck(nexts==n0+1,"native short left next picture");
key(0);ck(map && state==0,"right enters map");
key(3);key(1);ck(state==3,"map point selection");
longleft;ck(state==4,"long left enters pan");
longleft;ck(state==3,"long left exits pan");
a0=autos;flip(1);ck(!native_request && state==3 && autos==a0,"layout switch does not change map point state");
flip(2);key(1);ck(!map && state==0,"return index");
key(3);ck(state==1,"room selection restored");
$display("PASS: debounced SW2 level, hidden selection guard, autoplay and map pan via long-left, normal layout restored");
$finish;
end
initial begin #10000000;$fatal(1,"timeout");end
endmodule
