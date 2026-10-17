`timescale 1ns/1ps
// This checks the parallel-data capture contract of the existing serializer.
// It does not model LVDS electrical behaviour or the encrypted HDMI encoder.
module capture_case #(parameter real PIXEL_PHASE=0.0)(output reg done=0);
 reg pixel_clk=0,serial_clk=0,rst=1;
 reg[9:0] word=0;
 wire serial;
 integer loads=0,serial_edges=0,last_load_edge=0,last_word=-1;
 real changed_at=0.0,minimum_age=1.0e9;
 always #2.5 serial_clk=~serial_clk;
 initial begin #(2.5+PIXEL_PHASE);pixel_clk=1;forever #12.5 pixel_clk=~pixel_clk;end
 always @(posedge pixel_clk)begin
   word<=word+1'b1;
   changed_at=$realtime;
 end
 lane_lvds_10_1 dut(.I_pixel_clk(pixel_clk),.I_serial_clk(serial_clk),.I_rst(rst),.I_logic_rst(rst),.I_data_in(word),.O_serial_out(serial));
 // Evaluate before the pixel-domain NBA update on coincident edges. The word
 // captured at that edge is the old, fully stable word, not the new word.
 reg[9:0] observed;
 real word_changed_at=0.0;
 always @(word)word_changed_at=$realtime;
 always @(posedge serial_clk)begin
   serial_edges=serial_edges+1;
   if(!rst && dut.S_load_en_2d && loads<2000)begin
     observed=word;
     if(loads>4)begin
       if(serial_edges-last_load_edge!=5)$fatal(1,"capture is not once per five serial cycles");
       if(word!==((last_word+1)&1023))$fatal(1,"parallel word skipped or repeated phase=%f",PIXEL_PHASE);
       if($realtime-word_changed_at<19.999)$fatal(1,"capture before four fast clocks phase=%f age=%f",PIXEL_PHASE,$realtime-word_changed_at);
       if($realtime-word_changed_at<minimum_age)minimum_age=$realtime-word_changed_at;
     end
     last_word=word;last_load_edge=serial_edges;loads=loads+1;
     #0.001;
     if(dut.S_shift_data!==observed)$fatal(1,"wrong parallel word captured");
     if(loads==2000)begin
       $display("CAPTURE phase=%0.3f ns loads=%0d minimum_stability=%0.3f ns",PIXEL_PHASE,loads,minimum_age);
       done=1;
     end
   end
 end
 initial begin #123.1;rst=0;end
endmodule

module tb_hdmi_capture_contract;
 wire[5:0] done;
 capture_case #(.PIXEL_PHASE(0.0)) c0(done[0]);
 capture_case #(.PIXEL_PHASE(0.1)) c1(done[1]);
 capture_case #(.PIXEL_PHASE(1.0)) c2(done[2]);
 capture_case #(.PIXEL_PHASE(2.5)) c3(done[3]);
 capture_case #(.PIXEL_PHASE(4.0)) c4(done[4]);
 capture_case #(.PIXEL_PHASE(4.9)) c5(done[5]);
 initial begin wait(&done);$display("PASS: 12000 consecutive HDMI parallel words across six phase offsets; one capture per five serial cycles, each word stable for at least four serial cycles");$finish;end
 initial begin #100000;$fatal(1,"HDMI capture timeout");end
endmodule

// The capture contract ends at S_shift_data. The ODDR is only an elaboration
// stub here; no assertions claim to validate this behavioural output model.
module EG_LOGIC_ODDR(input clk,rst,d0,d1,output q);
 assign q=1'b0;
endmodule
