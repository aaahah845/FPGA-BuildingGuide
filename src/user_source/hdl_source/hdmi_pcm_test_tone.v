// 【未使用】早期 25 MHz 测试音源，已由 hdmi_event_audio.v 取代。
// 仍保留在工程文件列表中，综合时不会进入设计层次；阅读当前设计可跳过本文件。
`ifndef HDMI_PCM_TEST_TONE_V
`define HDMI_PCM_TEST_TONE_V
// 25 MHz pixel clock only. 48 kHz stereo, signed 24-bit PCM.
// 1 kHz triangle, peak 262140 / 8388607 (about -30 dBFS).
// ACR: N=6144, CTS=25000; 48 samples span exactly 25000 clocks.
module hdmi_pcm_test_tone(
 input clk,rst,
 output reg audio_valid,
 output reg[23:0] left_data,right_data,
 output reg acr_valid,
 output wire[19:0] acr_n,acr_cts);
 reg[24:0] sample_acc;
 wire[25:0] sample_sum={1'b0,sample_acc}+26'd48000;
 reg[5:0] phase;
 reg signed[23:0] sample;
 assign acr_n=20'd6144;
 assign acr_cts=20'd25000;
 always @(posedge clk or posedge rst)begin
 if(rst)begin
 sample_acc<=0;phase<=0;sample<=0;
 audio_valid<=0;left_data<=0;right_data<=0;acr_valid<=0;
 end else begin
 audio_valid<=0;acr_valid<=0;
 if(sample_sum>=26'd25000000)begin
 sample_acc<=sample_sum-26'd25000000;
 audio_valid<=1;left_data<=sample;right_data<=sample;
 if(phase<12 || phase>=36)sample<=sample+24'sd21845;
 else sample<=sample-24'sd21845;
 if(phase==47)begin phase<=0;acr_valid<=1;end
 else phase<=phase+1'b1;
 end else sample_acc<=sample_sum[24:0];
 end end
endmodule
`endif
