`ifndef ROOM_ELAPSED_STORE_V
`define ROOM_ELAPSED_STORE_V
// Two small RAM copies provide independent timer and display reads. No RAM
// reset network: valid bits make every room read as zero after reset.
// A one-second update takes 60 clocks (1.5 us at 40 MHz); an occupancy
// change has write priority and removes that room from the pending snapshot.
// 【说明】占用计时：每秒给所有占用房间加 1（BCD，最大 99:59），切换占用时清零。
module room_elapsed_store (
    input clk, rst, second_tick,
    input [29:0] occupied,
    input clear_valid,
    input [4:0] clear_room, read_room,
    output [15:0] elapsed
);
    (* ram_style="bram" *) reg [15:0] timer_words[0:31];
    (* ram_style="bram" *) reg [15:0] display_words[0:31];
    reg [15:0] timer_q, display_q;
    reg [29:0] valid, pending;
    reg timer_valid_q, display_valid_q, active, phase;
    reg [4:0] cursor;
    function [15:0] next_second;
        input [15:0] b;
        begin
            if (b == 16'h9959) next_second = b;
            else if (b[3:0] != 9) next_second = b + 16'h0001;
            else if (b[7:4] != 5) next_second = b + 16'h0007;
            else if (b[11:8] != 9) next_second = b + 16'h00a7;
            else next_second = b + 16'h06a7;
        end
    endfunction
    wire writing = !rst && (clear_valid || (active && phase && pending[cursor] && !second_tick));
    wire [4:0] write_room = clear_valid ? clear_room : cursor;
    wire [15:0] write_data = clear_valid ? 16'd0 : next_second(timer_valid_q ? timer_q : 16'd0);
    always @(posedge clk) begin
        if (writing) begin
            timer_words[write_room] <= write_data;
            display_words[write_room] <= write_data;
        end
        timer_q <= timer_words[cursor];
        display_q <= display_words[read_room];
    end
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            valid <= 0;
            pending <= 0;
            timer_valid_q <= 0;
            display_valid_q <= 0;
            active <= 0;
            phase <= 0;
            cursor <= 0;
        end else begin
            timer_valid_q <= valid[cursor];
            display_valid_q <= read_room < 30 && valid[read_room];
            if (writing) valid[write_room] <= 1;
            if (second_tick) begin
                pending <= occupied;
                cursor <= 0;
                active <= 1;
                phase <= 0;
            end  // Clearing another room temporarily owns the sole write port. Retry the
                 // pending increment next clock so a simultaneous key event loses no tick.
            else if (active && (!phase || !clear_valid || clear_room == cursor)) begin
                phase <= !phase;
                if (phase) begin
                    if (cursor == 29) active <= 0;
                    else cursor <= cursor + 1'b1;
                end
            end
            if (clear_valid) pending[clear_room] <= 0;
        end
    end
    assign elapsed = display_valid_q ? display_q : 16'd0;
endmodule
`endif
