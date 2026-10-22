`ifndef SITE_POINT_MEMORY_V
`define SITE_POINT_MEMORY_V
// Canonical 30-record coordinate table. One registered read, one complete write.
// 【说明】观察点坐标表：30 个点的 (x,y)，由 SITE.CFG 写入，一个寄存读端口。
module site_point_memory(
    input clk,
    input cfg_we,
    input [12:0] cfg_addr,
    input [7:0] cfg_data,
    input [4:0] read_index,
    output wire [9:0] point_x,point_y
);
(* syn_ramstyle="block_ram" *) reg [17:0] points[0:31];
// Only two high bits need flip-flops; the 18-bit body fits one EG4 BRAM.
reg [31:0] point_hi0,point_hi1;
reg [9:0] write_x;
reg [7:0] write_y;
reg [19:0] read_q;
wire [4:0] write_index=(cfg_addr-13'd320)>>4;
always @(posedge clk) begin
    if(cfg_we && cfg_addr>=320 && cfg_addr<800) case(cfg_addr[3:0])
        2:write_x[7:0]<=cfg_data;
        3:write_x[9:8]<=cfg_data[1:0];
        4:write_y<=cfg_data;
        5: begin
            points[write_index]<={write_y,write_x};
            point_hi0[write_index]<=cfg_data[0];
            point_hi1[write_index]<=cfg_data[1];
        end
        default:;
    endcase
    read_q<={point_hi1[read_index],point_hi0[read_index],points[read_index]};
end
assign point_x=read_q[9:0];
assign point_y=read_q[19:10];
endmodule
`endif
