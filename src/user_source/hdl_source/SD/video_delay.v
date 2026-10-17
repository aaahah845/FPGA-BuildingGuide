// ============================================================================
// video_delay：按视频扫描节奏读取 FIFO，并对齐基础像素与 HS/VS/DE。
// hs_d/vs_d/de_d 为 21 位移位寄存器；read_en 取 de_d[18]，
// de_d[19] 有效时锁存 read_data，同步输出取 [20]。后续合成器的流水线延迟
// 由其内部同步寄存器配套；本模块负责进入合成器之前的 FIFO 读延迟。
// ============================================================================
module video_delay #(
    parameter DATA_WIDTH = 24  // Video data one clock data width
) (
    input                     video_clk,  // Video pixel clock
    input                     rst,
    output                    read_en,    // Read data enable
    input  [DATA_WIDTH - 1:0] read_data,  // Read data
    input                     hs,         // horizontal synchronization
    input                     vs,         // vertical synchronization
    input                     de,         // video valid

    output                    hs_r,      // horizontal synchronization
    output                    vs_r,      // vertical synchronization
    output                    de_r,      // video valid
    output [DATA_WIDTH - 1:0] vout_data  // video data

);
    reg [20:0] hs_d;
    reg [20:0] vs_d;
    reg [20:0] de_d;
    reg [DATA_WIDTH - 1:0] vout_data_r;

    assign read_en = de_d[18];
    assign hs_r = hs_d[20];
    assign vs_r = vs_d[20];
    assign de_r = de_d[20];
    assign vout_data = vout_data_r;
    always @(posedge video_clk or posedge rst) begin
        if (rst == 1'b1) vout_data_r <= {DATA_WIDTH{1'b0}};
        else if (de_d[19]) vout_data_r <= read_data;
        else vout_data_r <= {DATA_WIDTH{1'b0}};
    end
    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            hs_d <= 20'b0;
            vs_d <= 20'b0;
            de_d <= 20'b0;
        end else begin

            hs_d <= {hs_d[19:0], hs};
            vs_d <= {vs_d[19:0], vs};
            de_d <= {de_d[19:0], de};
        end
    end
endmodule
