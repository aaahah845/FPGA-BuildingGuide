`timescale 1ns/1ps
// Independent full-frame scoreboard. Memory returns preserve ordering but contain
// variable latency and valid gaps; no reference copy of the reader is used.
module tb_carousel_native_reader;
reg native_mode=0,slide_anim=0; reg [4:0] slide_phase=0;
reg expected_native; integer shift,left,right,top,bottom;
reg clk=0; always #5 clk=~clk;
reg rst=1,req=0,full=0,map_mode=0,bilinear=0;
reg blend=0,expected_blend=0;
reg [31:0] overlay_expected;
reg [2:0] photo_slot=4;
reg [7:0] tag=0;
wire ack,clear,re,we,fault,busy,applied_pulse,applied_valid,applied_full;
wire [20:0] addr;
wire [31:0] word;
wire [7:0] applied_tag;
wire [5:0] applied_mask;
wire [2:0] applied_slot;
reg [8:0] used=0;
reg rv=0;
reg [31:0] return_word=0;
integer frame=-1,n=0,consumed=0,total=0,cycle=0;
integer iq=0,oq=0,read_count=0,return_count=0,gaps=0,bursts=0;
integer burst_words=0,previous_address=0,max_used=0,apply_count=0;
integer x,y,sx,sy,slot,expected_address,pad_count=0,photo_count=0;
integer native_count=0,retained_count=0,boundary_checks=0;
reg previous_re=0,expected_full=0,expected_map=0,active=0;
reg expected_bilinear=0,native_hit=0;
reg [31:0] p00,p01,p10,p11;
integer local_x,local_y,fx,fy,sx1,sy1;
reg [2:0] expected_photo=4;
reg [5:0] expected_mask;
reg [31:0] expected;
reg [20:0] queue[0:4095];
integer due[0:4095];
reg consume_start=0;
integer cx,cy,direct_checks=0,direct_return_checks=0;
integer sample_checks=0,filter_running_checks=0,filter_samples=0,first_pass_samples=0;
time started;

function [15:0] rgb565;
 input [31:0] p;
 begin rgb565={p[31:27],p[23:18],p[15:11]}; end
endfunction
function [31:0] pattern;
    input [20:0] address;
    begin pattern={3'b101,address,8'd0}; end
endfunction
function [7:0] channel_blend;
 input [7:0] a,b,c,d;
 input integer wx,wy;
 integer top,bottom;
 begin
  top=(a*(256-wx)+b*wx+8)>>4;
  bottom=(c*(256-wx)+d*wx+8)>>4;
  channel_blend=(top*(256-wy)+bottom*wy+2048)>>12;
 end
endfunction

scene_frame_reader #(.DYNAMIC_GEOMETRY(1),.SCATTERED_SLOTS(1),.BILINEAR_SUPPORT(1),.CROSSFADE_SUPPORT(1)) dut(
 .carousel_native(native_mode),.bilinear_enabled(bilinear),.scene_motion(13'd0),
 .map_view({14'd4096,12'd640,11'd480}),
 .slot_tails(18'd0),.slot_widths({6{11'd640}}),
 .slot_strides({6{11'd640}}),.slot_heights({6{10'd480}}),
 .clk(clk),.rst(rst),.init_done(1'b1),.refresh_busy(1'b0),
 .writer_busy(1'b0),.core_busy(1'b0),.read_req(req),.fifo_used(used),
 .rd_valid(rv),.rd_data(return_word),.slide_anim(slide_anim),.slide_phase(slide_phase),
 .slide_old(3'd2),.scene_ready(1'b1),.slide_slot(3'd1),.bg_slot(3'd0),
 .photo_slot(photo_slot),.panel_height(8'd0),.photo_full(full),.photo_blend(blend),
 .map_mode(map_mode),.map_zoom(1'b0),.map_slot(3'd3),
 .map_x(9'd0),.map_y(8'd0),.scene_tag(tag),
 .applied_pulse(applied_pulse),.applied_tag(applied_tag),.applied_mask(applied_mask),
`ifdef READER_HAS_APPLIED_FULL
 .applied_full(applied_full),
`endif
 .req_ack(ack),.fifo_clear(clear),.rd_en(re),.rd_addr(addr),
 .fifo_we(we),.fifo_data(word),.busy(busy),.applied_slot(applied_slot),
 .applied_valid(applied_valid),.fault(fault));
`ifndef READER_HAS_APPLIED_FULL
assign applied_full=dut.desc[17];
`endif
wire legacy_filter_sample=dut.filter_active && dut.filter_running && dut.filter_pending &&
    (!dut.filter_inside || dut.filter_data_ready) &&
    ((!dut.second_pass && !dut.single_row) || dut.fifo_room_output) &&
    !(dut.state[28] && dut.req_sync[1]);

// Queue every issued word. The independent output reference below checks the
// native photo rectangle and the retained detail border on the same frame.
always @(posedge clk) if(!rst) begin
 cycle=cycle+1;
 sample_checks=sample_checks+1;
 if(dut.filter_sample!==legacy_filter_sample)
  $fatal(1,"filter_sample mismatch frame=%0d state=%h old=%b new=%b first_pass=%b",frame,dut.state,legacy_filter_sample,dut.filter_sample,(!dut.second_pass && !dut.single_row));
 if(dut.filter_running) begin
  filter_running_checks=filter_running_checks+1;
  if(dut.filter_active!==1'b1) $fatal(1,"filter_running without filter_active frame=%0d state=%h",frame,dut.state);
 end
 if(dut.filter_sample) begin
  filter_samples=filter_samples+1;
  if(!dut.second_pass && !dut.single_row)first_pass_samples=first_pass_samples+1;
 end
 if(dut.returning) begin
  direct_checks=direct_checks+1;
  if(dut.direct_read!==(!dut.filter_active && dut.mode!=3))
   $fatal(1,"direct_read mismatch frame=%0d state=%h mode=%0d filter_active=%b direct_read=%b",frame,dut.state,dut.mode,dut.filter_active,dut.direct_read);
  if(rv) direct_return_checks=direct_return_checks+1;
 end
 if(fault) $fatal(1,"reader fault frame=%0d n=%0d state=%h",frame,n,dut.state);
 if(re) begin
  if(!previous_re) begin
   if(addr[1:0]!==2'b00) $fatal(1,"unaligned burst address=%0d",addr);
   burst_words=0; bursts=bursts+1;
  end else if(addr!==previous_address+1)
   $fatal(1,"non-contiguous burst frame=%0d addr=%0d previous=%0d",frame,addr,previous_address);
  if(iq-oq>=4096) $fatal(1,"memory model queue overflow");
  queue[iq%4096]=addr; due[iq%4096]=cycle+4+(iq%5); iq=iq+1;
  read_count=read_count+1; burst_words=burst_words+1; previous_address=addr;
 end
 if(previous_re && !re && (burst_words==0 || burst_words%4!=0))
  $fatal(1,"unaligned burst length=%0d",burst_words);
 previous_re=re;
 if(rv) begin
  if(oq>=iq) $fatal(1,"orphan memory return");
  oq=oq+1; return_count=return_count+1;
 end else if(iq>oq) gaps=gaps+1;
 if(applied_pulse) begin
  apply_count=apply_count+1;
  if(!applied_valid || applied_tag!==tag || applied_full!==expected_full || applied_mask!==expected_mask)
   $fatal(1,"handoff mismatch frame=%0d tag=%0d full=%b mask=%b expected=%b",frame,applied_tag,applied_full,applied_mask,expected_mask);
 end
 if(we) begin
  if(!active || n>=480000) $fatal(1,"unexpected extra pixel frame=%0d n=%0d",frame,n);
  x=n%800; y=n/800; slot=-1; sx=0; sy=0;
  left=expected_native?80:304; right=expected_native?720:784;
  top=expected_native?60:64; bottom=expected_native?540:424;
  if(x>=left && x<right && y>=top && y<bottom) begin
   slot=slide_anim && x<right-shift?2:1;
   local_x=slide_anim?(slot==2?x-left+shift:x-(right-shift)):x-left;
   local_y=y-top;
   sx=expected_native?local_x:local_x*4/3;
   sy=expected_native?local_y:local_y*4/3;
  end
  expected_address=slot*307200+sy*640+sx;
  expected=slot<0?32'hf3f5f900:pattern(expected_address);
  if(word!==expected) $fatal(1,"pixel mismatch frame=%0d x=%0d y=%0d got=%h expected=%h address=%0d",frame,x,y,word,expected,expected_address);
  if(expected_full || expected_blend) begin
   if(x>=80 && x<720 && y>=60 && y<540) native_count=native_count+1;
   else retained_count=retained_count+1;
   if(x==79 || x==80 || x==719 || x==720 || y==59 || y==60 || y==539 || y==540)
    boundary_checks=boundary_checks+1;
  end
  if(applied_full!==expected_full || applied_mask!==expected_mask)
   $fatal(1,"descriptor changed mid-frame frame=%0d n=%0d",frame,n);
  if(slot<0) pad_count=pad_count+1;
  if(slot==expected_photo) photo_count=photo_count+1;
  n=n+1; total=total+1;
 end
end

// Return values on falling edges so that data and valid are stable at the DUT's
// sampling edge. Frequent short gaps and a periodic six-cycle gap exercise DRAIN.
always @(negedge clk) begin
 rv=0;
 if(!rst && oq<iq && cycle>=due[oq%4096] && cycle%11!=0 && cycle%17!=3 && cycle%157<151) begin
  rv=1; return_word=pattern(queue[oq%4096]);
 end
 if(!rst) begin
  if(n-consumed<0 || n-consumed>511) $fatal(1,"display FIFO range error occupancy=%0d",n-consumed);
  used=n-consumed;
  if(n-consumed>max_used) max_used=n-consumed;
 end
end

// Independent 40 MHz scan consumer, with 256 blank pixels per line. A vertical
// blank prefill lets the reader fill the FIFO before continuous active video.
initial forever begin
 wait(consume_start); #600000;
 for(cy=0;cy<600;cy=cy+1) begin
  for(cx=0;cx<800;cx=cx+1) begin
   if(consumed>=n) $fatal(1,"display FIFO underflow frame=%0d x=%0d y=%0d",frame,cx,cy);
   consumed=consumed+1; #25;
  end
  #6400;
 end
 wait(!consume_start);
end

initial begin
 repeat(8) @(negedge clk); rst=0;
 for(frame=0;frame<7;frame=frame+1) begin
  @(negedge clk);
  expected_native=frame!=0 && frame!=6; native_mode=expected_native;
  slide_anim=frame>=2 && frame<=5;
  case(frame)
   2:begin slide_phase=0;shift=0;end
   3:begin slide_phase=7;shift=109;end
   4:begin slide_phase=15;shift=467;end
   5:begin slide_phase=29;shift=640;end
   default:begin slide_phase=0;shift=0;end
  endcase
  tag=frame+1; expected_full=0;expected_blend=0;expected_map=0;expected_bilinear=0;
  bilinear=expected_native; // native pixels must ignore the selected scale filter
  expected_mask=slide_anim?6'b000110:6'b000010;
  n=0; consumed=0; used=0; read_count=0; return_count=0; gaps=0;
  bursts=0; pad_count=0; photo_count=0; apply_count=0; max_used=0;
  active=1; req=1; wait(ack); repeat(8) @(negedge clk); req=0;
  started=$time; consume_start=1;
  wait(n>=200000); @(negedge clk); native_mode=!expected_native;
  wait(n==480000 && consumed==480000);
  consume_start=0; active=0; repeat(1000) @(negedge clk);
  if(iq!=oq || read_count!=return_count || apply_count!=1) $fatal(1,"accounting");
  if($time-started>16666667) $fatal(1,"throughput");
  $display("FRAME_PASS native=%0d phase=%0d pixels=%0d reads=%0d max_fifo=%0d",expected_native,slide_phase,n,read_count,max_used);
 end
 $display("PASS: native carousel full scan, original layout, eased slide, pixel-exact samples, midframe mode, FIFO and slot masks");
 $finish;
end
initial begin #140000000; $fatal(1,"native carousel timeout"); end
endmodule
