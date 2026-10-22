`ifndef AUDIO_OUTPUT_MIXER_V
`define AUDIO_OUTPUT_MIXER_V
// PCM cadence never depends on SD latency. Empty audio pages contribute zero.
// 【说明】输出混音（video_clk）：SD 样本 × 音量 + 合成提示音，饱和到 24 位后送 HDMI。
module audio_output_mixer(
    input clk,rst,
    input tick,acr_tick,
    input [23:0] tone_left,tone_right,
    input available,
    input [15:0] sample,
    input [3:0] volume,
    output reg pcm_valid,acr_valid,
    output reg [23:0] left_data,right_data
);
wire signed [20:0] gain=$signed(sample)*$signed({1'b0,volume});
wire signed [26:0] sd_value=available?($signed({{6{gain[20]}},gain})<<<5):27'sd0;
wire signed [26:0] left_sum=sd_value+$signed({{3{tone_left[23]}},tone_left});
wire signed [26:0] right_sum=sd_value+$signed({{3{tone_right[23]}},tone_right});
function[23:0] clip;
    input signed [26:0] v;
    begin
        if(v>27'sd8388607) clip=24'h7fffff;
        else if(v< -27'sd8388608) clip=24'h800000;
        else clip=v[23:0];
    end
endfunction
always @(posedge clk or posedge rst) begin
    if(rst) begin
        pcm_valid<=0;
        acr_valid<=0;
        left_data<=0;
        right_data<=0;
    end else begin
        pcm_valid<=tick;
        acr_valid<=acr_tick;
        if(tick) begin
            left_data<=clip(left_sum);
            right_data<=clip(right_sum);
        end
    end
end
endmodule
`endif
