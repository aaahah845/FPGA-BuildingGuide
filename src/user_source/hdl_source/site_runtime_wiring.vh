// Top-level runtime config distribution and acknowledged cache mailboxes.
wire cfg_ready_sd,background_ready_sd;
(* ASYNC_REG="TRUE" *) reg [1:0] cfg_ready_sync,background_ready_sync;
reg [2:0] cfg_copy_state;
reg site_ready,cfg_we;
reg [12:0] cfg_addr,cfg_read_addr;
reg [7:0] cfg_data;
wire [7:0] cfg_read_data;
// The loader accepts only full v6 packages; their first 8 KB already use
// canonical addresses. Fonts have finished loading before cfg_ready_sd.
always @(posedge video_clk or posedge rst_video) begin
    if(rst_video) begin
        cfg_ready_sync<=0;
        background_ready_sync<=0;
        cfg_copy_state<=0;
        site_ready<=0;
        cfg_we<=0;
        cfg_addr<=0;
        cfg_read_addr<=0;
        cfg_data<=0;
    end else begin
        cfg_ready_sync<={cfg_ready_sync[0],cfg_ready_sd};
        background_ready_sync<={background_ready_sync[0],background_ready_sd};
        cfg_we<=0;
        case(cfg_copy_state)
            0:if(cfg_ready_sync[1]) begin
                cfg_read_addr<=0;
                cfg_copy_state<=1;
            end
            1:cfg_copy_state<=2;
            2: begin
                cfg_we<=1;
                cfg_addr<=cfg_read_addr;
                cfg_data<=cfg_read_data;
                cfg_copy_state<=3;
            end
            3:if(cfg_read_addr==8191) cfg_copy_state<=4;
            else begin
                cfg_read_addr<=cfg_read_addr+1'b1;
                cfg_copy_state<=1;
            end
            4: begin
                site_ready<=1;
                cfg_copy_state<=5;
            end
            default:;
        endcase
    end
end
wire request_toggle_v,request_toggle_sd,response_toggle_sd,response_toggle_v,decision_toggle_v,decision_toggle_sd,decision_accept_v;
wire [6:0] request_primary_v,request_photo_v;
wire request_need_v;
wire [7:0] request_tag_v;
wire request_prefetch_v,prefetch_cancel_v;
wire [31:0] request_keep_v;
wire [55:0] request_packet_sd;
(* ASYNC_REG="TRUE" *) reg [1:0] prefetch_cancel_sync;
always @(posedge sd_card_clk or posedge rst_sd)
    if(rst_sd) prefetch_cancel_sync<=0;
    else prefetch_cancel_sync<={prefetch_cancel_sync[0],prefetch_cancel_v};
wire response_ok_sd;
wire [2:0] response_primary_sd,response_photo_sd;
wire [6:0] response_packet_v;
wire decision_accept_sd;
held_bus_cdc #(
    .WIDTH(56)
) u_asset_request(
    .clk(sd_card_clk),
    .rst(rst_sd),
    .async_toggle(request_toggle_v),
    .async_data({request_keep_v,request_prefetch_v,request_tag_v,request_primary_v,request_photo_v,request_need_v}),
    .event_toggle(request_toggle_sd),
    .data(request_packet_sd)
);
held_bus_cdc #(
    .WIDTH(7)
) u_asset_response(
    .clk(video_clk),
    .rst(rst_video),
    .async_toggle(response_toggle_sd),
    .async_data({response_ok_sd,response_primary_sd,response_photo_sd}),
    .event_toggle(response_toggle_v),
    .data(response_packet_v)
);
held_bus_cdc #(
    .WIDTH(1)
) u_asset_decision(
    .clk(sd_card_clk),
    .rst(rst_sd),
    .async_toggle(decision_toggle_v),
    .async_data(decision_accept_v),
    .event_toggle(decision_toggle_sd),
    .data(decision_accept_sd)
);
wire reader_applied_pulse;
wire [7:0] reader_applied_tag,scene_tag;
wire [5:0] reader_applied_mask;
reg applied_toggle_mem;
reg [14:0] applied_packet_mem;
wire [14:0] applied_packet_sd;
wire applied_toggle_sd;
always @(posedge ext_mem_clk or posedge rst_mem) begin
    if(rst_mem) begin
        applied_toggle_mem<=0;
        applied_packet_mem<=0;
    end else if(reader_applied_pulse) begin
        applied_toggle_mem<=!applied_toggle_mem;
        applied_packet_mem<={applied_buf_valid_mem,reader_applied_tag,reader_applied_mask};
    end
end
held_bus_cdc #(
    .WIDTH(15)
) u_reader_handoff(
    .clk(sd_card_clk),
    .rst(rst_sd),
    .async_toggle(applied_toggle_mem),
    .async_data(applied_packet_mem),
    .event_toggle(applied_toggle_sd),
    .data(applied_packet_sd)
);
wire site_loading,site_load_error;
wire [6:0] carousel_image_id;

wire image_loading_sd;
wire [6:0] loading_resource_sd;
(* ASYNC_REG="TRUE" *) reg [7:0] load_meta,load_sync;
wire visible_loading;
always @(posedge video_clk or posedge rst_video) begin
    if(rst_video) begin
        load_meta<=0;
        load_sync<=0;
    end else begin
        load_meta<={image_loading_sd,loading_resource_sd};
        load_sync<=load_meta;
    end
end
