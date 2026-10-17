`timescale 1ns / 1ps

// Assert reset asynchronously, then release it only on the destination clock.
// 【说明】跨域工具：reset_sync 异步置位、同步释放；pulse_cdc 用 toggle 把单拍脉冲送到目标域。
module reset_sync #(
    parameter integer STAGES = 3
) (
    input  wire clk,
    input  wire async_reset,
    output wire reset_out
);

    (* ASYNC_REG = "TRUE", max_fanout = 64 *) reg [STAGES-1:0] reset_pipe;

    always @(posedge clk or posedge async_reset) begin
        if (async_reset) reset_pipe <= {STAGES{1'b1}};
        else reset_pipe <= {reset_pipe[STAGES-2:0], 1'b0};
    end

    assign reset_out = reset_pipe[STAGES-1];

endmodule

// A final reset distribution stage after reset_sync. Assertion is immediate;
// release is on the falling edge, leaving half a cycle before rising-edge
// consumers resume. This does not replace the asynchronous-input synchronizer.
module reset_release_leaf #(
    parameter integer WIDTH = 1
) (
    input wire clk,
    input wire reset_in,
    output wire [WIDTH-1:0] reset_out
);

    (* preserve *) reg [WIDTH-1:0] release_reg;
    always @(negedge clk or posedge reset_in) begin
        if (reset_in) release_reg <= {WIDTH{1'b1}};
        else release_reg <= {WIDTH{1'b0}};
    end
    assign reset_out = release_reg;

endmodule

// Convert a source-domain pulse into one destination-domain pulse by using a
// synchronized toggle.  Source events must be separated by at least three
// destination clock cycles.
module pulse_cdc (
    input  wire src_clk,
    input  wire src_reset,
    input  wire src_pulse,
    input  wire dst_clk,
    input  wire dst_reset,
    output wire dst_pulse
);

    reg src_toggle;
    (* ASYNC_REG = "TRUE" *) reg [2:0] dst_sync;

    always @(posedge src_clk or posedge src_reset) begin
        if (src_reset) src_toggle <= 1'b0;
        else if (src_pulse) src_toggle <= ~src_toggle;
    end

    always @(posedge dst_clk or posedge dst_reset) begin
        if (dst_reset) dst_sync <= 3'b000;
        else dst_sync <= {dst_sync[1:0], src_toggle};
    end

    assign dst_pulse = dst_sync[2] ^ dst_sync[1];

endmodule
