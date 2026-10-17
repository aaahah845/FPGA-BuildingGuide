`timescale 1ns/1ps
module tb_nav_control;
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
initial begin
$readmemh("rooms10_cfg.hex",cfg);
for(i=0;i<8192;i=i+1)begin @(negedge clk);cfgwe=1;ca=i;cd=cfg[i];end
@(negedge clk);cfgwe=0;rst=0;repeat(100)@(negedge clk);
ck(!map && state==0 && room==0 && !visible && !detail && !settings,"contacts held at power-up must not fire");
nav=127;repeat(100)@(negedge clk);
ck(!map && state==0 && !visible && !settings,"release after boot must not fire");
// Contact chatter below the debounce interval must not open settings.
repeat(6)begin nav[5]=0;repeat(3)@(negedge clk);nav[5]=1;repeat(3)@(negedge clk);end
repeat(80)@(negedge clk);ck(!settings,"SET chatter ignored");
nav[5]=0;repeat(2000)@(negedge clk);ck(settings,"SET hold fires once");
nav[5]=1;repeat(80)@(negedge clk);ck(settings,"SET release does not toggle");
flip(2);ck(!settings,"RST closes settings");
flip(3);ck(!detail,"unselected confirmation");holdkey(2);ck(occupied==0 && room==0,"unselected long down ignored");
key(1);ck(nexts==1,"left manual slide");flip(1);ck(autos==1,"SW2 carousel");
key(3);ck(visible && state==1 && room==0,"up selects first room");
for(f=0;f<3;f=f+1)begin for(j=1;j<=10;j=j+1)begin key(2);ck(room==j%10 && fl==f,"ten-room wrap");end holdkey(3);ck(room==0 && fl==(f+1)%3,"long up floor wrap without short up");end
key(3);ck(room==0,"room up cannot select previous");
key(2);key(3);ck(room==1,"room up ignored away from first");holdkey(2);ck(room==1 && occupied==2,"long K3 toggles selected room without down click");
repeat(10500)@(negedge clk);ck(elapsed!=0,"occupied timer runs");holdkey(2);ck(occupied==0 && elapsed==0 && room==1,"occupancy clear resets timer");
flip(3);ck(detail,"SW4 opens room detail");panel=1;holdkey(2);ck(detail && occupied==2,"long K3 also works inside open detail");
key(0);ck(!full && detail && room==1,"fullscreen removed");flip(2);panel=0;ck(!detail && visible && room==1,"return detail restores room cursor");
flip(0);ck(settings,"SW1 panel");
ck(!dut.bilinear_enabled,"nearest default");flip(3);ck(dut.bilinear_enabled && !detail && state==1,"settings SW4 enables bilinear only");flip(3);ck(!dut.bilinear_enabled,"settings SW4 restores nearest on opposite edge");key(1);ck(bright==7 && room==1,"brightness left");key(2);key(1);ck(field==1 && volume==7,"volume");key(2);key(0);ck(field==2 && !wave,"wave toggle");key(2);key(0);ck(field==3 && music,"music toggle");holdkey(2);ck(occupied==2 && field==0,"settings long down does not mark room");flip(2);ck(!settings && state==1,"return closes panel");flip(0);ck(settings,"SW1 opposite edge reopens panel");flip(0);ck(!settings,"SW1 closes panel");
ready=0;key(0);ck(!map && pending && room==1,"defer map until resident");key(2);ck(room==2 && pending,"index responsive during pending map");holdkey(3);ck(fl==1 && room==0 && pending,"pending map follows floor");ready=1;repeat(150)@(negedge clk);ck(map && state==3 && room==0,"index-to-map corresponding point");
key(0);ck(room==1,"point right");flip(2);ck(state==0 && !visible && room==0,"return page clears selection only");
key(3);ck(selecting && cursor==fl,"floor entry preselects current");key(2);holdkey(2);ck(cursor==fl,"floor down ignored");key(3);ck(cursor==2,"up next floor");flip(3);ck(selecting && fl==2 && cursor==2,"confirm retains floor selector");key(3);ck(cursor==0,"floor cursor wrap");flip(3);ck(fl==0 && selecting,"confirm floor zero");key(1);ck(state==3 && room==0,"left enters point one");
repeat(9)key(0);ck(room==9,"point ten");key(0);ck(room==0,"point wrap");key(1);ck(room==0,"point left cannot select previous");repeat(9)key(0);ck(room==9,"forward point ten");
// SW2 changes the arrow-key context only, at every zoom level and on both edges.
repeat(3)begin flip(1);ck(state==4 && pan && level==0,"SW2 enters pan without zoom");flip(1);ck(state==3 && !pan && level==0,"SW2 leaves pan without zoom");end
selected_before=room;holdkey(0);repeat(150)@(negedge clk);ck(level==1 && room==selected_before && state==3,"point-mode long K1 zoom has no next-point click");
flip(1);ck(state==4 && pan && level==1,"SW2 preserves 1.5x");settle_pan;
before_x=tx;key(1);ck(tx<before_x,"pan left");settle_pan;
before_y=ty;key(3);ck(ty<before_y,"pan up");settle_pan;
before_x=tx;key(0);ck(tx>before_x,"pan right");settle_pan;
before_y=ty;key(2);ck(ty>before_y,"pan down");settle_pan;
holdkey(0);repeat(150)@(negedge clk);ck(level==2,"pan-mode long K1 zoom");settle_pan;
n=autos;holdkey(2);ck(occupied==2 && autos==n,"pan long down never changes occupancy or autoplay");settle_pan;
selected_before=room;before_x=tx;before_y=ty;flip(1);ck(state==3 && level==2 && room==selected_before && tx==before_x && ty==before_y,"SW2 returns to point selection without resetting viewport");
key(0);ck(room==(selected_before+1)%10 && level==2,"zoomed point next");
expected_x=2*(cfg[322+room*16]+256*cfg[323+room*16]);if(expected_x<480)expected_x=480;if(expected_x>1440)expected_x=1440;
expected_y=2*(cfg[324+room*16]+256*cfg[325+room*16]);if(expected_y<360)expected_y=360;if(expected_y>766)expected_y=766;
repeat(1600)@(negedge clk);ck(tx==expected_x && ty==expected_y && dut.nav_cx==tx && dut.nav_cy==ty,"zoomed point selection moves viewport to clamped point");
ck(room==(selected_before+1)%10,"point selection remains explicit during focus");selected_before=room;
flip(3);ck(detail,"point detail");flip(2);ck(!detail && state==3 && room==selected_before,"point detail return");flip(1);flip(2);ck(state==3 && !pan && level==2,"return leaves pan and preserves zoom");flip(2);ck(state==0 && room==0 && !visible,"return point to page");key(1);ck(!map && state==0,"map page left returns index");
// A held key cannot acquire the new context after a switch event.
key(3);@(negedge clk);nav[2]=0;repeat(100)@(negedge clk);flip(2);repeat(1100)@(negedge clk);nav[2]=1;repeat(60)@(negedge clk);ck(state==0 && room==0 && occupied==2,"held key suppressed across return");
$display("PASS: external NAV ports: debounce, startup held/release suppression, one command per press, and full control regression; 3x10 selection, settings SW4 filter, switch/gesture boundaries, SW2 mode-only at all levels, long K1 zoom, closest-point pan selection, zoom-preserving return and viewport-following next point");$finish;
end
initial begin #10000000;$fatal(1,"timeout");end
endmodule
