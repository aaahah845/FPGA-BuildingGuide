`ifndef BMP_DYNAMIC_READ_V
`define BMP_DYNAMIC_READ_V
// Sector-buffered 24-bit BI_RGB loader. Output rows are padded to four words,
// so SDRAM bursts cannot cross an unaligned row boundary. Geometry is held
// from header validation until completion/abort, ahead of write_req.
// 【说明】BMP 解析（sd_card_clk）：只支持 24 位未压缩 BI_RGB，宽 1~1024、高 1~600；
//         非地图资源必须为 640×480。stride 为宽度向上取整到 4 的倍数，行尾补 0。
module bmp_dynamic_read (
    input clk, rst, start, abort, allow_large, stream_ready,
    input [31:0] actual_file_size,
    output ready,
    output reg [3:0] error,
    output reg write_req,
    input write_ack,
    output reg [10:0] image_width, image_stride,
    output reg [9:0] image_height,
    output reg bottom_up,
    output reg [20:0] image_words, first_offset,
    output reg sector_req,
    output reg [31:0] sector,
    input [7:0] data,
    input valid, sector_end,
    output reg pixel_valid,
    output reg [23:0] pixel
);
    localparam IDLE = 0, FETCH = 1, SETTLE = 2, GEOM = 3, CHECK = 4, ACK = 5, READ_ADDR = 6, READ_WAIT = 7,
        BYTE = 8, PAD = 9, NEXT = 10, VALIDATE = 11, EXTENT = 12, HEADER_CHECK = 13, BOUNDS = 14;
    reg [3:0] state;
    reg [7:0] bytes[0:511];
    reg [8:0] wrpos, rdpos;
    reg [7:0] q;
    reg [31:0] width, height, offset, length, dib, compression;
    reg [15:0] magic, bpp, planes;
    reg header;
    reg [20:0] position;
    reg pixel_byte, row_last_byte;
    reg [12:0] pixel_start, row_last;
    // Only compute geometry after the full-width header has been validated.
    // Accepted images have <=3072 bytes/row and <=1843200 payload bytes.
    reg [12:0] row_bytes;
    reg [20:0] payload_end, payload_bytes;
    reg [12:0] row_byte, row_payload;
    reg [10:0] col;
    reg [9:0] row;
    reg [4:0] check_bad;
    reg [1:0] channel;
    wire [9:0] abs_height = height[31] ? (~height[9:0] + 10'd1) : height[9:0];
    wire height_bad = height[31] ? height < 32'hfffffda8 : (height == 0 || height > 600);
    reg [1:0] size_hi_less, size_hi_equal, size_lo_less;
    assign ready = state == IDLE;
    always @(posedge clk) begin
        if (state == FETCH && valid) bytes[wrpos] <= data;
        q <= bytes[rdpos];
    end
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= IDLE;
            error <= 0;
            write_req <= 0;
            sector_req <= 0;
            sector <= 0;
            wrpos <= 0;
            rdpos <= 0;
            width <= 0;
            height <= 0;
            offset <= 0;
            length <= 0;
            dib <= 0;
            compression <= 0;
            magic <= 0;
            bpp <= 0;
            planes <= 0;
            image_width <= 640;
            image_stride <= 640;
            image_height <= 480;
            bottom_up <= 1;
            image_words <= 307200;
            first_offset <= 306560;
            header <= 0;
            position <= 0;
            row_bytes <= 0;
            payload_end <= 0;
            payload_bytes <= 0;
            row_byte <= 0;
            row_payload <= 0;
            check_bad <= 0;
            col <= 0;
            row <= 0;
            channel <= 0;
            pixel_valid <= 0;
            pixel <= 0;
            size_hi_less <= 0;
            size_hi_equal <= 0;
            size_lo_less <= 0;
            pixel_byte <= 0;
            row_last_byte <= 0;
            pixel_start <= 0;
            row_last <= 0;
        end else if (abort) begin
            state <= IDLE;
            error <= 0;
            write_req <= 0;
            sector_req <= 0;
            pixel_valid <= 0;
        end else begin
            pixel_valid <= 0;
            case (state)
                IDLE:
                if (start) begin
                    error <= 0;
                    sector <= 0;
                    sector_req <= 1;
                    wrpos <= 0;
                    header <= 1;
                    state <= FETCH;
                    width <= 0;
                    height <= 0;
                    offset <= 0;
                    length <= 0;
                    dib <= 0;
                    compression <= 0;
                    magic <= 0;
                    bpp <= 0;
                    planes <= 0;
                end
                FETCH: begin
                    if (valid) begin
                        wrpos <= wrpos + 1'b1;
                        if (header)
                            case (wrpos)
                                0: magic[7:0] <= data;
                                1: magic[15:8] <= data;
                                2: length[7:0] <= data;
                                3: length[15:8] <= data;
                                4: length[23:16] <= data;
                                5: length[31:24] <= data;
                                10: offset[7:0] <= data;
                                11: offset[15:8] <= data;
                                12: offset[23:16] <= data;
                                13: offset[31:24] <= data;
                                14: dib[7:0] <= data;
                                15: dib[15:8] <= data;
                                16: dib[23:16] <= data;
                                17: dib[31:24] <= data;
                                18: width[7:0] <= data;
                                19: width[15:8] <= data;
                                20: width[23:16] <= data;
                                21: width[31:24] <= data;
                                22: height[7:0] <= data;
                                23: height[15:8] <= data;
                                24: height[23:16] <= data;
                                25: height[31:24] <= data;
                                26: planes[7:0] <= data;
                                27: planes[15:8] <= data;
                                28: bpp[7:0] <= data;
                                29: bpp[15:8] <= data;
                                30: compression[7:0] <= data;
                                31: compression[15:8] <= data;
                                32: compression[23:16] <= data;
                                33: compression[31:24] <= data;
                                default: ;
                            endcase
                    end
                    if (sector_end) begin
                        sector_req <= 0;
                        rdpos <= 0;
                        state <= header ? VALIDATE : READ_ADDR;
                    end
                end
                SETTLE: begin
                    image_width <= width[10:0];
                    image_height <= abs_height[9:0];
                    image_stride <= ((width[10:0] + 11'd3) >> 2) << 2;
                    bottom_up <= !height[31];
                    row_bytes <= ((width[10:0] * 13'd3 + 13'd3) >> 2) << 2;
                    row_payload <= width[10:0] * 13'd3;
                    state <= GEOM;
                end
                GEOM: begin
                    image_words <= image_stride * image_height;
                    first_offset <= image_stride * (image_height - 1'b1);
                    payload_bytes <= row_bytes * image_height;
                    state <= EXTENT;
                end
                EXTENT: begin
                    payload_end <= {8'd0, offset[12:0]} + payload_bytes;
                    pixel_start <= offset[12:0];
                    row_last <= row_bytes - 1'b1;
                    state <= BOUNDS;
                end
                VALIDATE: begin
                    check_bad[0] <= magic != 16'h4d42 || dib != 40 || planes != 1 || bpp != 24 ||
                        compression != 0;
                    check_bad[1] <= width < 1 || width > 1024 || height_bad ||
                        (!allow_large && (width != 640 || (height != 480 && height != 32'hfffffe20)));
                    check_bad[2] <= offset < 54 || offset > 4096;
                    check_bad[3] <= 0;
                    check_bad[4] <= 0;
                    state <= HEADER_CHECK;
                end
                HEADER_CHECK: begin
                    if (|check_bad) begin
                        error <= 10;
                        state <= IDLE;
                    end else state <= SETTLE;
                end
                BOUNDS: begin
                    // Split each 32-bit comparison across a register boundary. The high
                    // part includes the original file's full width, so truncation cannot
                    // turn a malformed header into an accepted image.
                    size_hi_less <= {
                        actual_file_size[31:11] < {11'd0, payload_end[20:11]},
                        length[31:11] < {11'd0, payload_end[20:11]}
                    };
                    size_hi_equal <= {
                        actual_file_size[31:11] == {11'd0, payload_end[20:11]},
                        length[31:11] == {11'd0, payload_end[20:11]}
                    };
                    size_lo_less <= {
                        actual_file_size[10:0] < payload_end[10:0], length[10:0] < payload_end[10:0]
                    };
                    state <= CHECK;
                end
                CHECK: begin
                    if (|(size_hi_less | (size_hi_equal & size_lo_less))) begin
                        error <= 10;
                        state <= IDLE;
                    end else begin
                        write_req <= 1;
                        state <= ACK;
                    end
                end
                ACK:
                if (write_ack) begin
                    write_req <= 0;
                    header <= 0;
                    position <= 0;
                    row_byte <= 0;
                    col <= 0;
                    row <= 0;
                    channel <= 0;
                    rdpos <= 0;
                    state <= READ_ADDR;
                end
                READ_ADDR: begin
                    pixel_byte <= position >= {8'd0, pixel_start};
                    row_last_byte <= row_byte == row_last;
                    state <= READ_WAIT;
                end
                READ_WAIT: state <= BYTE;
                BYTE:
                if (stream_ready) begin
                    position <= position + 1'b1;
                    rdpos <= rdpos + 1'b1;
                    state <= NEXT;
                    if (pixel_byte) begin
                        row_byte <= row_byte + 1'b1;
                        if (row_byte < row_payload) begin
                            case (channel)
                                0: pixel[7:0] <= q;
                                1: pixel[15:8] <= q;
                                2: begin
                                    pixel[23:16] <= q;
                                    pixel_valid <= 1;
                                    col <= col + 1'b1;
                                end
                            endcase
                            channel <= channel == 2 ? 0 : channel + 1'b1;
                        end
                        if (row_last_byte) begin
                            row_byte <= 0;
                            state <= PAD;
                        end
                    end
                end
                PAD:
                if (stream_ready) begin
                    if (col < image_stride) begin
                        pixel <= 0;
                        pixel_valid <= 1;
                        col <= col + 1'b1;
                    end else begin
                        col <= 0;
                        row <= row + 1'b1;
                        if (row == image_height - 1) state <= IDLE;
                        else state <= NEXT;
                    end
                end
                NEXT:
                if (rdpos == 0) begin
                    sector <= sector + 1'b1;
                    sector_req <= 1;
                    wrpos <= 0;
                    state <= FETCH;
                end else state <= READ_ADDR;
                default:   state <= IDLE;
            endcase
        end
    end
endmodule
`endif
