`ifndef FAT32_NAMED_FILE_V
`define FAT32_NAMED_FILE_V
// Read-only FAT32, 512-byte sectors, root directory, ASCII short names.
// Mount once; each open resolves an exact root short filename through the directory chain.
// Requests from bmp_read are LOGICAL file sectors, never physical SD LBAs.
// 【说明】只读 FAT32（sd_card_clk）：挂载（LBA0 或 MBR 分区）、按 8.3 短文件名在根目录查找，
//         只允许读扇区 0 或顺序读下一扇区。3 个读取上下文（图片、音乐、语音）可保存/恢复。
module fat32_named_file #(
    parameter DUAL_CONTEXT=0,
    parameter CONTEXT_BITS=DUAL_CONTEXT==2?2:1
)(
    input [CONTEXT_BITS-1:0] context_select,
    output [CONTEXT_BITS-1:0] context_active,
    input clk,rst,sd_ready,
    output reg mounted,
    output reg open_done,open_ok,
    output wire [31:0] file_size,
    output reg [3:0] error_code,
    output wire idle,
    input file_open,
    input [87:0] file_name,
    input file_abort,
    input file_req,
    input [31:0] file_sector,
    output wire [7:0] file_data,
    output wire file_valid,
    output reg file_end,
    output reg sd_req,
    output reg [31:0] sd_addr,
    input [7:0] sd_data,
    input sd_valid,sd_end
);
localparam START=0,ISSUE=1,READ=2,BOOT_CHECK=3,GEOMETRY=4,GEOMETRY_CHECK=5,
    DIR_ADDR=6,DIR_NEXT=7,FAT_ADDR=8,FAT_NEXT=9,FINISH=10,IDLE=11,
    FILE_MAP=12,FILE_ADDR=13,FILE_END=14,WAIT_LOW=15,FAIL=16,FILE_FAIL=17,GEOMETRY_WAIT=18,BOOT_SETTLE=19,FILE_CHECK=20,GEOMETRY_SETTLE=21,GEOMETRY_FLAGS=22;
localparam BOOT=0,DIR=1,FAT=2,DATA=3;
reg [4:0] state,after_read;
localparam CONTEXT_SETTLE=23;
reg [CONTEXT_BITS-1:0] active_context;
reg [141:0] context_store[0:2];
reg [2:0] context_valid;
reg [31:0] saved_cluster,saved_size,saved_current_cluster,saved_current_sector;
reg [7:0] saved_within_cluster;
reg saved_open_ok,saved_discard;
reg [3:0] saved_error;
assign context_active=active_context;
reg [1:0] kind;
reg [9:0] count;
reg [7:0] spc,nfats,part_type;
reg [3:0] cluster_shift;
reg [15:0] bps,reserved,root_entries,fat16,total16,flags,version,signature;
reg [31:0] total,fat_size,root_cluster,partition,partition_size,part_lba,part_len;
reg partition_found,boot_is_partition,part_lba_valid;
reg [31:0] fat_base,data_base,metadata_sectors,max_cluster,data_clusters;
reg [32:0] volume_end;
reg [87:0] wanted_name;
reg found,dir_end;
reg [87:0] entry_name;
reg [7:0] entry_attr,entry_first;
reg [31:0] entry_cluster,entry_size;
reg [31:0] current_cluster,current_sector,selected_cluster,selected_size;
reg [31:0] next_sector;
reg [7:0] within_cluster;
reg [7:0] last_sector_in_cluster;
reg [12:0] directory_sectors;
reg fat_for_file,discard;
reg [31:0] fat_value,cluster_offset,target_sector;
// 100,000,000-cycle sector timeout fits in 27 bits; READ exits before wrap.
reg [26:0] watchdog;
reg watchdog_expired;
reg request_bad,request_zero,request_next;
reg [7:0] file_data_d;
reg file_valid_d,fat_bad,geometry_bad,bpb_valid,signature_ok;
reg geometry_volume_bad,geometry_cluster_bad,entry_cluster_ok;
reg entry_commit;
reg partition_byte_valid;
reg dir_byte_valid;
reg boot_byte_valid;
reg [9:0] boot_byte_pos;
reg [7:0] boot_byte;
reg [23:0] file_sectors;
wire [141:0] context_now={selected_cluster,selected_size,current_cluster,current_sector,within_cluster,open_ok,discard,error_code};
integer i;
function[7:0] upper;
    input [7:0] c;
    begin
        upper=(c>=8'd97&&c<=8'd122)?c-8'd32:c;
    end
endfunction
wire valid_cluster=current_cluster>=2 && current_cluster<=max_cluster;
wire entry_file=!(entry_attr & 8'h18) && entry_attr!=8'h0f && entry_first!=8'he5;
wire entry_match=entry_name==wanted_name;
assign file_size=selected_size;
wire [31:0] complete_size={sd_data,entry_size[23:0]};
assign idle=state==IDLE && (!DUAL_CONTEXT || context_select==active_context);
assign file_data=file_data_d;
assign file_valid=file_valid_d && !file_abort;
// Delay header fields one cycle so the byte decoder does not include the
// complete filesystem state/stream selection path. BOOT_SETTLE drains it.
always @(posedge clk or posedge rst) begin
    if(rst) begin
        dir_byte_valid<=0;
        partition_byte_valid<=0;
        boot_byte_valid<=0;
        boot_byte_pos<=0;
        boot_byte<=0;
        spc<=0;
        nfats<=0;
        bps<=0;
        reserved<=0;
        root_entries<=0;
        fat16<=0;
        total16<=0;
        flags<=0;
        version<=0;
        signature<=0;
        total<=0;
        fat_size<=0;
        root_cluster<=0;
    end else begin
        partition_byte_valid<=state==READ && kind==BOOT && sd_valid && !boot_is_partition && count>=446 && count<510;
        dir_byte_valid<=state==READ && kind==DIR && sd_valid;
        boot_byte_valid<=state==READ && kind==BOOT && sd_valid;
        boot_byte_pos<=count;
        boot_byte<=sd_data;
        if(boot_byte_valid) begin
            case(boot_byte_pos)
                11:bps[7:0]<=boot_byte;
                12:bps[15:8]<=boot_byte;
                13:spc<=boot_byte;
                14:reserved[7:0]<=boot_byte;
                15:reserved[15:8]<=boot_byte;
                16:nfats<=boot_byte;
                17:root_entries[7:0]<=boot_byte;
                18:root_entries[15:8]<=boot_byte;
                19:total16[7:0]<=boot_byte;
                20:total16[15:8]<=boot_byte;
                22:fat16[7:0]<=boot_byte;
                23:fat16[15:8]<=boot_byte;
                32:total[7:0]<=boot_byte;
                33:total[15:8]<=boot_byte;
                34:total[23:16]<=boot_byte;
                35:total[31:24]<=boot_byte;
                36:fat_size[7:0]<=boot_byte;
                37:fat_size[15:8]<=boot_byte;
                38:fat_size[23:16]<=boot_byte;
                39:fat_size[31:24]<=boot_byte;
                40:flags[7:0]<=boot_byte;
                41:flags[15:8]<=boot_byte;
                42:version[7:0]<=boot_byte;
                43:version[15:8]<=boot_byte;
                44:root_cluster[7:0]<=boot_byte;
                45:root_cluster[15:8]<=boot_byte;
                46:root_cluster[23:16]<=boot_byte;
                47:root_cluster[31:24]<=boot_byte;
                510:signature[7:0]<=boot_byte;
                511:signature[15:8]<=boot_byte;
                default:;
            endcase
        end
    end
end
always @(posedge clk or posedge rst) begin
    if(rst) begin
        state<=START;
        sd_req<=0;
        sd_addr<=0;
        mounted<=0;
        open_done<=0;
        open_ok<=0;
        wanted_name<=0;
        error_code<=0;
        context_valid<=0;
        active_context<=0;
        saved_cluster<=0;
        saved_size<=0;
        saved_current_cluster<=0;
        saved_current_sector<=0;
        saved_within_cluster<=0;
        saved_open_ok<=0;
        saved_discard<=0;
        saved_error<=0;
        count<=0;
        kind<=BOOT;
        after_read<=BOOT_SETTLE;

        partition<=0;
        partition_size<=0;
        part_lba<=0;
        part_len<=0;
        part_type<=0;
        partition_found<=0;
        boot_is_partition<=0;
        part_lba_valid<=0;
        cluster_shift<=0;
        fat_base<=0;
        data_base<=0;
        metadata_sectors<=0;
        max_cluster<=0;
        data_clusters<=0;
        volume_end<=0;
        found<=0;
        dir_end<=0;
        entry_name<=0;
        entry_attr<=0;
        entry_first<=0;
        entry_cluster<=0;
        entry_size<=0;
        current_cluster<=0;
        current_sector<=0;
        next_sector<=1;
        selected_cluster<=0;
        selected_size<=0;
        within_cluster<=0;
        directory_sectors<=0;
        last_sector_in_cluster<=0;
        fat_for_file<=0;
        discard<=0;
        fat_value<=0;
        cluster_offset<=0;
        target_sector<=0;
        file_end<=0;
        watchdog<=0;
        watchdog_expired<=0;
        request_bad<=0;
        request_zero<=0;
        request_next<=0;
        file_data_d<=0;
        file_valid_d<=0;
        fat_bad<=0;
        geometry_bad<=0;
        bpb_valid<=0;
        signature_ok<=0;
        file_sectors<=0;
        geometry_volume_bad<=0;
        geometry_cluster_bad<=0;
        entry_cluster_ok<=0;
        entry_commit<=0;

    end else begin
        file_end<=0;
        open_done<=0;
        entry_commit<=0;
        // Directory byte 31 completes the entry; commit on the following clock.
        // Cluster and size remain stable until later bytes of the next entry.
        if(entry_commit) begin
            selected_cluster<=entry_cluster;
            selected_size<=entry_size;
            found<=1;
        end
        signature_ok<=signature==16'haa55;
        part_lba_valid<=part_lba!=0;
        // Updated while the preceding physical sector is in flight, before IDLE.
        next_sector<=current_sector+1'b1;
        bpb_valid<=(bps==512 && root_entries==0 && fat16==0 && total16==0 && fat_size!=0 &&
            reserved!=0 && (nfats==1 || nfats==2) && version==0 && spc!=0 && (spc&(spc-1'b1))==0 &&
            (!flags[7] || flags[3:0]<nfats));
        file_data_d<=sd_data;
        file_valid_d<=state==READ && kind==DATA && sd_valid && !discard && !file_abort;
        file_sectors<={1'b0,selected_size[31:9]}+(|selected_size[8:0]);
        fat_bad<=fat_value<2 || fat_value>max_cluster || fat_value==current_cluster;
        geometry_volume_bad<=total<=metadata_sectors || total>partition_size || volume_end[32] || fat_size>32'h01ffffff;
        geometry_cluster_bad<=data_clusters<65525 || data_clusters>32'h0fffffed ||
            max_cluster>=(fat_size<<7) || root_cluster<2 || root_cluster>max_cluster;
        geometry_bad<=geometry_volume_bad || geometry_cluster_bad;
        // Entry cluster bytes finish at offset 27, before the size ends at 31.
        entry_cluster_ok<=entry_cluster>=2 && entry_cluster<=max_cluster;
        if(file_abort) discard<=1;
        watchdog_expired<=state==READ && watchdog==27'd99999998;
        if(state==READ) watchdog<=watchdog+1'b1;
        else watchdog<=0;
        if(partition_byte_valid) begin
            // Partition records start at byte 446 (low nibble E).
            case(boot_byte_pos[3:0])
                2:part_type<=boot_byte;
                6:part_lba[7:0]<=boot_byte;
                7:part_lba[15:8]<=boot_byte;
                8:part_lba[23:16]<=boot_byte;
                9:part_lba[31:24]<=boot_byte;
                10:part_len[7:0]<=boot_byte;
                11:part_len[15:8]<=boot_byte;
                12:part_len[23:16]<=boot_byte;
                13:if(!partition_found && (part_type==8'h0b || part_type==8'h0c) && part_lba_valid) begin
                    partition<=part_lba;
                    partition_size<={boot_byte,part_len[23:0]};
                    partition_found<=1;
                end
                default:;
            endcase
        end
        if(dir_byte_valid && !dir_end) begin
            if(boot_byte_pos[4:0]<11) entry_name<={entry_name[79:0],upper(boot_byte)};
            case(boot_byte_pos[4:0])
                0: begin
                    entry_first<=boot_byte;
                    if(boot_byte==0) dir_end<=1;
                end
                11:entry_attr<=boot_byte;
                20:entry_cluster[23:16]<=boot_byte;
                21:entry_cluster[31:24]<={4'd0,boot_byte[3:0]};
                26:entry_cluster[7:0]<=boot_byte;
                27:entry_cluster[15:8]<=boot_byte;
                28:entry_size[7:0]<=boot_byte;
                29:entry_size[15:8]<=boot_byte;
                30:entry_size[23:16]<=boot_byte;
                31: begin
                    entry_size[31:24]<=boot_byte;
                    if(entry_file && entry_match && !found && entry_cluster_ok && {boot_byte,entry_size[23:0]}!=0) entry_commit<=1;
                end
                default:;
            endcase

        end
        case(state)
            START:if(sd_ready) begin
                sd_addr<=0;
                kind<=BOOT;
                after_read<=BOOT_SETTLE;
                state<=ISSUE;
            end
            ISSUE: begin
                sd_req<=1;
                count<=0;
                state<=READ;
            end
            READ: begin
                if(sd_valid) begin
                    count<=count+1'b1;
                    if(kind==BOOT) begin

                    end else if(kind==FAT && count[8:2]==current_cluster[6:0]) begin
                        case(count[1:0])
                            0:fat_value[7:0]<=sd_data;
                            1:fat_value[15:8]<=sd_data;
                            2:fat_value[23:16]<=sd_data;
                            3:fat_value[31:24]<={4'd0,sd_data[3:0]};
                        endcase
                    end
                end
                if(sd_end) begin
                    sd_req<=0;
                    if(count!=512) begin
                        error_code<=4'hb;
                        state<=mounted?FILE_FAIL:FAIL;
                    end else if(discard && mounted) state<=WAIT_LOW;
                    else state<=after_read;
                end
                if(watchdog_expired) begin
                    sd_req<=0;
                    error_code<=4'hc;
                    state<=FAIL;
                end
            end
            BOOT_SETTLE:state<=BOOT_CHECK;
            BOOT_CHECK: begin
                if(!signature_ok) begin
                    error_code<=1;
                    state<=FAIL;
                end else if(bpb_valid) begin
                    last_sector_in_cluster<=spc-8'd1;
                    case(spc)
                        1:cluster_shift<=0;
                        2:cluster_shift<=1;
                        4:cluster_shift<=2;
                        8:cluster_shift<=3;
                        16:cluster_shift<=4;
                        32:cluster_shift<=5;
                        64:cluster_shift<=6;
                        128:cluster_shift<=7;
                        default:cluster_shift<=0;
                    endcase
                    if(!boot_is_partition) begin
                        partition<=0;
                        partition_size<=total;
                    end
                    metadata_sectors<={16'd0,reserved}+(nfats==2?(fat_size<<1):fat_size);
                    state<=GEOMETRY;
                end else if(!boot_is_partition && partition_found) begin
                    boot_is_partition<=1;
                    sd_addr<=partition;
                    kind<=BOOT;
                    after_read<=BOOT_SETTLE;
                    state<=ISSUE;
                end else begin
                    error_code<=2;
                    state<=FAIL;
                end
            end
            GEOMETRY: begin
                fat_base<=partition+reserved+((flags[7] && flags[0])?fat_size:32'd0);
                data_base<=partition+metadata_sectors;
                data_clusters<=(total-metadata_sectors)>>cluster_shift;
                volume_end<={1'b0,partition}+{1'b0,total};
                state<=GEOMETRY_WAIT;
            end
            // Separate the final +1 from subtraction/shift, then allow both registered
            // validation stages to settle before accepting the volume geometry.
            GEOMETRY_WAIT: begin
                max_cluster<=data_clusters+1'b1;
                state<=GEOMETRY_SETTLE;
            end
            GEOMETRY_SETTLE:state<=GEOMETRY_FLAGS;
            GEOMETRY_FLAGS:state<=GEOMETRY_CHECK;
            GEOMETRY_CHECK: begin
                if(geometry_bad) begin
                    error_code<=3;
                    state<=FAIL;
                end else begin
                    mounted<=1;
                    state<=IDLE;
                end
            end
            DIR_ADDR: begin
                cluster_offset<=(current_cluster-2)<<cluster_shift;
                state<=FILE_ADDR;
                kind<=DIR;
            end
            DIR_NEXT: begin
                directory_sectors<=directory_sectors+1'b1;
                if(dir_end || found || entry_commit) state<=FINISH;
                else if(directory_sectors==4095) begin
                    error_code<=4;
                    state<=FAIL;
                end else if(within_cluster>=last_sector_in_cluster) begin
                    fat_for_file<=0;
                    state<=FAT_ADDR;
                end else begin
                    within_cluster<=within_cluster+1'b1;
                    state<=DIR_ADDR;
                end
            end
            FAT_ADDR: begin
                sd_addr<=fat_base+(current_cluster>>7);
                kind<=FAT;
                after_read<=FAT_NEXT;
                state<=ISSUE;
            end
            FAT_NEXT: begin
                if(fat_value>=32'h0ffffff8 && !fat_for_file) state<=FINISH;
                else if(fat_bad) begin
                    error_code<=5;
                    state<=mounted?FILE_FAIL:FAIL;
                end else begin
                    current_cluster<=fat_value;
                    within_cluster<=0;
                    if(fat_for_file) state<=FILE_MAP;
                    else state<=DIR_ADDR;
                end
            end
            FINISH: begin
                open_done<=1;
                open_ok<=found;
                if(!found) error_code<=6;
                state<=IDLE;
            end
            IDLE:if(DUAL_CONTEXT && context_select!=active_context) begin
                if(DUAL_CONTEXT==2) begin
                    context_store[active_context]<=context_now;
                    context_valid[active_context]<=1;
                    {selected_cluster,selected_size,current_cluster,current_sector,within_cluster,open_ok,discard,error_code}<=context_valid[context_select]?context_store[context_select]:142'd0;
                end else begin
                    saved_cluster<=selected_cluster;
                    selected_cluster<=saved_cluster;
                    saved_size<=selected_size;
                    selected_size<=saved_size;
                    saved_current_cluster<=current_cluster;
                    current_cluster<=saved_current_cluster;
                    saved_current_sector<=current_sector;
                    current_sector<=saved_current_sector;
                    saved_within_cluster<=within_cluster;
                    within_cluster<=saved_within_cluster;
                    saved_open_ok<=open_ok;
                    open_ok<=saved_open_ok;
                    saved_discard<=discard;
                    discard<=saved_discard;
                    saved_error<=error_code;
                    error_code<=saved_error;
                end
                active_context<=context_select;
                state<=CONTEXT_SETTLE;
            end else if(file_open) begin
                wanted_name<=file_name;
                found<=0;
                open_ok<=0;
                dir_end<=0;
                directory_sectors<=0;
                selected_cluster<=0;
                selected_size<=0;
                current_cluster<=root_cluster;
                within_cluster<=0;
                discard<=0;
                error_code<=0;
                state<=DIR_ADDR;
            end else if(file_req && open_ok && !discard) begin
                target_sector<=file_sector;
                request_bad<=file_sector>=file_sectors;
                request_zero<=file_sector==0;
                request_next<=file_sector==next_sector;
                state<=FILE_CHECK;
            end
            CONTEXT_SETTLE:state<=IDLE;
            FILE_CHECK: begin
                if(request_bad) begin
                    error_code<=7;
                    state<=FILE_FAIL;
                end else if(request_zero) begin
                    current_cluster<=selected_cluster;
                    within_cluster<=0;
                    current_sector<=0;
                    state<=FILE_MAP;
                end else if(request_next) begin
                    current_sector<=target_sector;
                    if(within_cluster>=last_sector_in_cluster) begin
                        fat_for_file<=1;
                        state<=FAT_ADDR;
                    end else begin
                        within_cluster<=within_cluster+1'b1;
                        state<=FILE_MAP;
                    end
                end else begin
                    error_code<=8;
                    state<=FILE_FAIL;
                end
            end

            FILE_MAP: begin
                // Both directory entries and FAT successors were validated before assignment.
                cluster_offset<=(current_cluster-2)<<cluster_shift;
                kind<=DATA;
                state<=FILE_ADDR;
            end
            FILE_ADDR: begin
                sd_addr<=data_base+cluster_offset+within_cluster;
                after_read<=kind==DIR?DIR_NEXT:FILE_END;
                state<=ISSUE;
            end
            FILE_END: begin
                file_end<=!discard;
                state<=WAIT_LOW;
            end
            WAIT_LOW:if(!file_req) begin
                state<=IDLE;
            end
            FILE_FAIL:if(file_abort) begin
                discard<=1;
                state<=WAIT_LOW;
            end
            FAIL:sd_req<=0;
            default: begin
                error_code<=15;
                state<=FAIL;
            end
        endcase
        // Drain a physical sector on abort; never let a stale response enter a retry.
        // A physical timeout is fatal until reset: the SD controller may still own
        // the bus, so a loader retry must not reopen it as a fresh file transaction.
        if(file_abort && mounted && state!=READ && state!=ISSUE && state!=FAIL) begin
            sd_req<=0;
            state<=WAIT_LOW;
        end
    end
end
endmodule
`endif
