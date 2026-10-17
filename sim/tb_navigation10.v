`timescale 1ns/1ps
module tb_navigation10;
reg clk=0;always #5 clk=~clk;reg rst=1,available=0,frame=0,focus=0,zoom=0;reg[3:0]selected=0;
wire[3:0]idx,nearest;wire valid;reg[9:0]xmem[0:9],ymem[0:9],xq,yq;wire[11:0]tx,cx;wire[10:0]ty,cy;wire[1:0]level;
always @(posedge clk)begin xq<=xmem[idx];yq<=ymem[idx];end
map_navigation dut(.clk(clk),.rst(rst),.available(available),.width(11'd640),.height(10'd480),.floor_id(2'd0),.room_count(4'd10),
.point_index(idx),.point_x(xq),.point_y(yq),.frame_request(frame),.zoom_reset(1'b0),.zoom_press(zoom),.left_press(1'b0),.right_press(1'b0),.up_press(1'b0),.down_press(1'b0),.focus_press(focus),.selected_room(selected),
.nearest_valid(valid),.nearest_room(nearest),.target_x2(tx),.target_y2(ty),.center_x2(cx),.center_y2(cy),.level(level));
integer i;
initial begin
 for(i=0;i<10;i=i+1)begin xmem[i]=20+i*20;ymem[i]=40;end
 xmem[9]=320;ymem[9]=240;xmem[8]=400;ymem[8]=300;
 repeat(3)@(negedge clk);rst=0;available=1;wait(valid);
 if(nearest!=9)$fatal(1,"last point omitted from nearest scan: %d",nearest);
 @(negedge clk);zoom=1;@(negedge clk);zoom=0;wait(dut.calc==0);repeat(200)@(negedge clk);
 // Emulate guide control: selection changes on the same edge as focus_press.
 @(negedge clk);focus=1;@(posedge clk);#1;selected=8;@(negedge clk);focus=0;
 repeat(5)@(negedge clk);
 if(tx!=800 || ty!=600)$fatal(1,"focus used preceding room / stale RAM data x=%d y=%d",tx,ty);
 $display("PASS: all 10 points scanned with synchronous coordinate RAM, point 10 nearest, key-edge focus uses newly selected room");$finish;
end
initial begin #1000000;$fatal(1,"navigation timeout");end
endmodule
