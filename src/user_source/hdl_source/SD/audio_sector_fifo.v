// 【未使用】旧版单路音频扇区缓存，已由 SD/audio_mix_fifo.v 取代。
// 仍保留在工程文件列表中，综合时不会进入设计层次；阅读当前设计可跳过本文件。
`ifndef AUDIO_SECTOR_FIFO_V
`define AUDIO_SECTOR_FIFO_V
// Two 256-sample pages, one 9K BRAM. Publish whole pages with a Gray pointer;
// page lengths remain held until the reader returns ownership. Never rewind
// live CDC pointers for a track change: drain old pages before opening a file.
module audio_sector_fifo(input wclk,wrst,input write_en,input[7:0]write_index,
 input[15:0]write_sample,input publish,input[8:0]publish_count,
 output full,empty_write,
 input rclk,rrst,input take,output available,output[15:0]sample);
 (* syn_ramstyle="block_ram" *)reg[15:0]mem[0:511];
 reg[8:0]length0,length1;
 reg[1:0]wp,rp,wgray,rgray;
 (* ASYNC_REG="TRUE" *)reg[1:0]rgray_meta,rgray_sync,wgray_meta,wgray_sync;
 wire[1:0]rb={rgray_sync[1],rgray_sync[1]^rgray_sync[0]};
 wire[1:0]wb={wgray_sync[1],wgray_sync[1]^wgray_sync[0]};
 wire[1:0]wnext=wp+2'd1,rnext=rp+2'd1;
 wire[1:0]used=wp-rb;
 assign full=used==2;assign empty_write=wp==rb;assign available=rp!=wb;
 reg[7:0]index;reg[15:0]q;
 assign sample=q;
 always @(posedge wclk)if(write_en && !full)mem[{wp[0],write_index}]<=write_sample;
 always @(posedge rclk)q<=mem[{rp[0],index}];
 always @(posedge wclk or posedge wrst)begin
 if(wrst)begin wp<=0;wgray<=0;rgray_meta<=0;rgray_sync<=0;length0<=0;length1<=0;end
 else begin
 rgray_meta<=rgray;rgray_sync<=rgray_meta;
 if(publish && !full && publish_count!=0)begin
 if(wp[0])length1<=publish_count;else length0<=publish_count;
 wp<=wnext;wgray<=(wnext>>1)^wnext;
 end
 end end
 always @(posedge rclk or posedge rrst)begin
 if(rrst)begin rp<=0;rgray<=0;wgray_meta<=0;wgray_sync<=0;index<=0;end
 else begin
 wgray_meta<=wgray;wgray_sync<=wgray_meta;
 if(take && available)begin
 if({1'b0,index}+9'd1==(rp[0]?length1:length0))begin
 index<=0;rp<=rnext;rgray<=(rnext>>1)^rnext;
 end else index<=index+1'b1;
 end
 end end
endmodule
`endif
