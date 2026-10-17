`ifndef SD_WAV_PLAYER_V
`define SD_WAV_PLAYER_V
// Canonical 44-byte PCM WAV: 48 kHz / signed 16-bit / mono. Conversion tool
// emits this exact format. Invalid/missing prompt files request synthesized
// fallback; invalid music stops until the user switches music off and on.
// 【说明】WAV 播放器：逐字节校验 44 字节文件头（48 kHz、单声道、16 位），按扇区读样本。
//         提示音文件缺失或格式错误时，通过 fallback_event 请求合成提示音。
module sd_wav_player (
    input clk, rst, ready, music_on,
    input [3:0] event_code,
    output reg [1:0] fallback_event,
    output reg [3:0] error,
    output busy,
    output want,
    output reg file_open,
    output file_abort,
    output [87:0] file_name,
    input fs_idle, open_done, open_ok,
    input [31:0] file_size,
    input [3:0] fs_error,
    output reg file_req,
    output reg [31:0] file_sector,
    input [7:0] file_data,
    input file_valid, file_end,
    input fifo_full, fifo_empty,
    output reg sample_write,
    output reg [7:0] sample_index,
    output reg [15:0] sample_data,
    output reg publish,
    output reg [8:0] publish_count
);
    localparam IDLE = 0, DRAIN = 1, OPEN = 2, OPEN_WAIT = 3, SPACE = 4, READ = 5, GAP = 6, GAP2 = 7, DONE = 8,
        ABORT = 9, ABORT_WAIT = 10;
    reg [3:0] state;
    reg [3:0] pending, kind;
    reg music_failed, music_d;
    reg [8:0] byte_pos;
    reg [8:0] samples;
    reg header_bad, format_ok;
    reg [7:0] low_byte;
    reg [31:0] payload_left, expected_data, expected_riff;
    reg [23:0] data_length_low;
    wire interrupted = pending != 0 || (kind == 0 && !music_on);
    assign busy = state != IDLE || !fifo_empty;
    assign want = state == OPEN || state == OPEN_WAIT || state == READ || state == ABORT ||
        state == ABORT_WAIT || (state == SPACE && !fifo_full);
    assign file_abort = state == ABORT;
    assign file_name = kind == 1 ? "UI1     WAV" : kind == 2 ? "UI2     WAV" :
        kind == 3 ? "UI3     WAV" : kind == 4 ? "FLOOR1  WAV" : kind == 5 ? "FLOOR2  WAV" :
        kind == 6 ? "FLOOR3  WAV" : kind == 7 ? "MAP     WAV" : kind == 8 ? "INDEX   WAV" : "MUSIC   WAV";
    wire [1:0] kind_fallback = kind >= 4 ? 2'd1 : kind[1:0];
    // Validate every mandatory header byte, including byte rate/block alignment.
    reg [7:0] expected;
    reg checked;
    always @* begin
        checked = 1;
        expected = 0;
        case (byte_pos)
            0: expected = "R";
            1: expected = "I";
            2: expected = "F";
            3: expected = "F";
            4: expected = expected_riff[7:0];
            5: expected = expected_riff[15:8];
            6: expected = expected_riff[23:16];
            7: expected = expected_riff[31:24];
            8: expected = "W";
            9: expected = "A";
            10: expected = "V";
            11: expected = "E";
            12: expected = "f";
            13: expected = "m";
            14: expected = "t";
            15: expected = " ";
            16: expected = 16;
            20: expected = 1;
            22: expected = 1;
            24: expected = 8'h80;
            25: expected = 8'hbb;
            28: expected = 8'h00;
            29: expected = 8'h77;
            30: expected = 8'h01;
            32: expected = 2;
            34: expected = 16;
            36: expected = "d";
            37: expected = "a";
            38: expected = "t";
            39: expected = "a";
            40, 41, 42, 43: checked = 0;
            default: if (byte_pos >= 44) checked = 0;
        endcase
    end
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= IDLE;
            pending <= 0;
            kind <= 0;
            music_failed <= 0;
            music_d <= 0;
            fallback_event <= 0;
            error <= 0;
            file_open <= 0;
            file_req <= 0;
            file_sector <= 0;
            byte_pos <= 0;
            samples <= 0;
            header_bad <= 0;
            format_ok <= 0;
            low_byte <= 0;
            payload_left <= 0;
            expected_data <= 0;
            expected_riff <= 0;
            data_length_low <= 0;
            sample_write <= 0;
            sample_index <= 0;
            sample_data <= 0;
            publish <= 0;
            publish_count <= 0;
        end else begin
            music_d <= music_on;
            if (!music_on) music_failed <= 0;
            file_open <= 0;
            sample_write <= 0;
            publish <= 0;
            fallback_event <= 0;
            case (state)
                IDLE:
                if (ready) begin
                    if (pending != 0) begin
                        kind <= pending;
                        pending <= 0;
                        state <= DRAIN;
                    end else if (music_on && !music_failed) begin
                        kind <= 0;
                        state <= DRAIN;
                    end
                end
                DRAIN:
                if (interrupted) state <= IDLE;
                else if (fifo_empty && ready) begin
                    state <= OPEN;
                    error <= 0;
                end
                OPEN:
                if (fs_idle) begin
                    file_open <= 1;
                    state <= OPEN_WAIT;
                end
                OPEN_WAIT:
                if (open_done) begin
                    if (!open_ok || file_size < 46 || file_size[0]) begin
                        error <= !open_ok ? 4'd1 : 4'd2;
                        if (kind != 0) fallback_event <= kind_fallback;
                        else music_failed <= 1;
                        state <= ABORT;
                    end else begin
                        file_sector <= 0;
                        header_bad <= 0;
                        format_ok <= 0;
                        payload_left <= 0;
                        expected_data <= file_size - 44;
                        expected_riff <= file_size - 8;
                        state <= SPACE;
                    end
                end
                SPACE:
                if (interrupted) state <= ABORT;
                else if (!fifo_full && fs_idle) begin
                    byte_pos <= 0;
                    samples <= 0;
                    file_req <= 1;
                    state <= READ;
                end
                READ: begin
                    if (file_valid) begin
                        byte_pos <= byte_pos + 1'b1;
                        if (file_sector == 0 && byte_pos < 44) begin
                            if (checked && file_data != expected) header_bad <= 1;
                            case (byte_pos)
                                40: data_length_low[7:0] <= file_data;
                                41: data_length_low[15:8] <= file_data;
                                42: data_length_low[23:16] <= file_data;
                                43: begin
                                    if (header_bad || {file_data, data_length_low} != expected_data)
                                        header_bad <= 1;
                                    else begin
                                        format_ok <= 1;
                                        payload_left <= expected_data;
                                    end
                                end
                                default: ;
                            endcase
                        end else if (format_ok && payload_left != 0) begin
                            payload_left <= payload_left - 1'b1;
                            if (!byte_pos[0]) low_byte <= file_data;
                            else begin
                                sample_write <= 1;
                                sample_index <= samples[7:0];
                                sample_data <= {file_data, low_byte};
                                samples <= samples + 1'b1;
                            end
                        end
                    end
                    if (file_end) begin
                        file_req <= 0;
                        if (header_bad || !format_ok) begin
                            error <= 2;
                            if (kind != 0) fallback_event <= kind_fallback;
                            else music_failed <= 1;
                            state <= ABORT;
                        end else begin
                            if (samples != 0) begin
                                publish <= 1;
                                publish_count <= samples;
                            end
                            state <= GAP;
                        end
                    end else if (fs_error != 0) begin
                        file_req <= 0;
                        error <= 3;
                        if (kind != 0) fallback_event <= kind_fallback;
                        else music_failed <= 1;
                        state <= ABORT;
                    end
                end
                GAP: state <= GAP2;
                GAP2:
                if (interrupted) state <= ABORT;
                else if (payload_left == 0) state <= DONE;
                else begin
                    file_sector <= file_sector + 1'b1;
                    state <= SPACE;
                end
                DONE: if (fifo_empty || interrupted) state <= IDLE;
                ABORT: begin
                    file_req <= 0;
                    state <= ABORT_WAIT;
                end
                ABORT_WAIT: if (fs_idle) state <= IDLE;
                default: state <= IDLE;
            endcase
            // Simple UI cues mix as synthesized tones while speech is playing/pending.
            // They must not truncate a floor/page announcement. New speech is latest-wins.
            if (event_code != 0 && event_code <= 8) begin
                if (event_code <= 3 && ((kind >= 4 && state != IDLE) || pending >= 4))
                    fallback_event <= event_code[1:0];
                else pending <= event_code;
            end
        end
    end
endmodule
`endif
