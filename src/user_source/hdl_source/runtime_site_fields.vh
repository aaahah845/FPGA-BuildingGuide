// Included inside consuming modules. Only referenced fields survive synthesis.
// cfg_* byte stream is issued once in the VIDEO domain after full SD validation.
reg [1:0] rt_floors,rt_period;
reg rt_show,rt_selected,rt_zoom;
reg [3:0] rt_counts[0:2];
reg [6:0] rt_maps[0:2],rt_photos[0:29];
reg [6:0] rt_point_photos[0:29];
reg [9:0] rt_x[0:29];
reg [9:0] rt_y[0:29];
reg [6:0] rt_playlist[0:15];
reg [4:0] rt_slide_count;
wire [1:0] cfg_floors=RUNTIME_CONFIG?rt_floors:SITE_FLOORS;
wire [1:0] cfg_period=RUNTIME_CONFIG?rt_period:MAP_PERIOD_SELECT;
wire cfg_show=RUNTIME_CONFIG?rt_show:MAP_SHOW_POINTS;
wire cfg_selected=RUNTIME_CONFIG?rt_selected:MAP_SELECTED_ONLY;
wire cfg_zoom=RUNTIME_CONFIG?rt_zoom:MAP_DEFAULT_ZOOM;
always @(posedge rt_clk)
    if(cfg_we && RUNTIME_CONFIG) begin
        case(cfg_addr)
            8:rt_floors<=cfg_data[1:0];
            10:rt_slide_count<=cfg_data[4:0];
            11:rt_period<=cfg_data[1:0];
            12:rt_show<=cfg_data[0];
            13:rt_selected<=cfg_data[0];
            14:rt_zoom<=cfg_data[0];
            default:;
        endcase
        if(cfg_addr>=256 && cfg_addr<304) begin
            if(cfg_addr[3:0]==0) rt_counts[(cfg_addr-256)>>4]<=cfg_data[3:0];
            if(cfg_addr[3:0]==1) rt_maps[(cfg_addr-256)>>4]<=cfg_data[6:0];
        end
        if(cfg_addr>=320 && cfg_addr<800) begin
            case(cfg_addr[3:0])
                0: begin
                    rt_photos[(cfg_addr-320)>>4]<=cfg_data[6:0];
                    rt_point_photos[(cfg_addr-320)>>4]<=cfg_data[6:0];
                end
                // V3 byte 1 is 0x80 | point resource. Legacy configs retain byte 0.
                1:if(cfg_data[7]) rt_point_photos[(cfg_addr-320)>>4]<=cfg_data[6:0];
                2:rt_x[(cfg_addr-320)>>4][7:0]<=cfg_data;
                3:rt_x[(cfg_addr-320)>>4][9:8]<=cfg_data[1:0];
                4:rt_y[(cfg_addr-320)>>4][7:0]<=cfg_data;
                5:rt_y[(cfg_addr-320)>>4][9:8]<=cfg_data[1:0];
                default:;
            endcase
        end
        if(cfg_addr>=832 && cfg_addr<848) rt_playlist[cfg_addr-832]<=cfg_data[6:0];
    end
function[3:0] cfg_room_count;
    input [1:0] f;
    begin
        cfg_room_count=RUNTIME_CONFIG?rt_counts[f]:site_room_count(f);
    end
endfunction
function[9:0] cfg_point_x;
    input [4:0] r;
    begin
        cfg_point_x=RUNTIME_CONFIG?rt_x[r]:site_point_x(r);
    end
endfunction
function[9:0] cfg_point_y;
    input [4:0] r;
    begin
        cfg_point_y=RUNTIME_CONFIG?rt_y[r]:site_point_y(r);
    end
endfunction
function[6:0] cfg_map_id;
    input [1:0] f;
    begin
        cfg_map_id=RUNTIME_CONFIG?rt_maps[f]:{5'd0,site_map_slot(f)};
    end
endfunction
function[6:0] cfg_photo_id;
    input [4:0] r;
    begin
        cfg_photo_id=RUNTIME_CONFIG?rt_photos[r]:{5'd0,site_photo(r)};
    end
endfunction
