`timescale 1ns/1ps
module tb_broker_photo_fade;
reg clk=0; always #5 clk=~clk;
reg rst=1,site_ready=0,frame_request=0;
reg cfg_we=0;
reg [12:0] cfg_addr=0;
reg [7:0] cfg_data=0;
reg detail_requested=1,full_requested=0,next_pulse=0,auto_toggle_pulse=0;
reg reader_full_applied=0,reader_follow=1;
wire request_toggle,request_prefetch,request_need_photo;
wire [6:0] request_primary,request_photo;
wire [7:0] request_tag;
reg response_toggle=0,response_ok=1;
reg [2:0] response_primary=0,response_photo=3;
wire full,ready,photo_view_active,slide_anim,auto_play_en,loading;
wire [4:0] photo_view_alpha;
wire [7:0] panel_height;
integer cycles=0,frames=0,checks=0,mode_changes=0,resource_responses=0;
reg observed_request=0;
reg [2:0] response_delay=0;
reg [2:0] pending_primary=0;
site_scene_broker #(.CLK_FREQ_HZ(1000000),.RUNTIME_CONFIG(1)) dut(
    .clk(clk),.rst(rst),.site_ready(site_ready),.background_ready(site_ready),
    .frame_request(frame_request),.requested_view({14'd4096,12'd640,11'd480}),
    .requested_scale(14'd4096),.cfg_we(cfg_we),.cfg_addr(cfg_addr),.cfg_data(cfg_data),
    .floor_idx(2'd0),.room_idx(4'd0),.map_requested(1'b0),
    .zoom_requested(1'b0),.pan_requested(1'b0),.floor_selecting(1'b0),
    .floor_cursor(2'd0),.cached_maps(3'b111),.map_entry_pending(1'b0),
    .nearest_room_valid(1'b0),.nearest_room_idx(4'd0),.origin_x(9'd0),.origin_y(8'd0),
    .detail_requested(detail_requested),.full_requested(full_requested),
    .next_pulse(next_pulse),.auto_toggle_pulse(auto_toggle_pulse),
    .reader_full_applied(reader_full_applied),.photo_view_alpha(photo_view_alpha),
    .photo_view_active(photo_view_active),.request_toggle(request_toggle),
    .request_prefetch(request_prefetch),.request_primary(request_primary),
    .request_photo(request_photo),.request_need_photo(request_need_photo),
    .request_tag(request_tag),.image_loading(1'b0),.loading_resource(7'd0),
    .response_toggle(response_toggle),.response_ok(response_ok),
    .response_primary(response_primary),.response_photo(response_photo),
    .ready(ready),.full(full),.panel_height(panel_height),.slide_anim(slide_anim),
    .auto_play_en(auto_play_en),.loading(loading)
);

// A small transaction peer, not a replacement for the real resource-manager
// tests: requests finish after a few clocks, foreground publication still
// obeys the broker's own frame-boundary decision logic.
always @(posedge clk) begin
    if(rst) begin
        response_toggle<=0;
        observed_request<=0;
        response_delay<=0;
    end else begin
        if(request_toggle!=observed_request) begin
            observed_request<=request_toggle;
            pending_primary<=request_primary==11?1:request_primary==12?2:0;
            response_delay<=3;
        end else if(response_delay!=0) begin
            response_delay<=response_delay-1'b1;
            if(response_delay==1) begin
                response_toggle<=observed_request;
                response_primary<=pending_primary;
                resource_responses=resource_responses+1;
            end
        end
    end
end

reg previous_full=0;
reg [4:0] previous_alpha=0;
reg sampled_frame;
always @(posedge clk) begin
    sampled_frame=frame_request && !dut.frame_d;
    #1;
    if(!rst) begin
        checks=checks+1;
        if(photo_view_alpha>16)
            $fatal(1,"invalid alpha %0d",photo_view_alpha);
        if((full!=previous_full || photo_view_alpha!=previous_alpha) && !sampled_frame)
            $fatal(1,"photo state changed outside frame boundary");
        if(full!=previous_full) mode_changes=mode_changes+1;
        if(full!==(photo_view_alpha==16)) $fatal(1,"full flag disagrees with opacity");
        if(photo_view_active!==(photo_view_alpha!=0)) $fatal(1,"active flag disagrees with opacity");
        if(photo_view_alpha>previous_alpha+1 || previous_alpha>photo_view_alpha+1)
            $fatal(1,"opacity discontinuity");
        if(photo_view_active && panel_height!=210)
            $fatal(1,"detail panel/slot was released while photo is active");
    end
    previous_full=full;
    previous_alpha=photo_view_alpha;
end

task tick;
begin @(posedge clk); #2; cycles=cycles+1; end
endtask
task frame;
begin
    @(negedge clk); frame_request=1;
    repeat(3) tick;
    @(negedge clk); frame_request=0;
    // Model the descriptor lock after request withdrawal and the video CDC.
    repeat(6) tick;
    if(reader_follow) reader_full_applied=full;
    repeat(21) tick;
    frames=frames+1;
end
endtask
task cfg;
input [12:0] addr;
input [7:0] data;
begin
    @(negedge clk); cfg_we=1; cfg_addr=addr; cfg_data=data;
    tick;
    @(negedge clk); cfg_we=0;
end
endtask
task settle;
input want_full;
integer limit;
begin
    limit=0;
    while((full!==want_full || photo_view_alpha!==(want_full?16:0)) && limit<90) begin
        frame;
        limit=limit+1;
    end
    if(limit==90) $fatal(1,"failed to settle full=%b alpha=%0d state=%0d",full,photo_view_alpha,0);
end
endtask
task pulse_next;
begin
    @(negedge clk); next_pulse=1;
    tick;
    @(negedge clk); next_pulse=0;
end
endtask
integer i,changes_before;
reg [31:0] paused_count;
reg [4:0] paused_slide;
initial begin
    repeat(5) tick;
    @(negedge clk); rst=0;
    cfg(8,3); cfg(10,3); cfg(11,0);
    for(i=0;i<3;i=i+1) begin cfg(256+i*16,10); cfg(257+i*16,40+i); end
    for(i=0;i<30;i=i+1) cfg(320+i*16,20+i);
    cfg(832,10); cfg(833,11); cfg(834,12);
    site_ready=1;
    // A premature request must retain the existing detail view until ready.
    full_requested=1;
    i=0;
    while(panel_height!=210 && i<60) begin
        if(photo_view_alpha!=0) $fatal(1,"fade before detail ready");
        frame; i=i+1;
    end
    settle(1);
    $display("PASS: direct fade waits for loaded photo and fully opened detail");
    full_requested=0; settle(0);
    if(panel_height!=210 || !detail_requested) $fatal(1,"return closed detail");
    $display("PASS: direct return preserves detail and ends at opacity zero");

    full_requested=1; repeat(6) frame;
    if(photo_view_alpha==0 || photo_view_alpha==16) $fatal(1,"missing intermediate blend");
    full_requested=0; settle(0);
    $display("PASS: partial opening reverses continuously to detail");
    full_requested=1; settle(1);
    full_requested=0; repeat(6) frame;
    full_requested=1; settle(1);
    $display("PASS: partial return reverses continuously to full photo");
    full_requested=0; settle(0);

    // Autoplay time and manual NEXT remain frozen throughout request/fade/full.
    @(negedge clk); auto_toggle_pulse=1; tick;
    @(negedge clk); auto_toggle_pulse=0;
    repeat(8) tick;
    full_requested=1;
    paused_count=dut.auto_count; paused_slide=dut.slide_number;
    pulse_next; settle(1); repeat(8) frame;
    if(dut.auto_count!=paused_count || dut.slide_number!=paused_slide)
        $fatal(1,"carousel advanced while full photo was pending/visible");
    full_requested=0; settle(0);
    $display("PASS: carousel elapsed time and NEXT are paused through native photo");

    // An already-started carousel must drain, not deadlock with a pending full
    // request waiting for slide_anim to become idle.
    pulse_next;
    i=0;
    while(!slide_anim && i<10) begin frame; i=i+1; end
    if(!slide_anim) $fatal(1,"test setup did not start carousel animation");
    full_requested=1; settle(1);
    if(slide_anim) $fatal(1,"full photo opened during carousel animation");
    $display("PASS: an in-flight carousel finishes before native-photo fade");

    // Defensive caller behavior: close detail and full together. The photo
    // and panel remain held until the outgoing fade has safely completed.
    detail_requested=0; full_requested=0;
    settle(0);
    if(panel_height!=210) $fatal(1,"panel was released before fade completion");
    repeat(12) frame;
    if(panel_height!=0) $fatal(1,"panel failed to close after fade completion");
    $display("PASS: detail close retains photo through fade, then closes panel");

    detail_requested=1; full_requested=1;
    settle(1);
    @(negedge clk); rst=1; full_requested=0;
    repeat(3) tick;
    if(full!==0 || photo_view_alpha!==0 || photo_view_active!==0)
        $fatal(1,"reset failed to restore detail mode");
    previous_alpha=0; previous_full=0;
    @(negedge clk); rst=0;
    repeat(15) frame;
    $display("PASS: reset restores detail with zero photo opacity");
    $display("PASS: broker photo fade assertions=%0d frames=%0d mode_changes=%0d resource_responses=%0d",checks,frames,mode_changes,resource_responses);
    $finish;
end
initial begin #5000000; $fatal(1,"test timeout"); end
endmodule
