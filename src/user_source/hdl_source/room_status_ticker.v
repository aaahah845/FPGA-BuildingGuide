`ifndef ROOM_STATUS_TICKER_V
`define ROOM_STATUS_TICKER_V
// One shared updater services all rooms in vertical blanking. Keep the RAM
// free of reset logic so TD can infer compact storage with a registered read and a shared update cycle.
// 【说明】房间状态文字的滚动相位，在消隐期统一更新。
module room_status_ticker (
    input clk, rst, frame_tick,
    input [29:0] occupied,
    input [3:0] first_room,
    input [1:0] floor_idx,
    input [3:0] room_idx,
    output reg [41:0] visible_phase,
    output reg [5:0] selected_phase
);
    (* syn_ramstyle="block_ram" *)
        reg [13:0] state[0:31];  // phase[13:8], divide-by-three[7:6], readable pause[5:0]
    reg initializing, busy, frame_pending;
    reg [4:0] scan, floor_base, selected;
    reg [29:0] active, previous_active, new_active;
    reg [13:0] old;
    reg update_cycle;
    always @(posedge clk) old <= state[scan];
    wire [5:0] pause_frames = 6'd12 + {scan, 1'b0};
    reg [13:0] next_value;
    always @* begin
        next_value = old;
        if (initializing || !active[scan] || new_active[scan]) next_value = {8'd0, pause_frames};
        else if (old[5:0] != 0) next_value = {old[13:6], old[5:0] - 6'd1};
        else if (old[7:6] == 2)
            next_value = {old[13:8] + 6'd1, 2'd0, (old[13:8] == 63 ? pause_frames : 6'd0)};
        else next_value = {old[13:8], old[7:6] + 2'd1, 6'd0};
    end
    always @(posedge clk) if (busy && update_cycle) state[scan] <= next_value;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            initializing <= 1;
            busy <= 1;
            update_cycle <= 0;
            frame_pending <= 0;
            scan <= 0;
            floor_base <= 0;
            selected <= 0;
            active <= 0;
            previous_active <= 0;
            new_active <= 0;
            visible_phase <= 0;
            selected_phase <= 0;
        end else begin
            if (busy && !update_cycle) update_cycle <= 1;
            if (busy && update_cycle) begin
                update_cycle <= 0;
                if (!initializing) begin
                    if (scan == floor_base) visible_phase[5:0] <= next_value[13:8];
                    if (scan == floor_base + 1) visible_phase[11:6] <= next_value[13:8];
                    if (scan == floor_base + 2) visible_phase[17:12] <= next_value[13:8];
                    if (scan == floor_base + 3) visible_phase[23:18] <= next_value[13:8];
                    if (scan == floor_base + 4) visible_phase[29:24] <= next_value[13:8];
                    if (scan == floor_base + 5) visible_phase[35:30] <= next_value[13:8];
                    if (scan == floor_base + 6) visible_phase[41:36] <= next_value[13:8];
                    if (scan == selected) selected_phase <= next_value[13:8];
                end
                if (scan == 29) begin
                    busy <= 0;
                    initializing <= 0;
                    scan <= 0;
                end else scan <= scan + 1'b1;
            end
            if (frame_tick) begin
                active <= occupied;
                new_active <= occupied & ~previous_active;
                previous_active <= occupied;
                floor_base <= ({floor_idx, 3'b0} + {floor_idx, 1'b0}) + first_room;
                selected <= ({floor_idx, 3'b0} + {floor_idx, 1'b0}) + room_idx;
                if (initializing) frame_pending <= 1;
                else begin
                    scan <= 0;
                    busy <= 1;
                    update_cycle <= 0;
                    frame_pending <= 0;
                end
            end else if (frame_pending && !initializing && !busy) begin
                scan <= 0;
                busy <= 1;
                update_cycle <= 0;
                frame_pending <= 0;
            end
        end
    end
endmodule
`endif
