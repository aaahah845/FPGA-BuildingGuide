`timescale 1ns/1ps
module tb_startup_gate;
reg clk=0,rst=1,vs=0,de=0,site_ready=0;
reg [23:0] rgb=0;
wire [23:0] gated_rgb,out_data,reference_data;
wire gate_ready,out_user,out_valid,out_last,reference_user,reference_valid,reference_last;
always #12.5 clk=~clk;
startup_gate_from_top gate(
 .video_clk(clk),.rst_video_output(rst),.adjusted_vs(vs),.site_ready(site_ready),
 .adjusted_rgb(rgb),.gated_rgb(gated_rgb),.gate_ready(gate_ready));
video_rgb_to_axis dut(
 .I_clk(clk),.I_rst(rst),.I_vs(vs),.I_de(de),.I_rgb(gated_rgb),
 .O_video_user(out_user),.O_video_valid(out_valid),.O_video_last(out_last),.O_video_data(out_data));
video_rgb_to_axis reference_dut(
 .I_clk(clk),.I_rst(rst),.I_vs(vs),.I_de(de),.I_rgb(rgb),
 .O_video_user(reference_user),.O_video_valid(reference_valid),
 .O_video_last(reference_last),.O_video_data(reference_data));
integer cycles=0,active_pixels=0,sof_count=0,eol_count=0,x;

task cycle;
 input reset_value,vs_value,de_value,ready_value,expect_gate;
 input [23:0] pixel;
 begin
  @(negedge clk);rst=reset_value;vs=vs_value;de=de_value;site_ready=ready_value;rgb=pixel;
  @(posedge clk);#1;
  cycles=cycles+1;
  if({out_user,out_valid,out_last}!=={reference_user,reference_valid,reference_last})
   $fatal(1,"AXIS cadence differs from reference at cycle %0d",cycles);
  if(out_valid!==(reset_value?1'b0:de_value)) $fatal(1,"Valid latency changed at cycle %0d",cycles);
  if(out_data!==(reset_value?24'd0:expect_gate?pixel:24'd0))
   $fatal(1,"Pixel gate mismatch cycle=%0d got=%h expected_gate=%b input=%h",cycles,out_data,expect_gate,pixel);
  if(reference_data!==(reset_value?24'd0:pixel)) $fatal(1,"Reference pixel mismatch");
  if(out_valid) active_pixels=active_pixels+1;
  if(out_user) sof_count=sof_count+1;
  if(out_last) eol_count=eol_count+1;
 end
endtask

task active_line;
 input visible,raise_ready_midline,first_line;
 input [7:0] pattern;
 begin
  for(x=0;x<800;x=x+1) begin
   cycle(0,0,1,raise_ready_midline?(x>=320):site_ready,visible,{pattern,x[7:0],8'h97});
   if(out_last!==(x==799)) $fatal(1,"EOL shifted to wrong pixel %0d",x);
   if(out_user!==(first_line && x==0)) $fatal(1,"SOF shifted to wrong pixel %0d",x);
  end
  cycle(0,0,0,site_ready,visible,24'hac7512);
  cycle(0,0,0,site_ready,visible,24'h13579b);
 end
endtask

initial begin
 cycle(1,0,0,0,0,24'h123456);
 cycle(1,0,0,0,0,24'h234567);
 cycle(0,1,0,0,0,24'h345678);
 cycle(0,1,0,0,0,24'h456789);
 cycle(0,0,0,0,0,24'h56789a);
 active_line(0,1,1,8'h31);
 if(gate_ready!==0 || site_ready!==1) $fatal(1,"Gate opened during an active line");
 active_line(0,0,0,8'h62);
 $display("PASS: site_ready raised at pixel 320 keeps the current and next active line black");

 // On the first VS edge the gate register changes; the AXIS register still
 // samples the old black value on that edge, which is outside active video.
 cycle(0,1,0,1,0,24'h6789ab);
 if(gate_ready!==1) $fatal(1,"Gate did not open during vertical sync");
 cycle(0,1,0,1,1,24'h789abc);
 cycle(0,0,0,1,1,24'h89abcd);
 active_line(1,0,1,8'h93);
 active_line(1,0,0,8'hc4);
 $display("PASS: next vertical sync exposes original RGB with unchanged SOF/EOL timing");

 // Reset while site_ready remains high must return to black; it must wait
 // for another VS before showing pixels again, even with ready already high.
 cycle(1,0,0,1,0,24'h9abcde);
 if(gate_ready!==0) $fatal(1,"Reset did not clear display readiness");
 cycle(0,0,0,1,0,24'habcdef);
 active_line(0,0,1,8'hd5);
 cycle(0,1,0,1,0,24'hbcdef0);
 cycle(0,0,0,1,1,24'hcdef01);
 active_line(1,0,1,8'he6);
 $display("PASS: reset returns to black and visibility resumes only after another VS");
 if(active_pixels!=4800 || eol_count!=6 || sof_count!=4)
  $fatal(1,"Unexpected stream counts: pixels=%0d eol=%0d sof=%0d",active_pixels,eol_count,sof_count);
 $display("PASS: startup gate suite cycles=%0d active_pixels=%0d SOF=%0d EOL=%0d; user/valid/last match ungated reference on every clock",cycles,active_pixels,sof_count,eol_count);
 $finish;
end
initial begin #300000;$fatal(1,"Startup gate timeout");end
endmodule
