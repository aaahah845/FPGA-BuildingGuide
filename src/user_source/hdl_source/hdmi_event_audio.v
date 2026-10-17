`ifndef HDMI_EVENT_AUDIO_V
`define HDMI_EVENT_AUDIO_V
// 40 MHz probe: uninterrupted 48 kHz PCM and 1 kHz ACR, including silence.
// Events: 1=1000 Hz/80 ms; 2=750 Hz/120 ms; 3=500 Hz/160 ms.
// 【说明】48 kHz 节拍与 ACR（N=6144，CTS=40000）发生器，同时合成提示音：
//         事件 1/2/3 = 1000/750/500 Hz，持续 80/120/160 ms，带包络与音量。
module hdmi_event_audio (
    input clk, rst,
    input [1:0] event_code,
    input [3:0] volume,
    output reg audio_valid,
    output reg [23:0] left_data, right_data,
    output reg acr_valid,
    output [19:0] acr_n, acr_cts
);
    reg [25:0] sample_acc;
    wire [26:0] sum = {1'b0, sample_acc} + 27'd48000;
    reg [5:0] acr_count;
    reg [1:0] pending;
    reg playing;
    reg [12:0] remaining;
    reg [6:0] phase, period, quarter;
    reg [7:0] envelope;
    reg signed [23:0] wave, step;
    // Attenuate the common envelope, keeping the PCM/ACR cadence unchanged.
    wire [11:0] volume_product = envelope * volume;
    reg [7:0] audible_envelope;
    always @(posedge clk or posedge rst)
        if (rst) audible_envelope <= 0;
        else audible_envelope <= volume_product[10:3];
    wire signed [32:0] product = wave * $signed({1'b0, audible_envelope});
    wire signed [32:0] scaled = product >>> 8;
    assign acr_n = 6144;
    assign acr_cts = 40000;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            sample_acc <= 0;
            acr_count <= 0;
            pending <= 0;
            playing <= 0;
            remaining <= 0;
            phase <= 0;
            period <= 48;
            quarter <= 12;
            envelope <= 0;
            wave <= 0;
            step <= 21845;
            audio_valid <= 0;
            left_data <= 0;
            right_data <= 0;
            acr_valid <= 0;
        end else begin
            audio_valid <= 0;
            acr_valid <= 0;
            if (sum >= 40000000) begin
                sample_acc <= sum - 40000000;
                audio_valid <= 1;
                if (acr_count == 47) begin
                    acr_count <= 0;
                    acr_valid <= 1;
                end else acr_count <= acr_count + 1'b1;
                left_data <= playing ? scaled[23:0] : 24'd0;
                right_data <= playing ? scaled[23:0] : 24'd0;
                if (pending != 0 && (!playing || envelope == 0)) begin
                    playing <= 1;
                    phase <= 0;
                    wave <= 0;
                    envelope <= 0;
                    pending <= 0;
                    case (pending)
                        1: begin
                            remaining <= 3840;
                            period <= 48;
                            quarter <= 12;
                            step <= 21845;
                        end
                        2: begin
                            remaining <= 5760;
                            period <= 64;
                            quarter <= 16;
                            step <= 16384;
                        end
                        default: begin
                            remaining <= 7680;
                            period <= 96;
                            quarter <= 24;
                            step <= 10922;
                        end
                    endcase
                end else if (playing) begin
                    if (phase == period - 1) phase <= 0;
                    else phase <= phase + 1'b1;
                    if (phase < quarter || phase >= period - quarter) wave <= wave + step;
                    else wave <= wave - step;
                    if (remaining != 0) remaining <= remaining - 1'b1;
                    if (pending != 0 || remaining <= 256) begin
                        if (envelope != 0) envelope <= envelope - 1'b1;
                        else begin
                            playing <= 0;
                            wave <= 0;
                        end
                    end else if (envelope != 255) envelope <= envelope + 1'b1;
                end
            end else sample_acc <= sum[25:0];
            // Latest event wins; do not lose a new pulse on the consumption clock.
            if (event_code != 0) pending <= event_code;
        end
    end
endmodule
`endif
