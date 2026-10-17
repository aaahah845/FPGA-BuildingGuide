`timescale 1ns/1ps
module tb_photo_view_control;
reg clk=0;
always #5 clk=~clk;
reg rst=1,frame=0,cfg_we=0;
reg [12:0] cfg_addr=0;
reg [7:0] cfg_data=0;
reg [3:0] keys=4'hf,switches=4'hf;
reg [6:0] nav=7'h7f;
reg panel=0,photo_active=0;
wire [1:0] floor_id,field;
wire [3:0] room,brightness;
wire [2:0] state;
wire [29:0] occupied;
wire [15:0] elapsed;
wire detail,full,settings,map,visible,bilinear,next_pulse,auto_pulse;
integer ticks=0,nexts=0,autos=0;
always @(negedge clk) begin
    ticks=ticks+1;
    frame=ticks%20==0;
    if(next_pulse) nexts=nexts+1;
    if(auto_pulse) autos=autos+1;
end

guide_scene_control #(
    .EXTERNAL_NAV(1),.RUNTIME_CONFIG(1),.DEFER_MAP_ENTRY(1),
    .CLK_FREQ_HZ(10000),.DEBOUNCE_MS(1),.LONG_PRESS_MS(100)
) dut(
    .clk(clk),.rst(rst),.frame_request(frame),
    .cfg_we(cfg_we),.cfg_addr(cfg_addr),.cfg_data(cfg_data),
    .key_next_n(keys[0]),.key_floor_n(keys[1]),
    .key_room_n(keys[2]),.key_auto_occ_n(keys[3]),
    .switches(switches),.nav_keys_n(nav),
    .panel_active(panel),.photo_view_active(photo_active),.map_entry_ready(1'b1),
    .display_floor_idx(floor_id),.display_room_idx(room),
    .floor_idx(floor_id),.selected_room_idx(room),.control_state(state),
    .room_occupied(occupied),.selected_elapsed_bcd(elapsed),
    .detail_requested(detail),.photo_full_requested(full),.selection_visible(visible),
    .map_mode(map),.map_available(map),.map_width(11'd960),.map_height(10'd563),
    .settings_open(settings),.settings_field(field),.brightness(brightness),
    .bilinear_enabled(bilinear),.next_pulse(next_pulse),.auto_toggle_pulse(auto_pulse)
);

task ck;
    input condition;
    input [1023:0] message;
    begin
        if(condition!==1'b1)
            $fatal(1,"%s state=%0d room=%0d detail=%b full=%b active=%b settings=%b occupied=%h elapsed=%h",
                message,state,room,detail,full,photo_active,settings,occupied,elapsed);
    end
endtask

task key;
    input integer k;
    begin
        @(negedge clk);nav[k]=0;
        repeat(30) @(negedge clk);
        nav[k]=1;
        repeat(60) @(negedge clk);
    end
endtask

task hold_key;
    input integer k;
    begin
        @(negedge clk);nav[k]=0;
        repeat(1100) @(negedge clk);
        nav[k]=1;
        repeat(60) @(negedge clk);
    end
endtask

// External buttons: MID=4, SET=5, RST=6, each firing once per press.
task button;
    input integer k;
    begin
        @(negedge clk);nav[k]=0;
        repeat(80) @(negedge clk);
        nav[k]=1;
        repeat(80) @(negedge clk);
    end
endtask

integer i;
reg [7:0] cfg[0:8191];
initial begin
    $readmemh("rooms10_cfg.hex",cfg);
    for(i=0;i<8192;i=i+1) begin
        @(negedge clk);cfg_we=1;cfg_addr=i;cfg_data=cfg[i];
    end
    @(negedge clk);cfg_we=0;rst=0;
    repeat(150) @(negedge clk);
    button(4);
    ck(!detail && !full && state==0,"unselected confirmation remains ignored");
    key(3);key(2);
    ck(state==1 && room==1 && visible,"select the second room");
    hold_key(2);
    repeat(10500) @(negedge clk);
    ck(occupied==2 && elapsed!=0,"baseline occupancy and elapsed timer operate");

    button(4);
    ck(detail && !full,"first confirmation requests only the detail");
    button(4);
    ck(detail && !full,"second confirmation waits until the panel is active");
    panel=1;
    button(4);
    repeat(200) @(negedge clk);
    ck(full && detail && room==1,"second confirmation latches the full photo request");
    hold_key(2);hold_key(3);key(0);key(1);key(2);
    @(negedge clk);switches[1]=!switches[1];
    repeat(80) @(negedge clk);
    ck(full && detail && room==1 && floor_id==0 && occupied==2 && elapsed!=0 && nexts==0 && autos==0,
        "request alone locks directions and occupancy before broker feedback");
    photo_active=1;

    button(5);
    ck(settings && full && detail,"SET opens settings over a full photo");
    button(4);
    ck(bilinear && full && detail,"MID in settings changes the filter without changing the photo request");
    key(1);key(2);
    ck(brightness==7 && field==1 && occupied==2,"settings directions remain available over a full photo");
    button(6);
    ck(!settings && full && detail,"return closes settings before closing the full photo");

    // Simultaneous SW1/SW3 retains the established SW1 priority.
    @(negedge clk);switches[0]=!switches[0];switches[2]=!switches[2];
    repeat(80) @(negedge clk);
    ck(settings && full && detail,"settings toggle wins over a simultaneous return");
    button(5);
    ck(!settings && full && detail,"SET closes settings without leaving the full photo");

    button(6);
    ck(!full && detail && room==1 && state==1,"return withdraws the full photo request and retains the detail");
    button(6);button(6);button(4);hold_key(2);
    ck(!full && detail && occupied==2 && elapsed!=0 && room==1,
        "repeated return and confirm during fade cannot close detail, reopen photo, or change occupancy");
    button(5);button(6);
    ck(!settings && !full && detail,"settings still have return priority during fade-out");

    // A direction held during the fade must stay canceled when feedback falls.
    @(negedge clk);nav[2]=0;
    repeat(200) @(negedge clk);
    photo_active=0;
    repeat(1200) @(negedge clk);
    nav[2]=1;
    repeat(80) @(negedge clk);
    ck(detail && occupied==2 && elapsed!=0 && room==1,"held gesture cannot leak through fade completion");
    hold_key(2);
    ck(detail && occupied==0 && elapsed==0,"fresh occupancy gesture works again after the fade");
    button(6);
    ck(!detail && !full && visible && room==1,"normal detail return restores the original room selection");
    button(4);
    ck(!detail && !full,"confirmation cannot reopen detail while its closing panel is active");
    panel=0;
    button(6);
    ck(state==0 && !visible && room==0,"normal selection return is unchanged");

    // Map observation details use the same full-photo contract.
    key(3);key(0);key(0);
    ck(map && state==3 && room==1,"enter the second map observation point");
    @(negedge clk);nav[4]=0;
    repeat(80) @(negedge clk);
    ck(detail && !full,"held first confirmation opens map detail once");
    panel=1;
    repeat(250) @(negedge clk);
    ck(detail && !full,"holding confirm cannot implicitly become a second confirmation");
    nav[4]=1;
    repeat(80) @(negedge clk);
    button(4);
    ck(full && detail && map && state==3 && room==1,"map detail opens full photo after a fresh confirmation");
    photo_active=1;
    button(6);button(6);
    ck(!full && detail && map && state==3 && room==1,"map return fade preserves point selection");
    photo_active=0;
    repeat(80) @(negedge clk);
    button(6);
    ck(!detail && !full && map && state==3 && room==1,"map detail closes normally after full-photo exit");
    $display("PASS: photo view control: second-confirm latch, panel readiness, pre-accept lock, fade return/repeated return, settings priority and controls, occupancy/timer protection, held-gesture cancellation, and original room/map detail behavior");
    $finish;
end
initial begin
    #2000000;
    $fatal(1,"photo view controller timeout");
end
endmodule
