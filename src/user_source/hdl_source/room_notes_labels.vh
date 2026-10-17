function[7:0] notes_label_char;
    input [5:0] index;
    begin
        case(index)
            6'd0:notes_label_char=8'd19;
            6'd1:notes_label_char=8'd20;
            6'd2:notes_label_char=8'd21;
            6'd3:notes_label_char=8'd22;
            6'd16:notes_label_char=8'd23;
            6'd17:notes_label_char=8'd24;
            6'd18:notes_label_char=8'd25;
            6'd19:notes_label_char=8'd26;
            6'd32:notes_label_char=8'd23;
            6'd33:notes_label_char=8'd24;
            6'd34:notes_label_char=8'd27;
            6'd35:notes_label_char=8'd28;
            6'd36:notes_label_char=8'd25;
            6'd37:notes_label_char=8'd26;
            default:notes_label_char=0;
        endcase
    end
endfunction
