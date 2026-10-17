`ifndef SD_DUAL_AUDIO_V
`define SD_DUAL_AUDIO_V
`include "sd_wav_player.v"
`include "audio_mix_fifo.v"
// Independent music and prompt file cursors. Mix one sector from each into
// the existing two-page output memory; prompts never reopen MUSIC.WAV.
// 【说明】双路 WAV（sd_card_clk）：通道 0 背景音乐 MUSIC.WAV，通道 1 语音/提示。
//         每轮先写一页音乐，再把语音读出相加后写回同一页，整页完成后才发布给 HDMI 侧。
module sd_dual_audio (
    input clk, rst, ready, music_on,
    input [3:0] event_code,
    output [1:0] fallback_event,
    output [3:0] error,
    output context_select, want, file_open, file_abort,
    output [87:0] file_name,
    input fs_idle, open_done, open_ok,
    input [31:0] file_size,
    input [3:0] fs_error,
    output file_req,
    output [31:0] file_sector,
    input [7:0] file_data,
    input file_valid, file_end,
    input audio_clk, audio_rst, take,
    output available,
    output [15:0] sample
);
    reg [1:0] phase;
    reg [2:0] settle;
    reg [8:0] music_count, total_count;
    reg publish;
    wire full, empty;
    wire [1:0] wants, opens, aborts, reqs, writes, pubs, playing;
    wire [87:0] names[0:1];
    wire [31:0] sectors[0:1];
    wire [7:0] indices[0:1];
    wire [15:0] samples[0:1];
    wire [8:0] counts[0:1];
    wire [1:0] fallback[0:1];
    wire [3:0] errors[0:1];
    wire selected = phase == 1;
    wire ui_mix = event_code != 0 && event_code <= 3 && (music_on || playing[1]);
    wire [3:0] prompt_event = ui_mix ? 4'd0 : event_code;
    reg [1:0] ui_tone;
    always @(posedge clk or posedge rst)
        if (rst) ui_tone <= 0;
        else ui_tone <= ui_mix ? event_code[1:0] : 0;
    assign fallback_event = ui_tone != 0 ? ui_tone : fallback[1];
    assign error = errors[1] != 0 ? errors[1] : errors[0];
    assign context_select = selected;
    assign want = phase < 2 && wants[selected];
    assign file_open = phase < 2 && opens[selected];
    assign file_abort = phase < 2 && aborts[selected];
    assign file_name = names[selected];
    assign file_req = phase < 2 && reqs[selected];
    assign file_sector = sectors[selected];
    genvar g;
    generate
        for (g = 0; g < 2; g = g + 1) begin : channels
            sd_wav_player player (
                .clk(clk),
                .rst(rst),
                .ready(ready),
                .music_on(g == 0 ? music_on : 1'b0),
                .event_code(g == 0 ? 4'd0 : prompt_event),
                .fallback_event(fallback[g]),
                .error(errors[g]),
                .busy(playing[g]),
                .want(wants[g]),
                .file_open(opens[g]),
                .file_abort(aborts[g]),
                .file_name(names[g]),
                .fs_idle(fs_idle && phase == g),
                .open_done(open_done && phase == g),
                .open_ok(open_ok),
                .file_size(file_size),
                .fs_error(phase == g ? fs_error : 4'd0),
                .file_req(reqs[g]),
                .file_sector(sectors[g]),
                .file_data(file_data),
                .file_valid(file_valid && phase == g),
                .file_end(file_end && phase == g),
                .fifo_full(full || phase != g),
                .fifo_empty(1'b1),
                .sample_write(writes[g]),
                .sample_index(indices[g]),
                .sample_data(samples[g]),
                .publish(pubs[g]),
                .publish_count(counts[g])
            );
        end
    endgenerate
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            phase <= 0;
            settle <= 0;
            music_count <= 0;
            total_count <= 0;
            publish <= 0;
        end else begin
            publish <= 0;
            case (phase)
                0: begin
                    if (pubs[0]) begin
                        music_count <= counts[0];
                        total_count <= counts[0];
                        if (playing[1] || prompt_event != 0) phase <= 1;
                        else begin
                            phase <= 2;
                            settle <= 0;
                        end
                    end else if ((!music_on || errors[0] != 0) && !playing[0]) begin
                        music_count <= 0;
                        total_count <= 0;
                        phase <= 1;
                    end
                end
                1: begin
                    if (pubs[1]) begin
                        total_count <= counts[1] > music_count ? counts[1] : music_count;
                        phase <= 2;
                        settle <= 0;
                    end else if (!playing[1] && prompt_event == 0) begin
                        if (music_count != 0) begin
                            phase <= 2;
                            settle <= 0;
                        end else phase <= 0;
                    end
                end
                2:
                if (settle == 7) begin
                    publish <= total_count != 0;
                    phase <= 3;
                end else settle <= settle + 1'b1;
                3: begin
                    phase <= 0;
                    music_count <= 0;
                    total_count <= 0;
                end
            endcase
        end
    end
    audio_mix_fifo fifo (
        .wclk(clk),
        .wrst(rst),
        .write_en((writes[0] && phase == 0) || (writes[1] && phase == 1)),
        .write_index(indices[selected]),
        .write_sample(samples[selected]),
        .mix_write(selected),
        .music_count(music_count),
        .publish(publish),
        .publish_count(total_count),
        .full(full),
        .empty_write(empty),
        .rclk(audio_clk),
        .rrst(audio_rst),
        .take(take),
        .available(available),
        .sample(sample)
    );
endmodule
`endif
