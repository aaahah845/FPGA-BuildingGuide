`ifndef AUDIO_SPECTRUM_OVERLAY_V
`define AUDIO_SPECTRUM_OVERLAY_V
`include "audio_spectrum_engine.v"
// Real-time 64-band spectrum in the unchanged 256x24 region (528,540).
// Frequency is quasi-logarithmic; amplitude uses a 3 dB/pixel fixed scale.
// 【说明】频谱叠加（原名 audio_waveform_overlay）：绘制 64 频带频谱柱，位于 (528,540)，256×24。
//         每帧取一次 audio_spectrum_engine 的结果，下降时每帧最多降 1 像素。
module audio_spectrum_overlay (
    input clk, rst, enabled,
    input [7:0] panel_height,
    input pcm_valid,
    input signed [23:0] pcm_left,
    input in_vs, in_de,
    input [23:0] in_rgb,
    output reg out_vs, out_de,
    output reg [23:0] out_rgb
);
    wire result_valid, published_bank;
    wire [4:0] level_value;
    wire [6:0] level_address;
    audio_spectrum_engine spectrum (
        .clk(clk),
        .rst(rst),
        .pcm_valid(pcm_valid),
        .pcm_left(pcm_left),
        .level_address(level_address),
        .level_value(level_value),
        .published_bank(published_bank),
        .result_valid(result_valid)
    );
    (* syn_ramstyle="distributed_ram" *) reg [4:0] heights[0:63];
    reg smooth_busy, heights_valid, have_result, snapshot_bank, snapshot_valid;
    reg [5:0] smooth_index;
    assign level_address = {snapshot_bank, smooth_index};
    wire [5:0] bar_index;
    wire [5:0] height_addr = smooth_busy ? smooth_index : bar_index;
    wire [4:0] height_read = heights[height_addr];
    wire [4:0] target_height = snapshot_valid ? level_value : 5'd0;
    wire [4:0]
        next_height = !heights_valid || target_height >= height_read ? target_height : height_read - 1'b1;
    always @(posedge clk) if (smooth_busy) heights[smooth_index] <= next_height;
    reg [9:0] x, y;
    reg vs_d, de_d, enabled_frame;
    reg [4:0] alpha_frame, alpha1, height1;
    wire [4:0] alpha = panel_height >= 208 ? 8 :
        panel_height >= 182 ? 9 : panel_height >= 156 ? 10 : panel_height >= 130 ? 11 : panel_height >= 104 ?
        12 : panel_height >= 78 ? 13 : panel_height >= 52 ? 14 : panel_height >= 26 ? 15 : 16;
    function [7:0] dim;
        input [7:0] v;
        input [4:0] a;
        reg [12:0] product;
        begin
            product = v * a;
            dim = product >> 4;
        end
    endfunction
    assign bar_index = x[7:2] - 6'd4;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            x <= 0;
            y <= 0;
            vs_d <= 0;
            de_d <= 0;
            enabled_frame <= 0;
            alpha_frame <= 16;
            smooth_busy <= 0;
            smooth_index <= 0;
            heights_valid <= 0;
            have_result <= 0;
            snapshot_bank <= 0;
            snapshot_valid <= 0;
        end else begin
            vs_d <= in_vs;
            de_d <= in_de;
            if (result_valid) have_result <= 1;
            if (in_vs != vs_d) begin
                x <= 0;
                y <= 0;
            end else begin
                if (in_de) x <= x + 1'b1;
                else x <= 0;
                if (de_d && !in_de) y <= y + 1'b1;
            end
            if (in_vs && !vs_d) begin
                enabled_frame <= enabled;
                alpha_frame <= alpha;
                smooth_busy <= 1;
                smooth_index <= 0;
                snapshot_bank <= published_bank;
                snapshot_valid <= have_result;
            end else if (smooth_busy) begin

                if (smooth_index == 63) begin
                    smooth_busy <= 0;
                    heights_valid <= 1;
                end else smooth_index <= smooth_index + 1'b1;

            end
        end
    end
    reg [23:0] rgb1;
    reg vs1, de1, inside1;
    reg [4:0] local_y1;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            rgb1 <= 0;
            vs1 <= 0;
            de1 <= 0;
            inside1 <= 0;
            local_y1 <= 0;
            alpha1 <= 16;
            height1 <= 0;
            out_rgb <= 0;
            out_vs <= 0;
            out_de <= 0;
        end else begin
            rgb1 <= in_rgb;
            vs1 <= in_vs;
            de1 <= in_de;
            inside1 <= enabled_frame && in_de && x >= 528 && x < 784 && y >= 540 && y < 564 &&
                heights_valid && !smooth_busy && x[1:0] != 3;
            local_y1 <= y - 10'd540;
            alpha1 <= alpha_frame;
            height1 <= height_read;
            out_vs <= vs1;
            out_de <= de1;
            out_rgb <= rgb1;
            if (inside1 && height1 != 0 && local_y1 >= 24 - height1)
                out_rgb <= {dim(8'h81, alpha1), dim(8'h8a, alpha1), dim(8'h98, alpha1)};
        end
    end
endmodule
`endif
