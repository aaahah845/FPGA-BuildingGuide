`ifndef AUDIO_MIX_FIFO_V
`define AUDIO_MIX_FIFO_V
// Two output pages in one BRAM. The SD port fills music, then adds speech
// before publication. The HDMI port can only see completed mixed pages.
// 【说明】音频混音页（跨 sd_card_clk → video_clk）：一块 BRAM 分两页，每页最多 256 个样本；
//         写侧可对已有音乐样本做“读—加—饱和—写回”，读侧只能看到已发布的整页。
module audio_mix_fifo(
    input wclk,wrst,write_en,
    input [7:0] write_index,
    input [15:0] write_sample,
    input mix_write,
    input [8:0] music_count,
    input publish,
    input [8:0] publish_count,
    output full,empty_write,
    input rclk,rrst,take,
    output available,
    output [15:0] sample
);
(* syn_ramstyle="block_ram" *) reg [7:0] mem[0:1023];
reg [8:0] length0,length1;
reg [1:0] wp,rp,wgray,rgray;
(* ASYNC_REG="TRUE" *) reg [1:0] rmeta,rsync,wmeta,wsync;
reg [1:0] wvisible;
(* ASYNC_REG="TRUE" *) reg [8:0] length0_meta,length1_meta;
reg [8:0] length0_sync,length1_sync;
// Page lengths are held from publication until the reader releases the page.
// Sample the held buses twice; expose the Gray publication one cycle later.
wire [1:0] rb={rsync[1],rsync[1]^rsync[0]},wb={wvisible[1],wvisible[1]^wvisible[0]};
wire [1:0] wnext=wp+1'b1,rnext=rp+1'b1;
wire [1:0] used=wp-rb;
assign full=used==2'd2;
assign empty_write=wp==rb;
assign available=rp!=wb;
// EG4 true dual-port BRAM is at most 9 bits wide. Serialize each
// 16-bit sample into two bytes so read/modify/write still uses one BRAM.
// SD delivers samples >=72 clocks apart; this transaction takes 6.
reg [7:0] index,old_low,wq,read_low;
reg read_high=0;
reg [15:0] q,data_d,result_d;
reg mix_d;
reg [8:0] address_d;
reg [2:0] write_phase;
wire [9:0] port_address={address_d,(write_phase==2 || write_phase==5)};
wire signed [16:0] sum=$signed({wq[7],wq,old_low})+$signed({data_d[15],data_d});
wire [15:0] mixed=sum>17'sd32767 ? 16'h7fff : sum< -17'sd32768 ? 16'h8000 : sum[15:0];
always @(posedge wclk) begin
    if(write_phase==4 || write_phase==5) mem[port_address]<=write_phase==4?result_d[7:0]:result_d[15:8];
    else wq<=mem[port_address];
end
reg [7:0] rq;
reg read_high_d=0;
always @(posedge rclk) begin
    rq<=mem[{rp[0],index,read_high}];
    read_high<=!read_high;
    read_high_d<=read_high;
    if(read_high_d) q<={rq,read_low};
    else read_low<=rq;
end
assign sample=q;
always @(posedge wclk or posedge wrst) begin
    if(wrst) begin
        wp<=0;
        wgray<=0;
        rmeta<=0;
        rsync<=0;
        length0<=0;
        length1<=0;
        write_phase<=0;
        mix_d<=0;
        address_d<=0;
        data_d<=0;
        old_low<=0;
        result_d<=0;
    end else begin
        rmeta<=rgray;
        rsync<=rmeta;
        case(write_phase)
            0:if(write_en && !full) begin
                address_d<={wp[0],write_index};
                data_d<=write_sample;
                mix_d<=mix_write && {1'b0,write_index}<music_count;
                write_phase<=1;
            end
            1:write_phase<=2;
            2: begin
                old_low<=wq;
                write_phase<=3;
            end
            3: begin
                result_d<=mix_d?mixed:data_d;
                write_phase<=4;
            end
            4:write_phase<=5;
            5:write_phase<=0;
            default:write_phase<=0;
        endcase
        if(publish && !full && publish_count!=0) begin
            if(wp[0]) length1<=publish_count;
            else length0<=publish_count;
            wp<=wnext;
            wgray<=(wnext>>1)^wnext;
        end
    end
end
always @(posedge rclk or posedge rrst) begin
    if(rrst) begin
        rp<=0;
        rgray<=0;
        wmeta<=0;
        wsync<=0;
        wvisible<=0;
        index<=0;
        length0_meta<=0;
        length1_meta<=0;
        length0_sync<=0;
        length1_sync<=0;
    end else begin
        wmeta<=wgray;
        wsync<=wmeta;
        wvisible<=wsync;
        length0_meta<=length0;
        length1_meta<=length1;
        length0_sync<=length0_meta;
        length1_sync<=length1_meta;
        if(take && available) begin
            if({1'b0,index}+9'd1==(rp[0]?length1_sync:length0_sync)) begin
                index<=0;
                rp<=rnext;
                rgray<=(rnext>>1)^rnext;
            end else index<=index+1'b1;
        end
    end
end
endmodule
`endif
