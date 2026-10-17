// Use all 800x600 pixels for the scene; no outer canvas cropping.
// Latency = video_delay (21) + runtime guide compositor (6).
// 【说明】画布对齐：把 HS/VS/DE 延迟 27 拍（= video_delay 21 + 合成器 6），与合成像素对齐。
module ui_viewport_800 #(
    parameter LATENCY = 27
) (
    input clk, rst, hs, vs, de,
    input [23:0] ui_rgb,
    input ui_de,
    output window_de,
    output canvas_hs, canvas_vs, canvas_de,
    output [23:0] canvas_rgb
);
    reg [9:0] x, y;
    reg de_d, vs_d;
    reg [LATENCY-1:0] hs_pipe, vs_pipe, de_pipe;
    assign window_de = de;
    assign canvas_hs = hs_pipe[LATENCY-1];
    assign canvas_vs = vs_pipe[LATENCY-1];
    assign canvas_de = de_pipe[LATENCY-1];
    assign canvas_rgb = ui_de ? ui_rgb : 24'he9edf4;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            x <= 0;
            y <= 0;
            de_d <= 0;
            vs_d <= 0;
            hs_pipe <= 0;
            vs_pipe <= 0;
            de_pipe <= 0;
        end else begin
            de_d <= de;
            vs_d <= vs;
            hs_pipe <= {hs_pipe[LATENCY-2:0], hs};
            vs_pipe <= {vs_pipe[LATENCY-2:0], vs};
            de_pipe <= {de_pipe[LATENCY-2:0], de};
            if (vs_d && !vs) begin
                x <= 0;
                y <= 0;
            end else if (!de) begin
                x <= 0;
                if (de_d) y <= y == 599 ? 0 : y + 1'b1;
            end else if (x < 799) x <= x + 1'b1;
        end
    end
endmodule
