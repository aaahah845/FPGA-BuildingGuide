`timescale 1ns/1ps
module tb_layout_fade;
reg clk=0,rst=1,frame=0,want=0;
always #5 clk=~clk;
wire native_mode,busy;wire [4:0] alpha;
site_scene_broker #(.CLK_FREQ_HZ(10000)) dut(
.clk(clk),.rst(rst),.site_ready(1'b0),.background_ready(1'b0),.frame_request(frame),
.carousel_native_requested(want),.carousel_native(native_mode),.layout_alpha(alpha),.transition_busy(busy),
.cfg_we(1'b0),.cfg_addr(13'd0),.cfg_data(8'd0),.map_requested(1'b0),.detail_requested(1'b0),
.full_requested(1'b0),.next_pulse(1'b0),.auto_toggle_pulse(1'b0));
task tick;begin @(negedge clk);frame=1;repeat(4)@(negedge clk);frame=0;repeat(4)@(negedge clk);end endtask
integer i;
initial begin
repeat(4)@(negedge clk);rst=0;
force dut.ready=1;force dut.map_mode=0;force dut.motion_state=0;
force dut.slide_anim=0;force dut.panel_height=0;force dut.outstanding=0;
force dut.advance_slide=0;force dut.wanted_key=0;force dut.committed_key=0;
tick; if(native_mode!==0 || alpha!==16 || busy!==0)$fatal(1,"initial");
want=1;force dut.slide_anim=1;tick;if(busy!==0 || native_mode!==0)$fatal(1,"started during slide");
force dut.slide_anim=0;tick;if(!busy || alpha!==16)$fatal(1,"no fade start");
for(i=15;i>=0;i=i-1)begin tick;if(alpha!==i || native_mode!==0)$fatal(1,"old geometry changed before invisible");end
tick;if(native_mode!==1 || alpha!==0 || !busy)$fatal(1,"invisible handoff");
for(i=1;i<=16;i=i+1)begin tick;if(alpha!==i || native_mode!==1)$fatal(1,"fade in");end
if(busy!==0)$fatal(1,"busy did not clear");
want=0;tick;
for(i=15;i>=0;i=i-1)begin tick;if(alpha!==i || native_mode!==1)$fatal(1,"reverse fade out");end
tick;if(native_mode!==0 || alpha!==0)$fatal(1,"reverse handoff");
for(i=1;i<=16;i=i+1)tick;
if(alpha!==16 || busy!==0 || native_mode!==0)$fatal(1,"reverse finish");
$display("PASS: layout waits for slide, opacity changes by frame, geometry switches only at zero, fade-in completes, return releases busy");$finish;
end
initial begin #100000;$fatal(1,"timeout");end
endmodule
