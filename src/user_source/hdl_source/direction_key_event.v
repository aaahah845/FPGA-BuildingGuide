`ifndef DIRECTION_KEY_EVENT_V
`define DIRECTION_KEY_EVENT_V
// Release-to-click prevents a long press from first taking a short action.
// 【说明】方向键手势：短按在松开时触发；长按满 LONG_PRESS_MS 触发一次；cancel 作废当前手势。
module direction_key_event #(
    parameter CLK_FREQ_HZ = 40000000,
    DEBOUNCE_MS = 10,
    LONG_PRESS_MS = 800,
    LONG_ENABLE = 1,
    USE_MS_TICK = 0
) (
    input  clk, rst, button_n, cancel,
    input  ms_tick,
    output short_event, long_event,
    output held
);
    localparam N = USE_MS_TICK ? LONG_PRESS_MS : (CLK_FREQ_HZ / 1000) * LONG_PRESS_MS;
    localparam W = $clog2(N + 1) > 0 ? $clog2(N + 1) : 1;
    wire advance_count = !USE_MS_TICK || ms_tick;
    wire press, release_key;
    reg armed, fired;
    reg [W-1:0] count;
    guide_button_debounce #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ),
        .DEBOUNCE_MS(DEBOUNCE_MS),
        .USE_MS_TICK(USE_MS_TICK)
    ) db (
        .clk(clk),
        .rst(rst),
        .button_n(button_n),
        .ms_tick(ms_tick),
        .pressed(held),
        .press_pulse(press),
        .release_pulse(release_key)
    );
    assign long_event = LONG_ENABLE && armed && !fired && held && count >= N - 1 && !cancel && advance_count;
    assign short_event = armed && !fired && release_key && !cancel;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            armed <= 0;
            fired <= 0;
            count <= 0;
        end else if (cancel) begin
            armed <= 0;
            fired <= 1;
            count <= 0;
        end else if (press) begin
            armed <= 1;
            fired <= 0;
            count <= 0;
        end else if (release_key) armed <= 0;
        else if (held && armed && !fired && LONG_ENABLE && advance_count) begin
            if (long_event) fired <= 1;
            else count <= count + 1'b1;
        end
    end
endmodule
`endif
