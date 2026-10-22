`timescale 1ns/1ps

// 【历史遗留】本文件中只有 guide_button_debounce 仍被使用（方向键与拨码消抖）；
// guide_key_control 模块本身已不在层次中，下面的说明对应旧版 25 MHz 工程。
// Smart floor-guide key handling in the 25 MHz video clock domain.
//
// Board mapping used by top:
//   K2: next floor
//   K3: next room
//   K4 short press: toggle activity slideshow
//   K4 long press: toggle occupancy of the selected room
//
// K1 remains the active-low system reset and is not handled here.
module guide_key_control #(
    parameter integer CLK_FREQ_HZ   = 25_000_000,
    parameter integer DEBOUNCE_MS   = 10,
    parameter integer LONG_PRESS_MS = 800
)(
    input  wire       clk,
    input  wire       rst,
    input  wire       key_floor_n,
    input  wire       key_room_n,
    input  wire       key_auto_occ_n,

    output reg  [1:0] floor_idx,
    output reg  [1:0] selected_room_idx,
    output reg  [8:0] room_occupied,
    output reg        auto_toggle_pulse,
    output reg        occupancy_toggle_pulse
);

localparam integer LONG_PRESS_CYCLES =
    (CLK_FREQ_HZ / 1000) * LONG_PRESS_MS;

wire floor_press_pulse;
wire room_press_pulse;
wire auto_occ_pressed;
wire auto_occ_press_pulse;
wire auto_occ_release_pulse;

reg [31:0] long_press_cnt;
reg        long_press_fired;

guide_button_debounce #(
    .CLK_FREQ_HZ (CLK_FREQ_HZ),
    .DEBOUNCE_MS (DEBOUNCE_MS)
) u_floor_button (
    .clk          (clk),
    .rst          (rst),
    .button_n     (key_floor_n),
    .pressed      (),
    .press_pulse  (floor_press_pulse),
    .release_pulse()
);

guide_button_debounce #(
    .CLK_FREQ_HZ (CLK_FREQ_HZ),
    .DEBOUNCE_MS (DEBOUNCE_MS)
) u_room_button (
    .clk          (clk),
    .rst          (rst),
    .button_n     (key_room_n),
    .pressed      (),
    .press_pulse  (room_press_pulse),
    .release_pulse()
);

guide_button_debounce #(
    .CLK_FREQ_HZ (CLK_FREQ_HZ),
    .DEBOUNCE_MS (DEBOUNCE_MS)
) u_auto_occ_button (
    .clk          (clk),
    .rst          (rst),
    .button_n     (key_auto_occ_n),
    .pressed      (auto_occ_pressed),
    .press_pulse  (auto_occ_press_pulse),
    .release_pulse(auto_occ_release_pulse)
);

always @(posedge clk or posedge rst) begin
    if (rst) begin
        floor_idx               <= 2'd0;
        selected_room_idx       <= 2'd0;
        room_occupied           <= 9'd0;
        auto_toggle_pulse       <= 1'b0;
        occupancy_toggle_pulse  <= 1'b0;
        long_press_cnt          <= 32'd0;
        long_press_fired        <= 1'b0;
    end else begin
        auto_toggle_pulse      <= 1'b0;
        occupancy_toggle_pulse <= 1'b0;

        // A floor change returns the selection to the first room.  Occupancy
        // bits are deliberately retained while moving between floors.
        if (floor_press_pulse) begin
            if (floor_idx == 2'd2)
                floor_idx <= 2'd0;
            else
                floor_idx <= floor_idx + 2'd1;
            selected_room_idx <= 2'd0;
        end else if (room_press_pulse) begin
            if (selected_room_idx == 2'd2)
                selected_room_idx <= 2'd0;
            else
                selected_room_idx <= selected_room_idx + 2'd1;
        end

        // K4 short/long gesture separation.  A long action fires once while
        // held; releasing it cannot also generate the short action.
        if (auto_occ_press_pulse) begin
            long_press_cnt   <= 32'd0;
            long_press_fired <= 1'b0;
        end else if (auto_occ_pressed && !long_press_fired) begin
            if ((LONG_PRESS_CYCLES <= 1) ||
                (long_press_cnt >= LONG_PRESS_CYCLES - 1)) begin
                long_press_fired       <= 1'b1;
                occupancy_toggle_pulse <= 1'b1;

                case ({floor_idx, selected_room_idx})
                    4'b00_00: room_occupied[0] <= ~room_occupied[0];
                    4'b00_01: room_occupied[1] <= ~room_occupied[1];
                    4'b00_10: room_occupied[2] <= ~room_occupied[2];
                    4'b01_00: room_occupied[3] <= ~room_occupied[3];
                    4'b01_01: room_occupied[4] <= ~room_occupied[4];
                    4'b01_10: room_occupied[5] <= ~room_occupied[5];
                    4'b10_00: room_occupied[6] <= ~room_occupied[6];
                    4'b10_01: room_occupied[7] <= ~room_occupied[7];
                    4'b10_10: room_occupied[8] <= ~room_occupied[8];
                    default: ;
                endcase
            end else begin
                long_press_cnt <= long_press_cnt + 32'd1;
            end
        end else if (!auto_occ_pressed) begin
            long_press_cnt <= 32'd0;
            if (auto_occ_release_pulse && !long_press_fired)
                auto_toggle_pulse <= 1'b1;
        end
    end
end

endmodule


// Active-low button synchronizer/debouncer with one-cycle edge events.
module guide_button_debounce #(
    parameter integer CLK_FREQ_HZ = 25_000_000,
    parameter integer DEBOUNCE_MS = 10,
    parameter integer USE_MS_TICK = 0
)(
    input  wire clk,
    input  wire rst,
    input  wire button_n,
    input  wire ms_tick,
    output wire pressed,
    output reg  press_pulse,
    output reg  release_pulse
);

localparam integer DEBOUNCE_CYCLES =
    USE_MS_TICK ? DEBOUNCE_MS+1 : (CLK_FREQ_HZ / 1000) * DEBOUNCE_MS;
wire advance_count = !USE_MS_TICK || ms_tick;

reg sync_0;
reg sync_1;
reg stable_n;
// At 40 MHz / 10 ms only 19 bits are required, for each of seven inputs.
localparam integer DEBOUNCE_BITS = DEBOUNCE_CYCLES <= 1 ? 1 : $clog2(DEBOUNCE_CYCLES);
reg [DEBOUNCE_BITS-1:0] debounce_cnt;

assign pressed = ~stable_n;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        sync_0       <= 1'b1;
        sync_1       <= 1'b1;
        stable_n     <= 1'b1;
        debounce_cnt <= 32'd0;
        press_pulse  <= 1'b0;
        release_pulse<= 1'b0;
    end else begin
        sync_0        <= button_n;
        sync_1        <= sync_0;
        press_pulse   <= 1'b0;
        release_pulse <= 1'b0;

        if (sync_1 == stable_n) begin
            debounce_cnt <= 32'd0;
        end else if (advance_count && ((DEBOUNCE_CYCLES <= 1) ||
                     (debounce_cnt >= DEBOUNCE_CYCLES - 1))) begin
            stable_n     <= sync_1;
            debounce_cnt <= 32'd0;
            if (stable_n && !sync_1)
                press_pulse <= 1'b1;
            else if (!stable_n && sync_1)
                release_pulse <= 1'b1;
        end else if (advance_count) begin
            debounce_cnt <= debounce_cnt + 32'd1;
        end
    end
end

endmodule
