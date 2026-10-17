`ifndef GUIDE_NAV_BUTTONS_V
`define GUIDE_NAV_BUTTONS_V
`timescale 1ns / 1ps
// Three momentary contacts complement the four existing directional gestures.
// A contact must be released after reset/boot before it can issue a command.
// Hold and release never repeat a command. Board switches keep both-edge use.
// 【说明】外接五向模块的 MID/SET/RST：消抖后产生单拍事件；上电后必须先松开一次才生效。
module guide_nav_buttons #(
    parameter integer CLK_FREQ_HZ = 40_000_000,
    parameter integer DEBOUNCE_MS = 10,
    parameter integer USE_MS_TICK = 0
) (
    input wire clk, rst, enable, ms_tick,
    input wire [2:0] buttons_n,  // [0] MID, [1] SET, [2] RST
    output wire [3:0] events
);
    // Share the millisecond divider instead of three full-width debounce
    // counters. N+1 sample ticks guarantee at least N complete milliseconds
    // of stable input, independently of the divider phase.
    localparam integer TICK_CYCLES = CLK_FREQ_HZ / 1000 > 0 ? CLK_FREQ_HZ / 1000 : 1;
    localparam integer TICK_BITS = TICK_CYCLES > 1 ? $clog2(TICK_CYCLES) : 1;
    localparam integer STABLE_TICKS = DEBOUNCE_MS + 1;
    localparam integer COUNT_BITS = STABLE_TICKS > 1 ? $clog2(STABLE_TICKS + 1) : 1;
    wire sample_tick;
    generate
        if (USE_MS_TICK) begin : shared_tick
            assign sample_tick = ms_tick;
        end else begin : local_tick
            reg [TICK_BITS-1:0] tick_count;
            assign sample_tick = tick_count == TICK_CYCLES - 1;
            always @(posedge clk or posedge rst)
                if (rst) tick_count <= 0;
                else tick_count <= sample_tick ? 0 : tick_count + 1'b1;
        end
    endgenerate
    (* ASYNC_REG="TRUE" *) reg [2:0] buttons_meta_n, buttons_sync_n;
    reg [2:0] stable_n;
    wire [2:0] press;
    reg [2:0] armed;
    always @(posedge clk or posedge rst)
        if (rst) begin
            buttons_meta_n <= 3'b111;
            buttons_sync_n <= 3'b111;
        end else begin
            buttons_meta_n <= buttons_n;
            buttons_sync_n <= buttons_meta_n;
        end
    genvar k;
    generate
        for (k = 0; k < 3; k = k + 1) begin : contact
            reg [COUNT_BITS-1:0] stable_count;
            assign press[k] = sample_tick && !buttons_sync_n[k] && stable_n[k] &&
                stable_count == STABLE_TICKS - 1;
            always @(posedge clk or posedge rst)
                if (rst) begin
                    stable_count <= 0;
                    stable_n[k] <= 1;
                end else if (buttons_sync_n[k] == stable_n[k]) stable_count <= 0;
                else if (sample_tick) begin
                    if (stable_count == STABLE_TICKS - 1) begin
                        stable_n[k] <= buttons_sync_n[k];
                        stable_count <= 0;
                    end else stable_count <= stable_count + 1'b1;
                end
            always @(posedge clk or posedge rst)
                if (rst) armed[k] <= 0;
                else if (!enable) armed[k] <= 0;
                else if (press[k]) armed[k] <= 0;
                else if (stable_n[k]) armed[k] <= 1;
        end
    endgenerate
    assign events = enable ? {press[0] & armed[0], press[2] & armed[2], 1'b0, press[1] & armed[1]} : 4'b0;
endmodule
`endif
