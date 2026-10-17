"""One-shot, exact replacements against the preserved black-transition copy."""
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / 'src/user_source/hdl_source'
def edit(name, changes):
    p = SRC / name
    s = p.read_text(encoding='utf-8')
    for before, after in changes:
        assert s.count(before) == 1, (name, before[:100], s.count(before))
        s = s.replace(before, after)
    p.write_text(s, encoding='utf-8', newline='\n')

edit('SD/bilinear_span_cache.v', [
('module bilinear_span_cache(', 'module bilinear_span_cache #(parameter CROSSFADE_SUPPORT=0)('),
('    input clk,rst,clear,', '''    input clk,rst,clear,
    input blend_write,blend_read,
    input [6:0] blend_index,
    input [31:0] blend_data,
    output [15:0] blend_pixel,'''),
('    if(top_written) top_words[number3]<={hr3,hg3,hb3};', '''    if(CROSSFADE_SUPPORT && blend_write)
        top_words[{1'b1,blend_index}]<={20'd0,blend_data[31:27],blend_data[23:18],blend_data[15:11]};
    else if(top_written) top_words[number3]<={hr3,hg3,hb3};'''),
('    top_q<=top_words[number2];', '''    top_q<=top_words[(CROSSFADE_SUPPORT && blend_read)?{1'b1,blend_index}:number2];
assign blend_pixel=top_q[15:0];'''),
])

edit('SD/scene_frame_reader.v', [
('parameter DYNAMIC_GEOMETRY=0,SCATTERED_SLOTS=0,BILINEAR_SUPPORT=0,EASED_TRANSITIONS=1',
 'parameter DYNAMIC_GEOMETRY=0,SCATTERED_SLOTS=0,BILINEAR_SUPPORT=0,EASED_TRANSITIONS=1,CROSSFADE_SUPPORT=0'),
('    input photo_full,', '    input photo_full,photo_blend,'),
('reg [108:0] desc_meta,desc_sync,desc_stage,desc;', '''reg [109:0] desc_meta,desc_sync,desc_stage,desc;
reg overlay_pass,blend_inside;
reg [9:0] blend_end;
wire blend_capture=desc[109] && blend_inside && !overlay_pass;
wire layout_full=desc[17] || overlay_pass;
wire [15:0] blend_pixel;'''),
('wire [108:0] descriptor={BILINEAR_SUPPORT', 'wire [109:0] descriptor={CROSSFADE_SUPPORT && photo_blend,BILINEAR_SUPPORT'),
('wire filter_active=BILINEAR_SUPPORT && desc[108] && (mode==SHRINK || mode==ZOOM);', '''// Mixed frames use nearest sampling for the retained detail layer. This
// leaves the existing interpolation scratch RAM available and bounds SDRAM
// bandwidth while two layouts are read. Stable views keep the selected filter.
wire filter_active=BILINEAR_SUPPORT && desc[108] && !desc[109] && (mode==SHRINK || mode==ZOOM);'''),
('    fast_span<=next_x<edge_reg && next_x<10\'d800;', '    fast_span<=!desc[109] && next_x<edge_reg && next_x<10\'d800;'),
('    if(desc[17]) begin', '    if(layout_full) begin'),
('    // The hit tests were registered', '''    // A mixed span must lie completely inside or outside the native photo.
    // The second pass reuses exactly the first pass length and scratch indices.
    if(desc[109] && !overlay_pass && full_row) begin
        if(vx<80 && edge_x>80) edge_x=80;
        else if(vx<720 && edge_x>720) edge_x=720;
    end
    if(overlay_pass && edge_x>blend_end) edge_x=blend_end;
    // The hit tests were registered'''),
('bilinear_span_cache filter_cache(', '''bilinear_span_cache #(.CROSSFADE_SUPPORT(CROSSFADE_SUPPORT)) filter_cache(
    .blend_write(push_pixel && blend_capture),.blend_read(overlay_pass),
    .blend_index(emitted[6:0]),.blend_data(push_data),.blend_pixel(blend_pixel),'''),
('reg pixel_pending;\nreg [31:0] pixel_data;\nassign fifo_we=pixel_pending && !fifo_clear;\nassign fifo_data=pixel_data;', '''reg pixel_pending,pixel_paired,pixel_overlay;
reg [31:0] pixel_data;
wire [15:0] packed_pixel={pixel_data[31:27],pixel_data[23:18],pixel_data[15:11]};
assign fifo_we=pixel_pending && !fifo_clear;
// Only transition frames carry two RGB565 pixels in the existing 32-bit FIFO.
// Normal detail and the settled full photo retain the original RGB888 word.
assign fifo_data=!pixel_paired?pixel_data:
    pixel_overlay?{blend_pixel,packed_pixel}:{packed_pixel,16'hffbe};
always @(posedge clk) begin
    pixel_paired<=desc[109];
    pixel_overlay<=overlay_pass;
end'''),
('    else pixel_pending<=push_pixel;', '    else pixel_pending<=push_pixel && !blend_capture;'),
('|| (state[9] && !req_sync[1] && next_x==800 && y==599);', '|| (state[9] && !req_sync[1] && !blend_capture && next_x==800 && y==599);'),
('assign ns[16]=state[13] || (state[9] && !req_sync[1] && !fast_span && !(next_x==800 && y==599));',
 'assign ns[16]=state[13] || (state[9] && !req_sync[1] && (blend_capture || (!fast_span && !(next_x==800 && y==599))));'),
('        photo_hit<=0;', '''        overlay_pass<=0;
        blend_inside<=0;
        blend_end<=0;
        photo_hit<=0;'''),
('                desc<=desc_stage;', '                desc<=desc_stage;\n                overlay_pass<=0;'),
('                photo_row<=!desc[17]', '                photo_row<=!layout_full'),
('                full_hit<=desc[17]', '                blend_inside<=vy>=60 && vy<540 && vx>=80 && vx<720;\n                full_hit<=layout_full'),
('                photo_hit<=!desc[17]', '                photo_hit<=!layout_full'),
('                map_hit<=!desc[17]', '                map_hit<=!layout_full'),
('                carousel_hit<=!desc[17]', '                carousel_hit<=!layout_full'),
('span_pixels<=edge_delta<(filter_active?128:64)?edge_delta:(filter_active?128:64);',
 'span_pixels<=edge_delta<((filter_active || overlay_pass)?128:64)?edge_delta:((filter_active || overlay_pass)?128:64);'),
('''            end else if(next_x==800) begin
                x<=0;''', '''            end else if(blend_capture) begin
                overlay_pass<=1;
                blend_end<=next_x;
            end else if(next_x==800) begin
                overlay_pass<=0;
                x<=0;'''),
('''            end else begin
                x<=next_x;''', '''            end else begin
                overlay_pass<=0;
                x<=next_x;'''),
])

edit('SD/frame_read_write.v', [
(' input scene_ready,photo_full,', ' input scene_ready,photo_full,photo_blend,'),
('.DYNAMIC_GEOMETRY(1),.SCATTERED_SLOTS(1),.BILINEAR_SUPPORT(1)) u_scene_reader',
 '.DYNAMIC_GEOMETRY(1),.SCATTERED_SLOTS(1),.BILINEAR_SUPPORT(1),.CROSSFADE_SUPPORT(1)) u_scene_reader'),
('.panel_height(scene_panel_height),.photo_full(photo_full),', '.panel_height(scene_panel_height),.photo_full(photo_full),.photo_blend(photo_blend),'),
])

p=SRC/'site_scene_broker.v'
s=p.read_text(encoding='utf-8')
start=s.index('    // The reader\'s synchronized mode') if '    // The reader\'s synchronized mode' in s else s.index('// The reader\'s synchronized mode')
end=s.index('wire photo_pause=',start)
s=s[:start]+'''// Opacity is the contribution of the native photo: zero retains detail,
// sixteen is the settled full view. Every intermediate frame carries both.
assign photo_view_active=photo_view_alpha!=0;
'''+s[end:]
s=s.replace('        photo_view_alpha<=16;\n        photo_fade_state<=PHOTO_IDLE;\n        photo_black_frame<=0;', '        photo_view_alpha<=0;')
start=s.index('                // Change layout only after a fully black frame.')
end=s.index('                if(!detail_requested)',start)
s=s[:start]+'''                // Direct crossfade, with no blank or black interstitial frame.
                // At the frame boundary the reader snapshots full/mixed layout
                // before active scanout, just as it does for panel animations.
                if(photo_full_target && !loading) begin
                    if(photo_view_alpha<16) begin
                        photo_view_alpha<=photo_view_alpha+1'b1;
                        if(photo_view_alpha==15) full<=1;
                    end
                end else if(photo_view_alpha!=0) begin
                    photo_view_alpha<=photo_view_alpha-1'b1;
                    full<=0;
                end
'''+s[end:]
assert 'photo_fade_state' not in s and 'photo_black_frame' not in s
p.write_text(s,encoding='utf-8',newline='\n')

edit('guide_scene_compositor.v', [
('    input wire [4:0] I_photo_view_alpha,', '''    input wire [4:0] I_photo_view_alpha,
    input wire [15:0] I_photo_rgb565,'''),
('reg [23:0] rgb_pre;', '''reg [23:0] rgb_pre;
reg [15:0] photo_v0,photo_pre,photo_d,photo_q2,photo_q3;
reg mix_d,mix_q2,mix_q3;
wire photo_mix=I_photo_view_alpha!=0 && I_photo_view_alpha!=16;
wire [23:0] overlay_rgb={photo_q3[15:11],photo_q3[15:13],photo_q3[10:5],photo_q3[10:9],photo_q3[4:0],photo_q3[4:2]};
always @(posedge I_clk) begin
    photo_v0<=I_photo_rgb565;
    photo_pre<=photo_v0;
    photo_d<=photo_pre;
    photo_q2<=photo_d;
    photo_q3<=photo_q2;
    mix_d<=photo_mix;
    mix_q2<=mix_d;
    mix_q3<=mix_q2;
end'''),
('dim_d<=dim_background || I_photo_view_alpha<16;', 'dim_d<=dim_background;'),
('''        // Reuse the existing per-channel blend, preserving its latency.
        // The already-dimmed background stays at its normal level until
        // the global fade falls below it, so entering a fade never brightens it.
        fade_d<=I_photo_view_alpha<16 ?
            ((dim_background && dim_alpha<I_photo_view_alpha)?dim_alpha:I_photo_view_alpha) :
            (dim_background?dim_alpha:(list_fade_pixel?list_opacity:5'd16));''', '''        // Reuse the existing blend for detail -> native photo. The retained
        // detail panel is fully open, so its outside dim is exactly one half.
        fade_d<=photo_mix ? 5'd16-I_photo_view_alpha :
            (dim_background?dim_alpha:(list_fade_pixel?list_opacity:5'd16));'''),
('            composed_q3<=composed_rgb;', '''            composed_q3<=mix_q2 && dim_q2 ?
                {1'b0,composed_rgb[23:17],1'b0,composed_rgb[15:9],1'b0,composed_rgb[7:1]}:composed_rgb;'''),
('fade_channel(composed_q3[23:16],dim_q3?8\'d0:8\'hf8,fade_q3)', 'fade_channel(composed_q3[23:16],mix_q3?overlay_rgb[23:16]:(dim_q3?8\'d0:8\'hf8),fade_q3)'),
('fade_channel(composed_q3[15:8],dim_q3?8\'d0:8\'hf7,fade_q3)', 'fade_channel(composed_q3[15:8],mix_q3?overlay_rgb[15:8]:(dim_q3?8\'d0:8\'hf7),fade_q3)'),
('fade_channel(composed_q3[7:0],dim_q3?8\'d0:8\'hf5,fade_q3)', 'fade_channel(composed_q3[7:0],mix_q3?overlay_rgb[7:0]:(dim_q3?8\'d0:8\'hf5),fade_q3)'),
])

edit('top_tf_hdmi_audio.v', [
('wire [4:0] photo_view_alpha;', 'wire [4:0] photo_view_alpha;\nwire photo_blend=photo_view_alpha!=0 && photo_view_alpha!=16;\nwire [31:0] video_pixel_packet;'),
('video_delay video_delay_m0(', 'video_delay #(.DATA_WIDTH(32)) video_delay_m0('),
('.read_data (video_read_data[31:8]),', '.read_data (video_read_data),'),
('.vout_data (vout_data_raw)', '.vout_data (video_pixel_packet)'),
('assign vout_data = scene_ready ? vout_data_raw : 24\'d0;', '''assign vout_data_raw=photo_blend ?
    {video_pixel_packet[31:27],video_pixel_packet[31:29],video_pixel_packet[26:21],video_pixel_packet[26:25],video_pixel_packet[20:16],video_pixel_packet[20:18]}:
    video_pixel_packet[31:8];
assign vout_data = scene_ready ? vout_data_raw : 24'd0;'''),
('    .I_photo_view_alpha(photo_view_alpha),', '    .I_photo_view_alpha(photo_view_alpha),\n    .I_photo_rgb565(video_pixel_packet[15:0]),'),
('    .photo_full(scene_full),', '    .photo_full(scene_full),\n    .photo_blend(photo_blend),'),
])
print('Crossfade RTL edits applied in isolated copy.')
