`ifndef HELD_BUS_CDC_V
`define HELD_BUS_CDC_V
// Producer holds data through the consumer's acknowledgement (or for a whole
// video frame). The event has an extra synchronizer stage before capturing data.
// 【说明】保持型总线跨域：源端数据在 toggle 翻转前保持不变，目标端同步 toggle 后再采样数据。
module held_bus_cdc #(
    parameter WIDTH=1
)(
    input clk,rst,
    input async_toggle,
    input [WIDTH-1:0] async_data,
    output reg event_toggle,
    output reg [WIDTH-1:0] data
);
(* ASYNC_REG="TRUE" *) reg [2:0] toggle_sync;
(* ASYNC_REG="TRUE" *) reg [WIDTH-1:0] bus_meta;
reg [WIDTH-1:0] bus_sync;
always @(posedge clk or posedge rst) begin
    if(rst) begin
        toggle_sync<=0;
        bus_meta<=0;
        bus_sync<=0;
        event_toggle<=0;
        data<=0;
    end else begin
        toggle_sync<={toggle_sync[1:0],async_toggle};
        bus_meta<=async_data;
        bus_sync<=bus_meta;
        if(toggle_sync[2]!=event_toggle) begin
            event_toggle<=toggle_sync[2];
            data<=bus_sync;
        end
    end
end
endmodule
`endif
