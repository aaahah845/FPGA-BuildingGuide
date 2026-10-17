`timescale 1ns/1ps
module tb_dynamic_fonts;
reg video_clk=0;
reg sd_clk=0;
always #12.5 video_clk=~video_clk;
initial begin #3; forever #10 sd_clk=~sd_clk; end
reg [6:0] large_glyph=0;
reg [4:0] large_row=0;
wire [23:0] large_pixels;
reg [7:0] notes_glyph=0;
reg [3:0] notes_row=0;
wire [15:0] notes_pixels;
reg write_en=0;
reg [12:0] write_addr=0;
reg [17:0] write_data=0;
guide_large_font font24_dut(
 .clk(video_clk),.glyph(large_glyph),.row(large_row),.pixels(large_pixels),
 .write_clk(sd_clk),.write_en(write_en && !write_addr[12]),
 .write_addr(write_addr[11:0]),.write_data(write_data));
room_notes_font notes(
 .clk(video_clk),.glyph(notes_glyph),.row(notes_row),.pixels(notes_pixels),
 .write_clk(sd_clk),.write_en(write_en && write_addr[12] && write_addr<5632),
 .write_addr(write_addr[10:0]),.write_data(write_data[15:0]));

// Exercise the actual compositor routing, including its upper-address guard.
guide_scene_compositor #(.RUNTIME_CONFIG(1)) compositor(
 .I_clk(video_clk),.I_rst(1'b1),.I_scene_motion(13'd0),
 .cfg_we(1'b0),.cfg_addr(13'd0),.cfg_data(8'd0),
 .font_write_clk(sd_clk),.font_write_en(write_en),
 .font_write_addr(write_addr),.font_write_data(write_data),
 .I_loading(1'b0),.I_load_error(1'b0),.I_map_loading(1'b0),
 .I_rgb(24'd0),.I_hs(1'b0),.I_vs(1'b0),.I_de(1'b0),
 .I_floor_idx(2'd0),.I_selection_visible(1'b0),.I_floor_selecting(1'b0),
 .I_floor_cursor(2'd0),.I_requested_floor(2'd0),.I_selected_room_idx(4'd0),
 .I_room_occupied(30'd0),.I_elapsed_bcd(16'd0),.I_auto_play_en(1'b0),
 .I_detail_requested(1'b0),.I_view_settled(1'b0),.I_carousel_progress(13'd0),
 .I_period_select(2'd0),.I_panel_height(8'd0),.I_photo_full(1'b0),.I_photo_view_alpha(5'd16),
 .I_map_view(37'd0),.I_map_scale(14'd0),.I_map_width(11'd0),.I_map_height(10'd0),
 .I_map_mode(1'b0),.I_map_zoom(1'b0),.I_map_pan(1'b0),.I_map_x(9'd0),.I_map_y(8'd0),
 .O_panel_active(),.O_rgb(),.O_hs(),.O_vs(),.O_de());

reg [23:0] initial24[0:4095],loaded24[0:4095];
reg [15:0] initial16[0:4095],loaded16[0:4095];
reg [17:0] load24[0:4095];
reg [15:0] load16[0:1535];
reg [23:0] previous24;
reg [15:0] previous16;
integer i,j,loaded;

task scan_rows;
 input after_load;
 reg [23:0] expected24;
 reg [15:0] expected16;
 begin
  for(j=0;j<4096;j=j+1) begin
   @(negedge video_clk);
   previous24=large_pixels; previous16=notes_pixels;
   large_glyph=j/32; large_row=j%32;
   notes_glyph=j/16; notes_row=j%16;
   expected24=after_load?loaded24[j]:initial24[j];
   expected16=after_load?loaded16[j]:initial16[j];
   #1;
   if(large_pixels!==previous24 || notes_pixels!==previous16)
    $fatal(1,"Read changed before active edge at row index %0d",j);
   @(posedge video_clk); #1;
   if(large_pixels!==expected24)
    $fatal(1,"24px stage=%0d glyph=%0d row=%0d got=%h expected=%h",after_load,large_glyph,large_row,large_pixels,expected24);
   if(notes_pixels!==expected16)
    $fatal(1,"16px stage=%0d glyph=%0d row=%0d got=%h expected=%h",after_load,notes_glyph,notes_row,notes_pixels,expected16);
  end
 end
endtask

task write_word;
 input [12:0] address;
 input [17:0] data;
 input enabled;
 begin
  @(negedge sd_clk); write_addr=address;write_data=data;write_en=enabled;
  @(posedge sd_clk); #1;
 end
endtask

task check_routing;
 begin
  for(i=0;i<2048;i=i+1) begin
   if(compositor.large_font.even_words[i]!==load24[i] || font24_dut.even_words[i]!==load24[i])
    $fatal(1,"Even RAM routing at %0d",i);
   if(compositor.large_font.odd_words[i]!==load24[2048+i] || font24_dut.odd_words[i]!==load24[2048+i])
    $fatal(1,"Odd RAM routing at %0d",i);
  end
  for(i=0;i<512;i=i+1) begin
   if(compositor.notes_font.bank0[i]!==load16[i] || notes.bank0[i]!==load16[i]) $fatal(1,"Notes bank0 %0d",i);
   if(compositor.notes_font.bank1[i]!==load16[512+i] || notes.bank1[i]!==load16[512+i]) $fatal(1,"Notes bank1 %0d",i);
   if(compositor.notes_font.bank2[i]!==load16[1024+i] || notes.bank2[i]!==load16[1024+i]) $fatal(1,"Notes bank2 %0d",i);
  end
 end
endtask

initial begin
 $readmemh("initial24.hex",initial24);$readmemh("initial16.hex",initial16);
 $readmemh("loaded24.hex",loaded24);$readmemh("loaded16.hex",loaded16);
 $readmemh("load24.hex",load24);$readmemh("load16.hex",load16);
 repeat(3) @(posedge video_clk);
 scan_rows(0);
 $display("PASS: initial fonts, 128x32 large and 256x16 notes rows, one-cycle synchronous read");
 // Park read requests on the preserved blank while the unrelated write clock runs.
 @(negedge video_clk);large_glyph=0;large_row=0;notes_glyph=0;notes_row=0;
 for(i=0;i<4096;i=i+1) write_word(i,load24[i],1'b1);
 for(i=0;i<1536;i=i+1) write_word(4096+i,{2'b11,load16[i]},1'b1);
 @(negedge sd_clk);write_en=0;
 check_routing;
 scan_rows(1);
 $display("PASS: asynchronous startup writes, every bank and packed row phase, fixed UI glyphs preserved");
 // These addresses would alias a font bank if the compositor upper bound were absent.
 for(i=5632;i<8192;i=i+1) write_word(i,18'h3ffff,1'b1);
 // A disabled valid-address write must also leave both RAMs unchanged.
 write_word(0,18'h3ffff,1'b0);write_word(2048,18'h3ffff,1'b0);
 write_word(4096,18'h3ffff,1'b0);write_word(5631,18'h3ffff,1'b0);
 @(negedge sd_clk);write_en=0;
 check_routing;
 scan_rows(1);
 $display("PASS: compositor write routing, notes upper-address protection and write-enable hold");
 $display("PASS: dynamic font suite");
 $finish;
end
initial begin #2000000;$fatal(1,"Timeout");end
endmodule
