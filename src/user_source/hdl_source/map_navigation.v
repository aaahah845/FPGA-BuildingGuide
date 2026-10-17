`ifndef MAP_NAVIGATION_V
`define MAP_NAVIGATION_V
// Coordinates are original BMP pixels. Centres use half-pixel units so an
// odd-sized map is centred without discarding its last column/row.
// ============================================================================
// map_navigation：地图缩放、平移、选点跟随与最近点（video_clk）
//
// 坐标：源图像素；中心与目标用“半像素”单位（*_x2），奇数尺寸也能居中。
// 缩放：step 为 Q12 定点“每个输出像素前进多少源像素”。
//   fit_step = max(宽/640, 高/480)，不小于 1.0（4096）；
//   三档 level 0/1/2 = fit、fit×2/3（约 1.5 倍）、fit/2（2 倍）。
//   ÷3 与求 scale=1/step 都用 calc 状态机逐位移位相除，避免组合大除法器。
// 平移：每次按键目标移动 128 半像素（64 源像素），限制在 min/max 之内；
//   中心每帧向目标走剩余距离的 1/4（向上取整），形成减速靠近。
// 最近点：scan_state 逐个观察点计算距离平方，1 个乘法器先算 X 后算 Y，
//   10 个点约 50 拍。扫描中视野变化会作废本次结果重扫。
// 输出 select_valid/select_room 仅在平移模式（scan_select）下有效。
// ============================================================================
module map_navigation (
    input clk, rst, available,
    input [10:0] width,
    input [9:0] height,
    input [1:0] floor_id,
    input [3:0] room_count,
    output wire [3:0] point_index,
    input [9:0] point_x, point_y,
    input frame_request, zoom_press, zoom_reset, left_press, right_press, up_press, down_press, focus_press,
    input [3:0] selected_room,
    output reg [1:0] level,
    output reg [13:0] step, scale,
    output reg [11:0] center_x2,
    output reg [10:0] center_y2,
    output reg [11:0] target_x2,
    output reg [10:0] target_y2,
    output reg select_valid,
    output reg [3:0] select_room,
    output reg nearest_valid,
    output reg [3:0] nearest_room
);
    reg [10:0] old_w;
    reg [9:0] old_h;
    reg [1:0] old_floor;
    reg [3:0] calc;
    reg [23:0] ratio_x, ratio_y;
    reg [13:0] fit_step, next_step;
    reg [24:0] dividend;
    reg [14:0] remainder;
    reg [24:0] quotient;
    reg [4:0] bit_count;
    // Compute ceil(2*fit/3) serially; an unsized /3 on the pixel clock
    // otherwise infers a wide combinational divider.
    reg [15:0] third_bits, third_quotient;
    reg [1:0] third_rem;
    reg [3:0] third_count;
    wire [2:0] third_trial = {third_rem, third_bits[15]};
    wire [15:0] trial = {remainder, dividend[24]};
    wire changed = available && (width != old_w || height != old_h || floor_id != old_floor);
    reg [23:0] half_view_x, half_view_y;
    reg [11:0] min_x, max_x;
    reg [10:0] min_y, max_y;
    reg focus_d, focus_pending;
    reg [2:0] scan_state;
    reg [3:0] scan_room, best_room;
    reg [24:0] best_distance;
    reg scan_pending, scan_select;
    reg signed [12:0] delta;
    reg [24:0] square, x_square;
    reg point_valid;
    assign point_index = (focus_press || focus_d || focus_pending) ? selected_room : scan_room;
    wire [9:0] px = point_x, py = point_y;
    wire [25:0] distance = {1'b0, x_square} + {1'b0, square};
    // A single pipelined multiplier serves X then Y. Fifty clocks scan all
    // ten points, well within a video frame; no parallel distance DSP is needed.
    always @(posedge clk) square <= delta * delta;
    wire [10:0] focus_x = {point_x, 1'b0};
    wire [10:0] focus_y = {point_y, 1'b0};
    reg frame_d;
    wire moving = center_x2 != target_x2 || center_y2 != target_y2;
    wire [11:0] gap_x = center_x2 < target_x2 ? target_x2 - center_x2 : center_x2 - target_x2;
    wire [10:0] gap_y = center_y2 < target_y2 ? target_y2 - center_y2 : center_y2 - target_y2;
    // One quarter of the remaining distance per frame, rounded up. No divider
    // or multiplier is needed; the final half-pixel step reaches the exact target.
    wire [11:0] move_x = (gap_x >> 2) + (|gap_x[1:0]);
    wire [10:0] move_y = (gap_y >> 2) + (|gap_y[1:0]);
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            level <= 0;
            step <= 4096;
            scale <= 4096;
            center_x2 <= 640;
            center_y2 <= 480;
            target_x2 <= 640;
            target_y2 <= 480;
            frame_d <= 0;
            half_view_x <= 2621440;
            half_view_y <= 1966080;
            min_x <= 640;
            max_x <= 640;
            min_y <= 480;
            max_y <= 480;
            old_w <= 0;
            old_h <= 0;
            old_floor <= 0;
            calc <= 0;
            ratio_x <= 0;
            ratio_y <= 0;
            fit_step <= 4096;
            next_step <= 4096;
            dividend <= 0;
            remainder <= 0;
            quotient <= 0;
            bit_count <= 0;
            focus_d <= 0;
            focus_pending <= 0;
            third_bits <= 0;
            third_quotient <= 0;
            third_rem <= 0;
            third_count <= 0;
            scan_state <= 0;
            scan_room <= 0;
            best_room <= 0;
            best_distance <= 25'h1ffffff;
            delta <= 0;
            x_square <= 0;
            point_valid <= 0;
            select_valid <= 0;
            select_room <= 0;
            scan_pending <= 0;
            scan_select <= 0;
            nearest_valid <= 0;
            nearest_room <= 0;
        end else begin
            select_valid <= 0;
            focus_d <= focus_press;
            frame_d <= frame_request;
            if (focus_press) focus_pending <= 1;
            if (zoom_press) focus_pending <= 0;
            if (changed || (available && zoom_reset)) begin
                old_w <= width;
                old_h <= height;
                old_floor <= floor_id;
                level <= 0;
                calc <= 1;
                center_x2 <= width;
                center_y2 <= height;
                target_x2 <= width;
                target_y2 <= height;
                scan_state <= 0;
                nearest_valid <= 0;
                scan_pending <= 1;
                scan_select <= 0;
            end else if (available && zoom_press && calc == 0) begin
                level <= level == 2 ? 0 : level + 1'b1;
                calc <= 1;
                center_x2 <= width;
                center_y2 <= height;
                target_x2 <= width;
                target_y2 <= height;
                scan_state <= 0;
                nearest_valid <= 0;
                scan_pending <= 1;
                scan_select <= 0;
            end else
                case (calc)
                    1: begin
                        ratio_x <= ({width, 12'b0} + 639) / 640;
                        ratio_y <= ({height, 12'b0} + 479) / 480;
                        calc <= 2;
                    end
                    2: begin
                        fit_step <= ratio_x >= ratio_y ?
                            (ratio_x < 4096 ? 4096 : ratio_x) : (ratio_y < 4096 ? 4096 : ratio_y);
                        calc <= 3;
                    end
                    3: begin
                        calc <= 4;
                        case (level)
                            0: next_step <= fit_step;
                            1: begin
                                third_bits <= {1'b0, fit_step, 1'b0} + 16'd2;
                                third_quotient <= 0;
                                third_rem <= 0;
                                third_count <= 15;
                                calc <= 7;
                            end
                            default: next_step <= ({1'b0, fit_step} + 15'd1) >> 1;
                        endcase
                    end
                    7: begin
                        third_bits <= third_bits << 1;
                        third_quotient <= {third_quotient[14:0], third_trial >= 3'd3};
                        third_rem <= third_trial >= 3'd3 ? third_trial - 3'd3 : third_trial;
                        if (third_count == 0) calc <= 8;
                        else third_count <= third_count - 1'b1;
                    end
                    8: begin
                        next_step <= third_quotient[13:0];
                        calc <= 4;
                    end
                    4: begin
                        dividend <= 25'd16777216;
                        quotient <= 0;
                        remainder <= 0;
                        bit_count <= 24;
                        calc <= 5;
                    end
                    5: begin
                        dividend <= dividend << 1;
                        quotient <= {quotient[23:0], trial >= next_step};
                        remainder <= trial >= next_step ? trial - next_step : trial;
                        if (bit_count == 0) calc <= 6;
                        else bit_count <= bit_count - 1'b1;
                    end
                    6: begin
                        step <= next_step;
                        scale <= quotient[13:0];
                        calc <= 9;
                    end
                    9: begin
                        half_view_x <= ({next_step, 9'd0} + {next_step, 7'd0});
                        half_view_y <= ({next_step, 9'd0} - {next_step, 5'd0});
                        calc <= 10;
                    end
                    10: begin
                        min_x <= (half_view_x >> 12) >= width ? {1'b0, width} : half_view_x >> 12;
                        min_y <= (half_view_y >> 12) >= height ? {1'b0, height} : half_view_y >> 12;
                        calc <= 11;
                    end
                    11: begin
                        max_x <= {width, 1'b0} - min_x;
                        max_y <= {height, 1'b0} - min_y;
                        calc <= 0;
                    end
                    default: ;
                endcase
            if (available && !changed && !zoom_reset && calc == 0 && !zoom_press) begin
                if (focus_d) begin
                    // Allow the new room selection to reach the registered coordinate port.
                end else if (focus_pending) begin
                    focus_pending <= 0;
                    target_x2 <= focus_x < min_x ? min_x : focus_x > max_x ? max_x : focus_x;
                    target_y2 <= focus_y < min_y ? min_y : focus_y > max_y ? max_y : focus_y;
                    scan_state <= 0;
                    nearest_valid <= 0;
                    scan_pending <= 1;
                    scan_select <= 0;
                end else if (left_press || right_press || up_press || down_press) begin
                    if (left_press) target_x2 <= target_x2 < min_x + 128 ? min_x : target_x2 - 128;
                    else if (right_press) target_x2 <= target_x2 + 128 > max_x ? max_x : target_x2 + 128;
                    if (up_press) target_y2 <= target_y2 < min_y + 128 ? min_y : target_y2 - 128;
                    else if (down_press) target_y2 <= target_y2 + 128 > max_y ? max_y : target_y2 + 128;
                    scan_state <= 0;
                    nearest_valid <= 0;
                    scan_pending <= 1;
                    scan_select <= 1;
                end else if (moving && frame_request && !frame_d) begin
                    center_x2 <= center_x2 < target_x2 ? center_x2 + move_x : center_x2 - move_x;
                    center_y2 <= center_y2 < target_y2 ? center_y2 + move_y : center_y2 - move_y;
                    scan_state <= 0;
                    scan_pending <= 1;
                    nearest_valid <= 0;
                end else if (scan_pending) begin
                    // Scan the current centre between frame updates. A frame update above
                    // cancels any unfinished scan before changing the centre, so a result
                    // can never combine distances from different viewport positions.
                    scan_state <= 1;
                    scan_room <= 0;
                    best_distance <= 25'h1ffffff;
                    best_room <= 0;
                    scan_pending <= 0;
                end else
                    case (scan_state)
                        1: scan_state <= 2;
                        2: begin
                            delta <= $signed({2'b0, px, 1'b0}) - $signed({1'b0, center_x2});
                            point_valid <= px < width && py < height;
                            scan_state <= 3;
                        end
                        3: begin
                            delta <= $signed({2'b0, py, 1'b0}) - $signed({2'b0, center_y2});
                            scan_state <= 4;
                        end
                        4: begin
                            x_square <= square;
                            scan_state <= 5;
                        end
                        5: begin
                            if (point_valid && distance < best_distance) begin
                                best_distance <= distance;
                                best_room <= scan_room;
                            end
                            if (scan_room + 1 >= room_count) begin
                                nearest_valid <= room_count != 0 && ((point_valid && distance < best_distance)
                                                                     || best_distance != 25'h1ffffff);
                                nearest_room <= point_valid && distance < best_distance ? scan_room :
                                    best_room;
                                select_valid <= scan_select && room_count != 0 &&
                                    ((point_valid && distance < best_distance) ||
                                     best_distance != 25'h1ffffff);
                                select_room <= point_valid && distance < best_distance ? scan_room :
                                    best_room;
                                scan_state <= 0;
                            end else begin
                                scan_room <= scan_room + 1'b1;
                                scan_state <= 1;
                            end
                        end
                        default: ;
                    endcase
            end
            if (!available) begin
                nearest_valid <= 0;
                scan_state <= 0;
                scan_pending <= 1;
                scan_select <= 0;
            end
        end
    end
endmodule
`endif
