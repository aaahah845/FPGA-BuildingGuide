`ifndef UI_SETTINGS_OVERLAY_V
`define UI_SETTINGS_OVERLAY_V
// Independent final video stage. It consumes no SDRAM slot or SD resource.
// Four registered stages keep text, colour and DE/VS aligned at 40 MHz.
// 【说明】参数面板叠加（video_clk）：亮度、音量、频谱开关、音乐开关、采样方式。
module ui_settings_overlay(
    input clk,rst,
    input in_vs,in_de,
    input [23:0] in_rgb,
    input bilinear_enabled,
    input settings_open,spectrum_enabled,
    input [1:0] settings_field,
    input music_enabled,music_error,
    input [3:0] brightness,volume,
    output reg out_vs,out_de,
    output reg [23:0] out_rgb
);
reg [9:0] x,y;
reg vs_d,de_d;
reg filter_frame;
reg open_frame;
reg [1:0] field_frame;
reg wave_frame,music_frame;
reg [4:0] fade;
reg [3:0] bright_frame,volume_frame;
reg [9:0] bright_end,volume_end;
always @(posedge clk or posedge rst) begin
    if(rst) begin
        x<=0;
        y<=0;
        vs_d<=0;
        de_d<=0;
        filter_frame<=0;
        open_frame<=0;
        field_frame<=0;
        fade<=0;
        bright_frame<=8;
        volume_frame<=8;
        bright_end<=552;
        volume_end<=552;
        wave_frame<=1;
        music_frame<=0;
    end else begin
        vs_d<=in_vs;
        de_d<=in_de;
        if(in_vs&&!vs_d) begin
            if(settings_open && fade<16) begin
                fade<=fade+1'b1;
                open_frame<=1;
            end else if(!settings_open && fade!=0) begin
                fade<=fade-1'b1;
                if(fade==1) open_frame<=0;
            end
        end
        if(in_vs!=vs_d) begin
            x<=0;
            y<=0;
            field_frame<=settings_field;
            wave_frame<=spectrum_enabled;
            filter_frame<=bilinear_enabled;
            music_frame<=music_enabled;
            bright_frame<=brightness;
            volume_frame<=volume;
            bright_end<=10'd320+{1'b0,brightness,5'b0}-{6'b0,brightness}*10'd3;
            volume_end<=10'd320+{1'b0,volume,5'b0}-{6'b0,volume}*10'd3;
        end else begin
            if(in_de) x<=x+1'b1;
            else x<=0;
            if(de_d && !in_de) y<=y+1'b1;
        end
    end
end
reg [4:0] glyph;
reg [3:0] gx,gy;
reg text_on;
reg [23:0] base_colour;
function[4:0] label;
    input [3:0] id;
    input [3:0] n;
    begin
        label=0;
        case(id)
            0:case(n)
                0:label=1;
                1:label=2;
                default:label=0;
            endcase
            1:case(n)
                0:label=3;
                1:label=4;
                default:label=0;
            endcase
            2:case(n)
                0:label=5;
                1:label=6;
                default:label=0;
            endcase
            3:case(n)
                0:label=7;
                1:label=8;
                default:label=0;
            endcase
            4:case(n)
                0:label=5;
                1:label=9;
                default:label=0;
            endcase
            5:case(n)
                0:label=20;
                1:label=21;
                2:label=23;
                3:label=24;
                4:label=25;
                default:label=0;
            endcase
            6:case(n)
                0:label=12;
                1:label=13;
                2:label=14;
                3:label=15;
                4:label=0;
                5:label=16;
                6:label=17;
                7:label=18;
                8:label=19;
                default:label=0;
            endcase
            7:case(n)
                0:label=10;
                default:label=0;
            endcase
            8:case(n)
                0:label=11;
                default:label=0;
            endcase
            default:label=0;
        endcase
    end
endfunction
wire [1:0] row_id=y<264?0:y<328?1:y<392?2:3;
wire [9:0] row_top=y<264?200:y<328?264:y<392?328:392;
always @* begin
    base_colour=in_rgb;
    glyph=0;
    gx=x[3:0];
    gy=y[3:0];
    text_on=0;
    if(open_frame && x>=208 && x<592 && y>=144 && y<488) begin
        base_colour=24'hffffff;
        if(x<212 || x>=588 || y<148 || y>=484) base_colour=24'he3e4e0;
        if(y>=200 && y<456) begin
            if(x>=228 && x<572 && row_id==field_frame) base_colour=24'heaf0f5;
            if(x>=240 && x<272 && y>=row_top+8 && y<row_top+24) begin
                text_on=1;
                glyph=label({2'd0,row_id}+1,(x-240)>>4);
                gy=y-row_top-8;
            end
            if(row_id<2 && x>=320 && x<552 && y>=row_top+36 && y<row_top+48) begin
                base_colour=24'he6e6e1;
                if(x<(row_id==0?bright_end:volume_end)) base_colour=24'h52789f;
            end
            if(row_id>=2 && x>=512 && x<528 && y>=row_top+8 && y<row_top+24) begin
                text_on=1;
                glyph=label((row_id==2?wave_frame:music_frame)?7:8,0);
                gy=y-row_top-8;
            end
        end
        if(x>=240 && x<272 && y>=168 && y<184) begin
            text_on=1;
            glyph=label(0,(x-240)>>4);
            gy=y-168;
        end
        if(x>=464 && x<544 && y>=168 && y<184) begin
            text_on=1;
            glyph=label(5,(x-464)>>4);
            gy=y-168;
        end
        if(x>=448 && x<480 && y>=464 && y<480) begin
            text_on=1;
            glyph=(filter_frame?5'd28:5'd26)+{4'd0,x[4]};
            gy=y-464;
        end
        if(x>=272 && x<416 && y>=464 && y<480) begin
            text_on=1;
            glyph=label(6,(x-272)>>4);
            gy=y-464;
        end
    end
end
(* syn_romstyle="block_rom" *) reg [15:0] font[0:511];
reg [15:0] font_row;
initial begin
    `include "settings_font_init.vh"
end
reg [23:0] base1,under1;
reg [4:0] alpha1;
reg [3:0] gx1,b1,b2_level;
reg text1,vs1,de1;
always @(posedge clk)
    font_row<=font[{glyph,gy}];
wire [23:0] mixed=text1 && font_row[15-gx1]?24'h303b49:base1;
reg [7:0] r2,g2,b2;
reg vs2,de2;
reg [11:0] r3,g3,b3;
reg vs3,de3;
function[7:0] blend;
    input [7:0] under,over;
    input [4:0] a;
    reg signed [8:0] delta;
    reg signed [14:0] weighted;
    reg signed [15:0] sum;
    begin
        delta=$signed({1'b0,over})-$signed({1'b0,under});
        weighted=delta*$signed({1'b0,a});
        sum=$signed({1'b0,under,4'b0})+weighted;
        blend=sum>>>4;
    end
endfunction
always @(posedge clk or posedge rst) begin
    if(rst) begin
        under1<=0;
        alpha1<=0;
        b2_level<=8;
        r3<=0;
        g3<=0;
        b3<=0;
        vs3<=0;
        de3<=0;
        base1<=0;
        gx1<=0;
        b1<=8;
        text1<=0;
        vs1<=0;
        de1<=0;
        r2<=0;
        g2<=0;
        b2<=0;
        vs2<=0;
        de2<=0;
        out_vs<=0;
        out_de<=0;
        out_rgb<=0;
    end else begin
        base1<=base_colour;
        under1<=in_rgb;
        alpha1<=(open_frame && x>=208 && x<592 && y>=144 && y<488)?fade:5'd0;
        gx1<=gx;
        b1<=bright_frame;
        text1<=text_on;
        vs1<=in_vs;
        de1<=in_de;
        r2<=blend(under1[23:16],mixed[23:16],alpha1);
        g2<=blend(under1[15:8],mixed[15:8],alpha1);
        b2<=blend(under1[7:0],mixed[7:0],alpha1);
        b2_level<=b1;
        vs2<=vs1;
        de2<=de1;
        r3<=r2*b2_level;
        g3<=g2*b2_level;
        b3<=b2*b2_level;
        vs3<=vs2;
        de3<=de2;
        out_rgb<={r3[10:3],g3[10:3],b3[10:3]};
        out_vs<=vs3;
        out_de<=de3;
    end
end
endmodule
`endif
