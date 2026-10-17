`timescale 1ns/1ps
module tb_runtime_title;
reg clk=0,rst=1,cfg_we=0,hs=0,vs=0,de=0,map_mode=0;
reg [12:0] cfg_addr=0;
reg [7:0] cfg_data=0;
wire [23:0] rgb,ref_rgb;
wire out_hs,out_vs,out_de,ref_hs,ref_vs,ref_de;
always #5 clk=~clk;
`define PORTS \
 .I_clk(clk),.I_rst(rst),.I_scene_motion(13'd0), \
 .cfg_we(cfg_we),.cfg_addr(cfg_addr),.cfg_data(cfg_data), \
 .I_loading(1'b0),.I_load_error(1'b0),.I_map_loading(1'b0), \
 .I_rgb(24'h426888),.I_hs(hs),.I_vs(vs),.I_de(de), \
 .I_floor_idx(2'd0),.I_selection_visible(1'b0),.I_floor_selecting(1'b0), \
 .I_floor_cursor(2'd0),.I_requested_floor(2'd0),.I_selected_room_idx(4'd0), \
 .I_room_occupied(30'd0),.I_elapsed_bcd(16'd0),.I_auto_play_en(1'b0), \
 .I_detail_requested(1'b0),.I_view_settled(1'b1),.I_carousel_progress(13'd0), \
 .I_period_select(2'd0),.I_panel_height(8'd0),.I_photo_full(1'b0), \
 .I_map_view(37'd0),.I_map_scale(14'd4096),.I_map_width(11'd640), \
 .I_map_height(10'd480),.I_map_mode(map_mode),.I_map_zoom(1'b0), \
 .I_map_pan(1'b0),.I_map_x(9'd0),.I_map_y(8'd0)
guide_scene_compositor #(.RUNTIME_CONFIG(1)) dut(
 `PORTS,.I_photo_view_alpha(5'd16),.O_rgb(rgb),.O_hs(out_hs),.O_vs(out_vs),.O_de(out_de),.O_panel_active());
guide_scene_compositor_baseline #(.RUNTIME_CONFIG(1)) reference_dut(
 `PORTS,.O_rgb(ref_rgb),.O_hs(ref_hs),.O_vs(ref_vs),.O_de(ref_de),.O_panel_active());
`undef PORTS

reg [23:0] font_rows[0:3071];
reg [6:0] title_ids[0:7];
reg custom_enabled=0;
reg check_enable=0;
integer x_pipe[0:5],y_pipe[0:5];
reg de_pipe[0:5],hs_pipe[0:5],vs_pipe[0:5];
integer i,j,x,y,n,glyph_index,glyph_col,glyph_row;
integer checked_pixels=0,title_pixels=0,outside_pixels=0,frames=0;
reg [23:0] expected_rgb;
reg [23:0] glyph_bits;

function integer default_glyph;
input integer c;
begin
 case(c)
 0:default_glyph=56; 1:default_glyph=57; 2:default_glyph=29;
 3:default_glyph=30; 4:default_glyph=58; 5:default_glyph=59;
 default:default_glyph=0;
 endcase
end
endfunction

// Six clock stages are an existing interface contract. Coordinates/DE/HS/VS
// are delayed independently of the DUT's text request and name RAM control.
always @(posedge clk) begin
 if(rst) begin
  for(j=0;j<6;j=j+1) begin
   x_pipe[j]=0;y_pipe[j]=0;de_pipe[j]=0;hs_pipe[j]=0;vs_pipe[j]=0;
  end
 end else begin
  for(j=5;j>0;j=j-1) begin
   x_pipe[j]=x_pipe[j-1];y_pipe[j]=y_pipe[j-1];
   de_pipe[j]=de_pipe[j-1];hs_pipe[j]=hs_pipe[j-1];vs_pipe[j]=vs_pipe[j-1];
  end
  x_pipe[0]=dut.scan_x;y_pipe[0]=dut.scan_y;
  de_pipe[0]=de;hs_pipe[0]=hs;vs_pipe[0]=vs;
  #1;
  if(check_enable) begin
   if({out_de,out_hs,out_vs}!=={de_pipe[5],hs_pipe[5],vs_pipe[5]})
    $fatal(1,"sync latency mismatch at (%0d,%0d)",x_pipe[5],y_pipe[5]);
   if({out_de,out_hs,out_vs}!=={ref_de,ref_hs,ref_vs})
    $fatal(1,"baseline sync mismatch");
   if(out_de) begin
    checked_pixels=checked_pixels+1;
    if((^rgb)===1'bx) $fatal(1,"unknown RGB at (%0d,%0d)",x_pipe[5],y_pipe[5]);
    if(x_pipe[5]>=16 && x_pipe[5]<208 && y_pipe[5]>=12 && y_pipe[5]<36) begin
     title_pixels=title_pixels+1;
     glyph_col=(x_pipe[5]-16)/24;
     glyph_row=y_pipe[5]-12;
     glyph_index=custom_enabled?title_ids[glyph_col]:default_glyph(glyph_col);
     glyph_bits=font_rows[glyph_index*24+glyph_row];
     expected_rgb=glyph_bits[23-((x_pipe[5]-16)%24)]?24'h152138:24'hf9f8f6;
     if(rgb!==expected_rgb)
      $fatal(1,"title RGB mismatch frame=%0d xy=(%0d,%0d) glyph=%0d expected=%h got=%h",frames,x_pipe[5],y_pipe[5],glyph_index,expected_rgb,rgb);
    end else begin
     outside_pixels=outside_pixels+1;
     if(rgb!==ref_rgb)
      $fatal(1,"non-title RGB changed frame=%0d xy=(%0d,%0d) expected=%h got=%h",frames,x_pipe[5],y_pipe[5],ref_rgb,rgb);
    end
   end
  end
 end
end

task write_byte;
input integer address;
input integer value;
begin
 @(negedge clk);cfg_we=1;cfg_addr=address;cfg_data=value;
 @(negedge clk);cfg_we=0;
end
endtask

task check_names;
integer a;
begin
 for(a=0;a<264;a=a+1)
  if(dut.runtime_names[a]!==((a%10)+1))
   $fatal(1,"name RAM overwritten at %0d",a);
end
endtask

task frame;
input integer page;
integer line,column,line_limit;
begin
 map_mode=page;
 @(negedge clk);vs=1;de=0;
 repeat(4) @(negedge clk);
 vs=0;
 repeat(8) @(negedge clk);
 check_enable=1;
 // The first pass includes a room card; subsequent passes scan all header
 // pixels (including the central floor name), without repeating the body.
 line_limit=(frames==0)?130:40;
 for(line=0;line<line_limit;line=line+1) begin
  hs=1;de=0;
  repeat(4) @(negedge clk);
  hs=0;
  for(column=0;column<800;column=column+1) begin
   de=1;
   @(negedge clk);
  end
  de=0;
  repeat(12) @(negedge clk);
 end
 repeat(12) @(negedge clk);
 check_enable=0;
 frames=frames+1;
 check_names;
end
endtask

initial begin
 $readmemh("font24_expected.hex",font_rows);
 repeat(4) @(negedge clk);
 rst=0;
 // Populate the same canonical configuration stream used by both versions.
 // All display memories are initialized so unknowns cannot mask a regression.
 for(i=0;i<8192;i=i+1) write_byte(i,0);
 write_byte(8,3);
 write_byte(256,10);write_byte(272,10);write_byte(288,10);
 for(i=0;i<264;i=i+1) write_byte(1024+i,(i%10)+1);
 frame(0);frame(1);
 $display("PASS: unextended/zero-marker config matches original title in both pages");

 // Writing title data alone must not enable an unmarked extension.
 for(i=0;i<8;i=i+1) write_byte(1288+i,1+i);
 frame(0);
 $display("PASS: title bytes without valid marker retain default");

 for(n=1;n<=8;n=n+1) begin
  write_byte(0,8'h53);custom_enabled=0;
  for(i=0;i<8;i=i+1) begin
   title_ids[i]=(i<n)?(1+i):0;
   write_byte(1288+i,title_ids[i]);
  end
  write_byte(1296,8'h54);custom_enabled=1;
  frame(n%2);
  $display("PASS: custom title length %0d including space padding and pixel pipeline",n);
 end

 // Explicit disable and then a subsequent legacy copy must both fall back.
 write_byte(1296,0);custom_enabled=0;
 frame(0);
 write_byte(1296,8'h54);custom_enabled=1;
 frame(1);
 write_byte(0,8'h53);custom_enabled=0;
 frame(0);
 $display("PASS: disabled marker and fresh legacy config restore default");

 // Invalid markers must never enable the extension at compositor boundary.
 write_byte(1296,8'h53);
 frame(1);
 $display("PASS: invalid marker does not enable title");

 // Reset clears the mode without relying on preserved RAM contents.
 write_byte(1296,8'h54);custom_enabled=1;
 @(negedge clk);rst=1;
 repeat(3) @(negedge clk);
 rst=0;custom_enabled=0;
 frame(0);
 $display("PASS: reset restores fixed title");
 $display("PASS: runtime title suite frames=%0d pixels=%0d title_pixels=%0d unchanged_non_title_pixels=%0d",frames,checked_pixels,title_pixels,outside_pixels);
 $finish;
end
initial begin #50000000; $fatal(1,"timeout"); end
endmodule
