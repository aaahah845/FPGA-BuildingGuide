`timescale 1ns/1ps
// Allocation-level regression of the actual resource manager. Cache metadata
// is seeded; no SD payload or physical SDRAM timing is modeled here.
module tb_cache_tailfix;
reg clk=0; always #10 clk=~clk;
reg rst=1;
reg [5:0] applied=0;
reg [20:0] words=307200;
integer checks=0, cases=0, seed=161016, n, r, t, q, j;
reg finished=0;
reg [5:0] before_valid, before_fp[0:5], blocked_ref;
reg [2:0] before_age[0:5];
integer owners[0:5], choice1, choice2, chosen, max_age, owner, spins;
reg [5:0] expected_mask, remaining, eligible_free;
sd_site_assets #(.ENABLE_SD_AUDIO(0)) dut(
 .clk(clk),.rst(rst),.cfg_video_clk(clk),.cfg_video_addr(13'd0),
 .audio_clk(clk),.audio_rst(rst),.audio_take(1'b0),.audio_music(1'b0),.audio_event(4'd0),
 .request_toggle(1'b0),.request_prefetch(1'b0),.prefetch_cancel(1'b0),.request_keep(32'd0),
 .request_primary(7'd40),.request_photo(7'd60),.request_need_photo(1'b1),.request_tag(8'd0),
 .decision_toggle(1'b0),.decision_accept(1'b0),.applied_valid(1'b1),.applied_tag(8'd0),
 .applied_mask(applied),.write_abort_done(1'b1),.frame_done_pulse(1'b0),
 .write_req_ack(1'b0),.write_fifo_used(9'd0),.SD_MISO(1'b1),
 .audio_fallback(),.audio_error(),.audio_available(),.audio_sample(),.cfg_video_data(),
 .font_write_en(),.font_write_addr(),.font_write_data(),.config_ready(),.background_ready(),
 .error_code(),.cached_maps(),.image_loading(),.loading_resource(),.response_toggle(),
 .response_ok(),.response_primary(),.response_photo(),.write_abort(),.write_buf_idx(),
 .write_tail_idx(),.slot_tails(),.write_req(),.write_en(),.write_data(),.write_stride(),
 .write_words(),.write_first_offset(),.write_bottom_up(),.slot_widths(),.slot_strides(),
 .slot_heights(),.SD_nCS(),.SD_DCLK(),.SD_MOSI()
);

task initialize_cache;
integer i;
begin
 @(negedge clk); rst=1;
 repeat(3) @(negedge clk);
 rst=0; dut.state=dut.HALT;
 dut.resource_count=69; dut.floor_count=3;
 dut.map_id0=1; dut.map_id1=2; dut.map_id2=3;
 dut.valid=6'b111111;
 for(i=0;i<6;i=i+1) begin
   dut.resource[i]=10+i;
   dut.footprint[i]=6'b1<<i;
   dut.age[i]=i%5;
 end
 dut.prefetch=0; dut.prefetch_keep=0;
 dut.primary_pin_valid=0; dut.primary_pin=0;
 dut.held=0; applied=0;
 dut.reserved=0; dut.allocating=1; dut.pair_second=0;
 dut.wanted_id=60; dut.phase=1; dut.need_photo=1;
 words=307200;
end
endtask

task make_map;
input integer root_slot, tail_slot;
begin
 dut.resource[root_slot]=1;
 dut.footprint[root_slot]=(6'b1<<root_slot)|(6'b1<<tail_slot);
 dut.valid[tail_slot]=0;
end
endtask

// Independent contract: prefer genuinely unused storage; otherwise reclaim
// a least-recently-touched unprotected IMAGE. Ties retain physical scan order.
task pick_expected;
input [5:0] available;
output integer pick;
integer i, best_age;
reg found_empty;
begin
 pick=-1; best_age=0; found_empty=0;
 for(i=0;i<6;i=i+1) if(available[i] && owners[i]<0 && !found_empty) begin
   pick=i; found_empty=1;
 end
 if(!found_empty) for(i=0;i<6;i=i+1)
   if(available[i] && owners[i]>=0 && (pick<0 || before_age[owners[i]]>best_age)) begin
     best_age=before_age[owners[i]]; pick=i;
   end
end
endtask

task check_allocation;
integer i, k;
begin
 repeat(3) @(negedge clk);
 cases=cases+1;
 before_valid=dut.valid;
 for(i=0;i<6;i=i+1) begin
   before_fp[i]=dut.footprint[i]; before_age[i]=dut.age[i]; owners[i]=-1;
 end
 blocked_ref=0;
 for(i=0;i<6;i=i+1) if(before_valid[i]) begin
   for(k=0;k<6;k=k+1) if(before_fp[i][k]) owners[k]=i;
   if(applied[i] || dut.held[i] || (dut.primary_pin_valid && dut.primary_pin==i) ||
      (dut.prefetch && ((dut.prefetch_keep[28] && dut.resource[i]==dut.prefetch_keep[6:0]) ||
       (dut.prefetch_keep[29] && dut.resource[i]==dut.prefetch_keep[13:7]) ||
       (dut.prefetch_keep[30] && dut.resource[i]==dut.prefetch_keep[20:14]) ||
       (dut.prefetch_keep[31] && dut.resource[i]==dut.prefetch_keep[27:21]))))
       blocked_ref=blocked_ref|before_fp[i];
 end
 remaining=~blocked_ref;
 pick_expected(remaining,choice1);
 choice2=choice1;
 if(words>307200 && choice1>=0) begin
   remaining[choice1]=0;
   pick_expected(remaining,choice2);
 end
 expected_mask=0;
 if(choice1>=0) expected_mask[choice1]=1;
 if(choice2>=0) expected_mask[choice2]=1;
 dut.state=dut.SELECT_WAIT;
 spins=0;
 while(!dut.reserved && dut.state!=dut.ABORT_WAIT && spins<60) begin
   @(negedge clk); spins=spins+1;
 end
 if(spins>=60) $fatal(1,"allocator did not terminate case=%0d",cases);
 checks=checks+1;
 if(choice1<0 || choice2<0) begin
   if(dut.reserved || dut.valid!==before_valid)
     $fatal(1,"insufficient unprotected storage must not invalidate cache case=%0d",cases);
 end else begin
   if(!dut.reserved || dut.allocation!==expected_mask)
     $fatal(1,"wrong eviction case=%0d actual=%b expected=%b valid=%b",cases,dut.allocation,expected_mask,before_valid);
   if((dut.allocation & blocked_ref)!=0) $fatal(1,"protected image overwritten");
   for(i=0;i<6;i=i+1) begin
     checks=checks+1;
     if(dut.valid[i] !== (before_valid[i] && ((before_fp[i]&expected_mask)==0)))
       $fatal(1,"image validity incorrect after allocation case=%0d root=%0d",cases,i);
   end
 end
 dut.state=dut.HALT;
end
endtask

initial begin
 force dut.fs_error=0; force dut.mounted=1;
 force dut.write_words=words; force dut.bmp_write_req=0;
 // Reproduction: an old room is available, while the newer map owns 2/3.
 initialize_cache(); make_map(2,3);
 applied=1; dut.primary_pin_valid=1; dut.primary_pin=0;
 dut.age[1]=3; dut.age[2]=0; dut.age[4]=5; dut.age[5]=2;
 check_allocation();
 if(!dut.valid[2]) $fatal(1,"warm map unnecessarily discarded");
 $display("PASS directed: foreground room miss preserves newer two-slot map");
 // Tail may precede its root and be physically non-adjacent.
 initialize_cache(); make_map(5,0); applied=2;
 dut.age[5]=1; dut.age[0]=5; dut.age[3]=5;
 check_allocation();
 if(!dut.valid[5]) $fatal(1,"tail must inherit root age");
 // Map remains replaceable when it is actually the least recently used.
 initialize_cache(); make_map(2,3); dut.age[2]=5;
 check_allocation();
 if(dut.valid[2]) $fatal(1,"unprotected oldest map should be replaceable");
 // The only two reusable slots are a non-contiguous old map's own pair.
 initialize_cache(); make_map(5,1); applied=6'b011101;
 words=500000; dut.wanted_id=2;
 check_allocation();
 if(dut.allocation!=6'b100010) $fatal(1,"reuse both old-map slots");
 // A real hole wins over both live roots and live tails.
 initialize_cache(); make_map(2,3); dut.valid[5]=0;
 check_allocation();
 if(dut.write_buf_idx!=5 || !dut.valid[2]) $fatal(1,"real empty slot should win");
 // Once a root is invalidated, its old footprint no longer occupies storage.
 initialize_cache(); make_map(2,3); dut.valid[2]=0;
 check_allocation();
 if(dut.write_buf_idx!=2) $fatal(1,"invalid map's old slots should be reusable");
 // Hard scanout/pin and transaction holds expand to all physical slots.
 initialize_cache(); make_map(2,3); applied=4; dut.age[2]=5;
 check_allocation();
 if(!dut.valid[2]) $fatal(1,"scanout protection lost");
 initialize_cache(); make_map(2,3); dut.held=4; dut.age[2]=5;
 check_allocation();
 initialize_cache(); make_map(2,3); dut.primary_pin_valid=1; dut.primary_pin=2;
 dut.age[2]=5; check_allocation();
 // Existing prefetch keep behavior is unchanged.
 initialize_cache(); make_map(2,3); dut.prefetch=1;
 dut.prefetch_keep={4'b0001,21'd0,7'd1}; dut.age[2]=5;
 check_allocation();
 // No space / one slot for a two-slot map must fail without damaging cache.
 initialize_cache(); make_map(2,3); applied=dut.valid;
 check_allocation();
 initialize_cache(); words=500000; dut.wanted_id=2; applied=6'b011111;
 check_allocation();
 $display("PASS directed: scattered pairs, legitimate map eviction, empty slots, stale footprints and all protection roots");
 for(n=0;n<256;n=n+1) begin
   initialize_cache();
   r=$unsigned($random(seed))%6;
   t=(r+1+($unsigned($random(seed))%5))%6;
   make_map(r,t);
   for(j=0;j<6;j=j+1) dut.age[j]=$unsigned($random(seed))%6;
   if(n%3==0) begin
     q=$unsigned($random(seed))%6;
     if(q!=r && q!=t) dut.valid[q]=0;
   end
   applied=$random(seed)&dut.valid;
   dut.held=($random(seed)&dut.valid)&6'b000101;
   dut.prefetch=(n%4==0);
   dut.prefetch_keep={4'b0001,21'd0,7'd1};
   if(n%2==0) begin words=500000; dut.wanted_id=2; end
   check_allocation();
 end
 $display("PASS: cache tail ownership suite cases=%0d checks=%0d",cases,checks);
 finished=1;
end
endmodule

module sd_card_top(
 input clk,rst,SD_MISO,sd_sec_read,sd_sec_write,
 input [31:0] sd_sec_read_addr,sd_sec_write_addr,
 input [7:0] sd_sec_write_data,
 output SD_nCS,SD_DCLK,SD_MOSI,sd_init_done,sd_sec_read_data_valid,
 output sd_sec_read_end,sd_sec_write_data_req,sd_sec_write_end,
 output [7:0] sd_sec_read_data
);
assign SD_nCS=1,SD_DCLK=0,SD_MOSI=0,sd_init_done=0;
assign sd_sec_read_data=0,sd_sec_read_data_valid=0,sd_sec_read_end=0;
assign sd_sec_write_data_req=0,sd_sec_write_end=0;
endmodule
