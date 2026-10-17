// Geometry selects a text source and character position. Decode only after
// the existing first pipeline register; do not put every text table in the
// pixel-coordinate/region-priority path. Kind 0 is a literal glyph ID.
function [12:0] request_message;
    input [3:0] message;
    input [5:0] position;
    begin
        request_message={3'd1,message,position};
    end
endfunction
function [12:0] request_ui;
    input [6:0] index;
    begin
        request_ui={3'd2,3'd0,index};
    end
endfunction
function [12:0] request_map;
    input [6:0] index;
    begin
        request_map={3'd3,3'd0,index};
    end
endfunction
function [12:0] request_status;
    input [4:0] index;
    begin
        request_status={3'd4,5'd0,index};
    end
endfunction
function [12:0] request_room;
    input [7:0] index;
    begin
        request_room={3'd5,2'd0,index};
    end
endfunction
function [12:0] request_floor;
    input [4:0] index;
    begin
        request_floor={3'd6,5'd0,index};
    end
endfunction
function [6:0] decode_text_request;
    input [12:0] request;
    begin
        case(request[12:10])
            3'd0: decode_text_request=request[6:0];
            3'd1: decode_text_request=message_char(request[9:6],request[5:0]);
            3'd2: decode_text_request=site_ui_char(request[6:0]);
            3'd3: decode_text_request=site_map_char(request[6:0]);
            3'd4: decode_text_request=site_status_char(request[4:0]);
            3'd5: decode_text_request=site_room_char(request[7:0]);
            3'd6: decode_text_request=site_floor_char(request[4:0]);
            default: decode_text_request=0;
        endcase
    end
endfunction
