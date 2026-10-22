`timescale 1ns/1ps
module tb_photo_compositor;
reg clk=0,rst=1,hs=0,vs=0,de=0,full=0,map_page=0;
reg [4:0] alpha=0;
reg [7:0] test_panel_height=210;reg test_detail=1;
reg [15:0] overlay565=0;
reg [15:0] op[0:5];
reg [23:0] source_rgb=0,underlying_rgb=0;
reg cfg_we=0,font_we=0;
reg [12:0] cfg_addr=0,font_addr=0;
reg [7:0] cfg_data=0;
reg [17:0] font_data=0;
reg [7:0] config_bytes[0:8191];
reg [17:0] font_words[0:5631];
integer input_x=0,input_y=0;
always #5 clk=~clk;
wire [23:0] rgb,reference_rgb;
wire oh,ov,od,rh,rv,rd;
`define PORTS \
 .I_clk(clk),.I_rst(rst),.I_scene_motion(13'd0), \
 .cfg_we(cfg_we),.cfg_addr(cfg_addr),.cfg_data(cfg_data), \
 .font_write_clk(clk),.font_write_en(font_we),.font_write_addr(font_addr),.font_write_data(font_data), \
 .I_loading(1'b0),.I_load_error(1'b0),.I_map_loading(1'b0), \
 .I_hs(hs),.I_vs(vs),.I_de(de), \
 .I_floor_idx(2'd0),.I_selection_visible(1'b1),.I_floor_selecting(1'b0), \
 .I_floor_cursor(2'd0),.I_requested_floor(2'd0),.I_selected_room_idx(4'd0), \
 .I_room_occupied(30'd0),.I_elapsed_bcd(16'd0),.I_auto_play_en(1'b0), \
 .I_detail_requested(test_detail),.I_view_settled(1'b1),.I_carousel_progress(13'd0), \
 .I_period_select(2'd0),.I_panel_height(test_panel_height), \
 .I_map_view(37'd0),.I_map_scale(14'd4096),.I_map_width(11'd640), \
 .I_map_height(10'd480),.I_map_mode(map_page),.I_map_zoom(1'b0), \
 .I_map_pan(1'b0),.I_map_x(9'd0),.I_map_y(8'd0)
guide_scene_compositor #(.RUNTIME_CONFIG(1)) dut(
 `PORTS,.I_carousel_native(1'b0),.I_layout_alpha(5'd16),.I_rgb(source_rgb),.I_photo_full(full),.I_photo_view_alpha(alpha),.I_photo_rgb565(overlay565),.O_rgb(rgb),.O_hs(oh),.O_vs(ov),.O_de(od),.O_panel_active());
guide_scene_compositor_baseline #(.RUNTIME_CONFIG(1)) baseline(
 `PORTS,.I_rgb(underlying_rgb),.I_photo_full(1'b0),.O_rgb(reference_rgb),.O_hs(rh),.O_vs(rv),.O_de(rd),.O_panel_active());
`undef PORTS

integer xp[0:5],yp[0:5],j,checks=0,frames=0,expected_checks=0,outside_checks=0,inside_checks=0;
reg [23:0] rp[0:5];
reg [2:0] sp[0:5];
reg checking=0;
reg [23:0] expected;
function [15:0] pack565;
 input [23:0] p;
 begin pack565={p[23:19],p[15:10],p[7:3]}; end
endfunction
function [23:0] expand565;
 input [15:0] p;
 begin expand565={p[15:11],p[15:13],p[10:5],p[10:9],p[4:0],p[4:2]}; end
endfunction
function [23:0] crossfade;
 input [23:0] a,b;
 input [4:0] k;
 integer r,g,bl;
 begin
  r=(a[23:16]*(16-k)+b[23:16]*k)/16;
  g=(a[15:8]*(16-k)+b[15:8]*k)/16;
  bl=(a[7:0]*(16-k)+b[7:0]*k)/16;
  crossfade={r[7:0],g[7:0],bl[7:0]};
 end
endfunction
function [23:0] darken;
 input [23:0] c;
 input [4:0] a;
 integer red,green,blue;
 begin
  red=c[23:16]*a/16;green=c[15:8]*a/16;blue=c[7:0]*a/16;
  darken={red[7:0],green[7:0],blue[7:0]};
 end
endfunction
always @(posedge clk) begin
 if(rst) begin
  for(j=0;j<6;j=j+1) begin xp[j]=0;yp[j]=0;rp[j]=0;sp[j]=0;end
 end else begin
  for(j=5;j>0;j=j-1) begin
   xp[j]=xp[j-1];yp[j]=yp[j-1];rp[j]=rp[j-1];sp[j]=sp[j-1];op[j]=op[j-1];
  end
  xp[0]=input_x;yp[0]=input_y;rp[0]=source_rgb;sp[0]={de,hs,vs};op[0]=overlay565;
  #1;
  if(checking) begin
   if({od,oh,ov}!==sp[5]) $fatal(1,"six-cycle timing mismatch");
   if({od,oh,ov}!=={rd,rh,rv}) $fatal(1,"baseline timing mismatch");
   if(od) begin
    checks=checks+1;
    if(xp[5]>=80 && xp[5]<720 && yp[5]>=60 && yp[5]<540) begin
     inside_checks=inside_checks+1;
     expected=full?rp[5]:(alpha==0?reference_rgb:crossfade(reference_rgb,expand565(op[5]),alpha));
    end else begin
     outside_checks=outside_checks+1;
     expected=reference_rgb;
    end
    if(rgb!==expected) $fatal(1,"overlay full=%0d alpha=%0d map=%0d xy=%0d,%0d expected=%h got=%h base=%h overlay=%h",full,alpha,map_page,xp[5],yp[5],expected,rgb,reference_rgb,expand565(op[5]));
   end
  end
 end
end
task frame;
 input f;
 input [4:0] a;
 input page;
 input complete;
 integer x,y;
 reg in_photo;
 reg [23:0] base_pattern,photo_pattern;
 begin
  @(negedge clk);checking=0;full=f;alpha=a;map_page=page;vs=1;de=0;
  repeat(8) @(negedge clk);
  vs=0;
  repeat(12) @(negedge clk);
  // Complete rasters check natural scan counters. Other cases inject
  // selected rows to cover all layout boundaries without repeating a frame.
  if(!complete) begin
   force dut.scan_y=input_y;
   force baseline.scan_y=input_y;
  end
  checking=1;
  for(y=0;y<600;y=y+1) begin
   if(complete || y==0 || y==12 || y==35 || y==59 || y==60 || y==61 ||
      y==68 || y==74 || y==88 || y==90 || y==104 || y==112 || y==182 || y==252 || y==322 || y==392 || y==462 || y==406 || y==478 || y==502 || y==135 || y==136 || y==240 || y==495 || y==496 || y==539 || y==540 ||
      y==548 || y==563 || y==568 || y==574 || y==596 || y==599) begin
   expected_checks=expected_checks+800;
   for(x=0;x<800;x=x+1) begin
    @(negedge clk);de=1;hs=0;input_x=x;input_y=y;
    in_photo=x>=80 && x<720 && y>=60 && y<540;
    base_pattern={x[7:0],y[7:0],(x[7:0]^y[7:0])};
    photo_pattern={~x[7:0],~y[7:0],(x[7:0]+y[7:0])};
    // Exercise the actual top-level packet protocol: I_rgb is word[31:8],
    // so only the inner mixed rectangle carries {backdrop565,photo565[15:8]}.
    // The independent baseline receives decoded backdrop RGB888 instead.
    overlay565={~x[4:0],y[5:0],x[4:0]^y[4:0]};
    underlying_rgb=(a!=0 && a!=16 && in_photo)?expand565(pack565(base_pattern)):base_pattern;
    source_rgb=(f && in_photo)?photo_pattern:
        ((a!=0 && a!=16 && in_photo)?{pack565(base_pattern),overlay565[15:8]}:base_pattern);
   end
   @(negedge clk);de=0;hs=1;
   repeat(12) @(negedge clk);
   hs=0;
   repeat(2) @(negedge clk);
   end
  end
  repeat(12) @(negedge clk);
  checking=0;
  release dut.scan_y;
  release baseline.scan_y;
  frames=frames+1;
  $display("FRAME_PASS full=%0d alpha=%0d map=%0d complete=%0d cumulative_pixels=%0d",f,a,page,complete,checks);
 end
endtask
integer load_i;
initial begin
 $readmemh("config.hex",config_bytes);
 $readmemh("fonts.hex",font_words);
 repeat(5) @(negedge clk);rst=0;
 for(load_i=0;load_i<8192;load_i=load_i+1) begin
  @(negedge clk);cfg_we=1;cfg_addr=load_i;cfg_data=config_bytes[load_i];
 end
 @(negedge clk);cfg_we=0;
 for(load_i=0;load_i<5632;load_i=load_i+1) begin
  @(negedge clk);font_we=1;font_addr=load_i;font_data=font_words[load_i];
 end
 @(negedge clk);font_we=0;
 // Full-width room, floor and title text addresses, with the panel closed.
 test_panel_height=0;test_detail=0;
 frame(0,0,0,0);frame(0,0,1,0);
 test_panel_height=210;test_detail=1;
 // Opening, stable view, then reverse/close, on both detail-page backdrops.
 frame(0,0,0,0);
 frame(0,1,0,0);
 frame(0,8,0,0);
 frame(0,15,0,0);
 frame(1,16,0,0);
 frame(0,15,0,0);
 frame(0,8,0,0);
 frame(0,1,0,0);
 frame(0,0,0,0);
 frame(0,0,1,0);
 frame(0,1,1,0);
 frame(0,8,1,0);
 frame(0,15,1,0);
 frame(1,16,1,0);
 frame(0,15,1,0);
 frame(0,8,1,0);
 frame(0,1,1,0);
 frame(0,0,1,0);
 if(checks!=expected_checks) $fatal(1,"pixel count %0d expected %0d",checks,expected_checks);
 $display("PASS: %0d cases, %0d pixels (%0d inside / %0d outside); direct RGB crossfade alpha=0/1/8/15/16, six-cycle timing, index/map outside detail unchanged, open/return",frames,checks,inside_checks,outside_checks);
 $finish;
end
endmodule
