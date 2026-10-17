// 【未使用】旧版 FAT32 读取器，已由 SD/fat32_named_file.v 取代。
// 仍保留在工程文件列表中，综合时不会进入设计层次；阅读当前设计可跳过本文件。
`ifndef FAT32_FILE_READER_V
`define FAT32_FILE_READER_V
// Read-only FAT32, 512-byte sectors, root directory, ASCII short names.
// Slot 0 is BACK.BMP; slots 1..3 are the first other root BMP short entries.
// Requests from bmp_read are LOGICAL file sectors, never physical SD LBAs.
module fat32_file_reader(
 input clk,rst,sd_ready,
 output reg catalog_ready,output reg[2:0] image_count,
 output reg[3:0] error_code,output wire idle,
 input file_open,input[1:0] file_index,input file_abort,
 input file_req,input[31:0] file_sector,
 output wire[7:0] file_data,output wire file_valid,output reg file_end,
 output reg sd_req,output reg[31:0] sd_addr,
 input[7:0] sd_data,input sd_valid,sd_end);
 localparam START=0,ISSUE=1,READ=2,BOOT_CHECK=3,GEOMETRY=4,GEOMETRY_CHECK=5,
 DIR_ADDR=6,DIR_NEXT=7,FAT_ADDR=8,FAT_NEXT=9,FINISH=10,IDLE=11,
 FILE_MAP=12,FILE_ADDR=13,FILE_END=14,WAIT_LOW=15,FAIL=16,FILE_FAIL=17,GEOMETRY_WAIT=18;
 localparam BOOT=0,DIR=1,FAT=2,DATA=3;
 reg[4:0] state,after_read;
 reg[1:0] kind;
 reg[9:0] count;
 reg[7:0] spc,nfats,part_type;
 reg[3:0] cluster_shift;
 reg[15:0] bps,reserved,root_entries,fat16,total16,flags,version,signature;
 reg[31:0] total,fat_size,root_cluster,partition,partition_size,part_lba,part_len;
 reg partition_found,boot_is_partition;
 reg[31:0] fat_base,data_base,metadata_sectors,max_cluster,data_clusters;
 reg[32:0] volume_end;
 reg[31:0] clusters[0:3],sizes[0:3];
 reg[1:0] extras;
 reg back_found,dir_end;
 reg[87:0] entry_name;
 reg[7:0] entry_attr,entry_first;
 reg[31:0] entry_cluster,entry_size;
 reg[31:0] current_cluster,current_sector,selected_cluster,selected_size;
 reg[7:0] within_cluster;
 reg[12:0] directory_sectors;
 reg fat_for_file,discard;
 reg[31:0] fat_value,cluster_offset,target_sector;
 reg[31:0] watchdog;
 reg [7:0] file_data_d;
 reg file_valid_d,fat_bad,geometry_bad;
 reg [23:0] file_sectors;
 integer i;
 function[7:0] upper;input[7:0] c;begin upper=(c>=8'd97&&c<=8'd122)?c-8'd32:c;end endfunction
 wire valid_cluster=current_cluster>=2 && current_cluster<=max_cluster;
 wire entry_bmp=entry_name[23:0]==24'h424d50 && !(entry_attr & 8'h18) && entry_attr!=8'h0f && entry_first!=8'he5;
 wire entry_back=entry_name==88'h4241434b20202020424d50;
 wire [31:0] complete_size={sd_data,entry_size[23:0]};
 assign idle=state==IDLE;
 assign file_data=file_data_d;
 assign file_valid=file_valid_d && !file_abort;
 always @(posedge clk or posedge rst)begin
 if(rst)begin
 state<=START;sd_req<=0;sd_addr<=0;catalog_ready<=0;image_count<=0;error_code<=0;
 count<=0;kind<=BOOT;after_read<=BOOT_CHECK;spc<=0;nfats<=0;bps<=0;reserved<=0;
 root_entries<=0;fat16<=0;total16<=0;flags<=0;version<=0;signature<=0;
 total<=0;fat_size<=0;root_cluster<=0;partition<=0;partition_size<=0;part_lba<=0;part_len<=0;part_type<=0;
 partition_found<=0;boot_is_partition<=0;cluster_shift<=0;fat_base<=0;data_base<=0;
 metadata_sectors<=0;max_cluster<=0;data_clusters<=0;volume_end<=0;
 extras<=0;back_found<=0;dir_end<=0;entry_name<=0;entry_attr<=0;entry_first<=0;entry_cluster<=0;entry_size<=0;
 current_cluster<=0;current_sector<=0;selected_cluster<=0;selected_size<=0;within_cluster<=0;directory_sectors<=0;
 fat_for_file<=0;discard<=0;fat_value<=0;cluster_offset<=0;target_sector<=0;file_end<=0;watchdog<=0;
 file_data_d<=0;file_valid_d<=0;fat_bad<=0;geometry_bad<=0;file_sectors<=0;
 for(i=0;i<4;i=i+1)begin clusters[i]<=0;sizes[i]<=0;end
 end else begin
 file_end<=0;
 file_data_d<=sd_data;
 file_valid_d<=state==READ && kind==DATA && sd_valid && !discard && !file_abort;
 file_sectors<={1'b0,selected_size[31:9]}+(|selected_size[8:0]);
 fat_bad<=fat_value<2 || fat_value>max_cluster || fat_value==current_cluster;
 geometry_bad<=total<=metadata_sectors || total>partition_size || volume_end[32] ||
 fat_size>32'h01ffffff || data_clusters<65525 || data_clusters>32'h0fffffed ||
 max_cluster>=(fat_size<<7) || root_cluster<2 || root_cluster>max_cluster;
 if(file_abort)discard<=1;
 if(file_open && state==IDLE)begin
 selected_cluster<=clusters[file_index];selected_size<=sizes[file_index];discard<=0;error_code<=0;
 end
 if(state==READ)watchdog<=watchdog+1'b1;else watchdog<=0;
 case(state)
 START:if(sd_ready)begin sd_addr<=0;kind<=BOOT;after_read<=BOOT_CHECK;state<=ISSUE;end
 ISSUE:begin sd_req<=1;count<=0;state<=READ;end
 READ:begin
 if(sd_valid)begin
 count<=count+1'b1;
 if(kind==BOOT)begin
 case(count)
 11:bps[7:0]<=sd_data;12:bps[15:8]<=sd_data;13:spc<=sd_data;
 14:reserved[7:0]<=sd_data;15:reserved[15:8]<=sd_data;16:nfats<=sd_data;
 17:root_entries[7:0]<=sd_data;18:root_entries[15:8]<=sd_data;
 19:total16[7:0]<=sd_data;20:total16[15:8]<=sd_data;
 22:fat16[7:0]<=sd_data;23:fat16[15:8]<=sd_data;
 32:total[7:0]<=sd_data;33:total[15:8]<=sd_data;34:total[23:16]<=sd_data;35:total[31:24]<=sd_data;
 36:fat_size[7:0]<=sd_data;37:fat_size[15:8]<=sd_data;38:fat_size[23:16]<=sd_data;39:fat_size[31:24]<=sd_data;
 40:flags[7:0]<=sd_data;41:flags[15:8]<=sd_data;42:version[7:0]<=sd_data;43:version[15:8]<=sd_data;
 44:root_cluster[7:0]<=sd_data;45:root_cluster[15:8]<=sd_data;46:root_cluster[23:16]<=sd_data;47:root_cluster[31:24]<=sd_data;
 510:signature[7:0]<=sd_data;511:signature[15:8]<=sd_data;
 default:;
 endcase
 if(!boot_is_partition && count>=446 && count<510)begin
 case((count-446)&15)
 4:part_type<=sd_data;
 8:part_lba[7:0]<=sd_data;9:part_lba[15:8]<=sd_data;10:part_lba[23:16]<=sd_data;11:part_lba[31:24]<=sd_data;
 12:part_len[7:0]<=sd_data;13:part_len[15:8]<=sd_data;14:part_len[23:16]<=sd_data;
 15:if(!partition_found && (part_type==8'h0b || part_type==8'h0c) && part_lba!=0)begin
 partition<=part_lba;partition_size<={sd_data,part_len[23:0]};partition_found<=1;end
 default:;
 endcase end
 end else if(kind==DIR && !dir_end)begin
 if(count[4:0]<11)entry_name<={entry_name[79:0],upper(sd_data)};
 case(count[4:0])
 0:begin entry_first<=sd_data;if(sd_data==0)dir_end<=1;end
 11:entry_attr<=sd_data;
 20:entry_cluster[23:16]<=sd_data;21:entry_cluster[31:24]<={4'd0,sd_data[3:0]};
 26:entry_cluster[7:0]<=sd_data;27:entry_cluster[15:8]<=sd_data;
 28:entry_size[7:0]<=sd_data;29:entry_size[15:8]<=sd_data;30:entry_size[23:16]<=sd_data;
 31:if(entry_bmp && entry_cluster>=2 && entry_cluster<=max_cluster && complete_size>=54)begin
 if(entry_back && !back_found)begin clusters[0]<=entry_cluster;sizes[0]<=complete_size;back_found<=1;end
 else if(!entry_back && extras<3)begin clusters[extras+1'b1]<=entry_cluster;sizes[extras+1'b1]<=complete_size;extras<=extras+1'b1;end
 end
 default:;
 endcase
 end else if(kind==FAT && count[8:2]==current_cluster[6:0])begin
 case(count[1:0])0:fat_value[7:0]<=sd_data;1:fat_value[15:8]<=sd_data;
 2:fat_value[23:16]<=sd_data;3:fat_value[31:24]<={4'd0,sd_data[3:0]};endcase
 end
 end
 if(sd_end)begin sd_req<=0;
 if(count!=512)begin error_code<=4'hb;state<=catalog_ready?FILE_FAIL:FAIL;end
 else if(discard && catalog_ready)state<=WAIT_LOW;
 else state<=after_read;
 end
 if(watchdog==32'd99999999)begin sd_req<=0;error_code<=4'hc;state<=FAIL;end
 end
 BOOT_CHECK:begin
 if(signature!=16'haa55)begin error_code<=1;state<=FAIL;end
 else if(bps==512 && root_entries==0 && fat16==0 && total16==0 && fat_size!=0 &&
 reserved!=0 && (nfats==1 || nfats==2) && version==0 && spc!=0 && (spc&(spc-1'b1))==0 &&
 (!flags[7] || flags[3:0]<nfats))begin
 case(spc)1:cluster_shift<=0;2:cluster_shift<=1;4:cluster_shift<=2;8:cluster_shift<=3;
 16:cluster_shift<=4;32:cluster_shift<=5;64:cluster_shift<=6;128:cluster_shift<=7;default:cluster_shift<=0;endcase
 if(!boot_is_partition)begin partition<=0;partition_size<=total;end
 metadata_sectors<={16'd0,reserved}+(nfats==2?(fat_size<<1):fat_size);
 state<=GEOMETRY;
 end else if(!boot_is_partition && partition_found)begin
 boot_is_partition<=1;sd_addr<=partition;kind<=BOOT;after_read<=BOOT_CHECK;state<=ISSUE;
 end else begin error_code<=2;state<=FAIL;end
 end
 GEOMETRY:begin
 fat_base<=partition+reserved+((flags[7] && flags[0])?fat_size:32'd0);
 data_base<=partition+metadata_sectors;
 data_clusters<=(total-metadata_sectors)>>cluster_shift;
 max_cluster<=((total-metadata_sectors)>>cluster_shift)+1'b1;
 volume_end<={1'b0,partition}+{1'b0,total};state<=GEOMETRY_WAIT;
 end
 GEOMETRY_WAIT:state<=GEOMETRY_CHECK;
 GEOMETRY_CHECK:begin
 if(geometry_bad)begin error_code<=3;state<=FAIL;end
 else begin current_cluster<=root_cluster;within_cluster<=0;state<=DIR_ADDR;end
 end
 DIR_ADDR:begin
 cluster_offset<=(current_cluster-2)<<cluster_shift;state<=FILE_ADDR;kind<=DIR;
 end
 DIR_NEXT:begin
 directory_sectors<=directory_sectors+1'b1;
 if(dir_end || (back_found && extras==3))state<=FINISH;
 else if(directory_sectors==4095)begin error_code<=4;state<=FAIL;end
 else if(within_cluster+1>=spc)begin fat_for_file<=0;state<=FAT_ADDR;end
 else begin within_cluster<=within_cluster+1'b1;state<=DIR_ADDR;end
 end
 FAT_ADDR:begin sd_addr<=fat_base+(current_cluster>>7);kind<=FAT;after_read<=FAT_NEXT;state<=ISSUE;end
 FAT_NEXT:begin
 if(fat_value>=32'h0ffffff8 && !fat_for_file)state<=FINISH;
 else if(fat_bad)begin error_code<=5;state<=catalog_ready?FILE_FAIL:FAIL;end
 else begin current_cluster<=fat_value;within_cluster<=0;
 if(fat_for_file)state<=FILE_MAP;else state<=DIR_ADDR;end
 end
 FINISH:if(back_found)begin catalog_ready<=1;image_count<={1'b0,extras}+1'b1;state<=IDLE;end
 else begin error_code<=6;state<=FAIL;end
 IDLE:if(file_req && !file_open && !discard)begin
 target_sector<=file_sector;
 if(file_sector>=file_sectors)begin error_code<=7;state<=FILE_FAIL;end
 else if(file_sector==0)begin current_cluster<=selected_cluster;within_cluster<=0;current_sector<=0;state<=FILE_MAP;end
 else if(file_sector==current_sector+1'b1)begin current_sector<=file_sector;
 if(within_cluster+1>=spc)begin fat_for_file<=1;state<=FAT_ADDR;end
 else begin within_cluster<=within_cluster+1'b1;state<=FILE_MAP;end
 end else begin error_code<=8;state<=FILE_FAIL;end
 end
 FILE_MAP:begin
 // Both directory entries and FAT successors were validated before assignment.
 cluster_offset<=(current_cluster-2)<<cluster_shift;kind<=DATA;state<=FILE_ADDR;
 end
 FILE_ADDR:begin sd_addr<=data_base+cluster_offset+within_cluster;
 after_read<=kind==DIR?DIR_NEXT:FILE_END;state<=ISSUE;end
 FILE_END:begin file_end<=!discard;state<=WAIT_LOW;end
 WAIT_LOW:if(!file_req)begin state<=IDLE;end
 FILE_FAIL:if(file_abort)begin discard<=1;state<=WAIT_LOW;end
 FAIL:sd_req<=0;
 default:begin error_code<=15;state<=FAIL;end
 endcase
 // Drain a physical sector on abort; never let a stale response enter a retry.
 // A physical timeout is fatal until reset: the SD controller may still own
 // the bus, so a loader retry must not reopen it as a fresh file transaction.
 if(file_abort && catalog_ready && state!=READ && state!=ISSUE && state!=FAIL)begin sd_req<=0;state<=WAIT_LOW;end
 end end
endmodule
`endif
