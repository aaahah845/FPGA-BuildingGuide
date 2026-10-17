// 【说明】外接按键提示，仅使用发布版现有字形，每条最多 18 个 16 点字。
// SW3 返回也可用外接 RST；SET 打开参数面板的功能保留，完整说明见 README。
function [6:0] message_char;
input [3:0] message;
input [5:0] position;
begin
message_char=0;
case(message)
4'd0: case(position) // 右布局 上选择 左切图 长左轮播
6'd0: message_char=7'd112;
6'd1: message_char=7'd106;
6'd2: message_char=7'd107;
6'd3: message_char=7'd0;
6'd4: message_char=7'd13;
6'd5: message_char=7'd65;
6'd6: message_char=7'd66;
6'd7: message_char=7'd0;
6'd8: message_char=7'd111;
6'd9: message_char=7'd69;
6'd10: message_char=7'd35;
6'd11: message_char=7'd0;
6'd12: message_char=7'd40;
6'd13: message_char=7'd111;
6'd14: message_char=7'd45;
6'd15: message_char=7'd46;
default: message_char=0;
endcase
4'd1: case(position) // 下选择 中详情 长左轮播
6'd0: message_char=7'd20;
6'd1: message_char=7'd65;
6'd2: message_char=7'd66;
6'd3: message_char=7'd0;
6'd4: message_char=7'd39;
6'd5: message_char=7'd18;
6'd6: message_char=7'd19;
6'd7: message_char=7'd0;
6'd8: message_char=7'd40;
6'd9: message_char=7'd111;
6'd10: message_char=7'd45;
6'd11: message_char=7'd46;
default: message_char=0;
endcase
4'd2: case(position) // 占用
6'd0: message_char=7'd25;
6'd1: message_char=7'd26;
default: message_char=0;
endcase
4'd3: case(position) // 空闲
6'd0: message_char=7'd27;
6'd1: message_char=7'd28;
default: message_char=0;
endcase
4'd4: case(position) // 上楼层 中切 左选择
6'd0: message_char=7'd13;
6'd1: message_char=7'd49;
6'd2: message_char=7'd50;
6'd3: message_char=7'd0;
6'd4: message_char=7'd39;
6'd5: message_char=7'd69;
6'd6: message_char=7'd0;
6'd7: message_char=7'd111;
6'd8: message_char=7'd65;
6'd9: message_char=7'd66;
default: message_char=0;
endcase
4'd5: case(position) // 占用时间
6'd0: message_char=7'd25;
6'd1: message_char=7'd26;
6'd2: message_char=7'd32;
6'd3: message_char=7'd33;
default: message_char=0;
endcase
4'd6: case(position) // 左列表 上楼层
6'd0: message_char=7'd111;
6'd1: message_char=7'd61;
6'd2: message_char=7'd62;
6'd3: message_char=7'd0;
6'd4: message_char=7'd13;
6'd5: message_char=7'd49;
6'd6: message_char=7'd50;
default: message_char=0;
endcase
4'd7: case(position) // 图片准备中
6'd0: message_char=7'd35;
6'd1: message_char=7'd36;
6'd2: message_char=7'd37;
6'd3: message_char=7'd38;
6'd4: message_char=7'd39;
default: message_char=0;
endcase
4'd8: case(position) // 右选择 中详情 长左移动
6'd0: message_char=7'd112;
6'd1: message_char=7'd65;
6'd2: message_char=7'd66;
6'd3: message_char=7'd0;
6'd4: message_char=7'd39;
6'd5: message_char=7'd18;
6'd6: message_char=7'd19;
6'd7: message_char=7'd0;
6'd8: message_char=7'd40;
6'd9: message_char=7'd111;
6'd10: message_char=7'd113;
6'd11: message_char=7'd114;
default: message_char=0;
endcase
4'd9: case(position) // 轮播
6'd0: message_char=7'd45;
6'd1: message_char=7'd46;
default: message_char=0;
endcase
4'd10: case(position) // 开
6'd0: message_char=7'd47;
default: message_char=0;
endcase
4'd11: case(position) // 关
6'd0: message_char=7'd48;
default: message_char=0;
endcase
4'd12: case(position) // 楼层
6'd0: message_char=7'd49;
6'd1: message_char=7'd50;
default: message_char=0;
endcase
4'd13: case(position) // 秒
6'd0: message_char=7'd51;
default: message_char=0;
endcase
4'd14: case(position) // SW3返回 长下修改占用
6'd0: message_char=7'd14;
6'd1: message_char=7'd15;
6'd2: message_char=7'd4;
6'd3: message_char=7'd21;
6'd4: message_char=7'd22;
6'd5: message_char=7'd0;
6'd6: message_char=7'd40;
6'd7: message_char=7'd20;
6'd8: message_char=7'd43;
6'd9: message_char=7'd44;
6'd10: message_char=7'd25;
6'd11: message_char=7'd26;
default: message_char=0;
endcase
4'd15: case(position) // 上下左右移动 长左选择 长右缩放
6'd0: message_char=7'd13;
6'd1: message_char=7'd20;
6'd2: message_char=7'd111;
6'd3: message_char=7'd112;
6'd4: message_char=7'd113;
6'd5: message_char=7'd114;
6'd6: message_char=7'd0;
6'd7: message_char=7'd40;
6'd8: message_char=7'd111;
6'd9: message_char=7'd65;
6'd10: message_char=7'd66;
6'd11: message_char=7'd0;
6'd12: message_char=7'd40;
6'd13: message_char=7'd112;
6'd14: message_char=7'd54;
6'd15: message_char=7'd52;
default: message_char=0;
endcase
default: message_char=0;
endcase
end
endfunction
