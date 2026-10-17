`ifndef HELD_BUS_CDC_V
`define HELD_BUS_CDC_V
// ============================================================================
// held_bus_cdc：保持型参数邮箱的接收端，clk/rst 属于目的时钟域。
// 源端发布整组 async_data 并翻转 async_toggle；数据保持至该邮箱的应答/裁决结束。
// bus_meta/bus_sync 两级采样数据，toggle_sync 三级同步通知；检测到通知变化时，
// 统一锁存 bus_sync 并更新 event_toggle。本模块只接收，发送端保持和返回应答由外层连接。
// ============================================================================
module held_bus_cdc #(
    parameter WIDTH = 1
) (
    input clk, rst,
    input async_toggle,
    input [WIDTH-1:0] async_data,
    output reg event_toggle,
    output reg [WIDTH-1:0] data
);
    (* ASYNC_REG="TRUE" *) reg [2:0] toggle_sync;
    (* ASYNC_REG="TRUE" *) reg [WIDTH-1:0] bus_meta;
    reg [WIDTH-1:0] bus_sync;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            toggle_sync <= 0;
            bus_meta <= 0;
            bus_sync <= 0;
            event_toggle <= 0;
            data <= 0;
        end else begin
            toggle_sync <= {toggle_sync[1:0], async_toggle};
            bus_meta <= async_data;
            bus_sync <= bus_meta;
            if (toggle_sync[2] != event_toggle) begin
                event_toggle <= toggle_sync[2];
                data <= bus_sync;
            end
        end
    end
endmodule
`endif
