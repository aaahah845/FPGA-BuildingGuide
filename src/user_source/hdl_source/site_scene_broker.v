`include "carousel_timeline.v"
// VIDEO-domain transaction owner. A late image response cannot change the
// current selection. Submitted scenes stay immutable until reader handoff.
// ============================================================================
// site_scene_broker：场景调度器（video_clk）
//
// 三个 key（22 位：主图 ID、照片 ID、需要照片、楼层、房间、地图页）
//   wanted_key    组合逻辑，随用户操作实时变化。只移动索引光标且未开详情时，
//                 房间字段清零，因此不触发加载（index_cursor_only）。
//   request_key   发出请求时快照一次，事务在途期间保持不变。
//   committed_key 只有结果成功且仍等于 wanted_key 时才更新。
//
// 一笔事务（与 sd_site_assets 之间，均为 toggle 加保持数据）
//   1. 空闲、无动画、wanted≠committed 且非刚失败目标 → 翻转 request_toggle；
//   2. 资源管理器翻转 response_toggle，附带 ok 与槽号；
//   3. 本模块只在帧请求时刻裁决（预取除外），翻转 decision_toggle：
//      成功且目标一致且动画到达交接点 → 提交，scene_tag 更新为本笔 tag；
//      失败或已过时 → 不提交，保留旧画面；仅动画未到交接点 → 下帧再判。
//   4. 读控制器锁存新描述后回报 applied_tag，资源管理器才释放旧槽保护。
//
// 预取：前台空闲且 wanted==committed 时，按上下文依次请求 3~4 个候选
//   （hint0~hint3），request_keep 携带整组候选防止互相淘汰；预取结果只进缓存，
//   不会提交上屏。上下文变化时 prefetch_step 归零重新开始。
//
// 动画：页面切换（横向 800 像素）与楼层切换（地图区纵向 480 像素）共约 30 帧。
//   新图加载成功后才开始：第 1~12 帧旧画面离场，离场到底时提交，第 13~29 帧
//   新画面入场；离场途中用户改了目标则倒放回原位。读卡等待期间旧画面不动。
//   轮播换图另有 30 帧滑动（slide_anim）。
// 大图：全画面淡到黑色后切换 full，等待读控制器接管对应模式，再淡入。
// bg 输出恒为 0；照片仍使用已提交的详情槽位，不创建额外资源事务。
// ============================================================================
module site_scene_broker #(
    parameter RUNTIME_CONFIG=1,CLK_FREQ_HZ=25000000,EASED_TRANSITIONS=1
)(
    input clk,rst,site_ready,background_ready,frame_request,
    input carousel_native_requested,
    output reg carousel_native,
    output reg [4:0] layout_alpha,
    output [12:0] scene_motion,
    output wire transition_busy,
    input [36:0] requested_view,
    input [13:0] requested_scale,
    output reg [36:0] map_view,
    output reg [13:0] map_scale,
    input cfg_we,
    input [12:0] cfg_addr,
    input [7:0] cfg_data,
    input [1:0] floor_idx,
    input [3:0] room_idx,
    input map_requested,zoom_requested,pan_requested,
    input floor_selecting,
    input [1:0] floor_cursor,
    input [2:0] cached_maps,
    output wire map_entry_ready,
    input map_entry_pending,
    output wire map_loading,
    input nearest_room_valid,
    input [3:0] nearest_room_idx,
    input [8:0] origin_x,
    input [7:0] origin_y,
    input detail_requested,full_requested,next_pulse,auto_toggle_pulse,
    input reader_full_applied,
    output reg [4:0] photo_view_alpha,
    output wire photo_view_active,
    output reg request_prefetch,
    output wire prefetch_cancel,
    output reg [31:0] request_keep,
    output reg request_toggle,
    output reg [6:0] request_primary,request_photo,
    output reg request_need_photo,
    output reg [7:0] request_tag,
    input image_loading,
    input [6:0] loading_resource,
    output wire visible_loading,
    input response_toggle,response_ok,
    input [2:0] response_primary,response_photo,
    output reg decision_toggle,decision_accept,
    output reg ready,full,
    output reg [7:0] panel_height,scene_tag,
    output reg [2:0] slide,photo,
    output reg [1:0] floor,
    output wire [2:0] bg,
    output reg [3:0] room,
    output reg map_mode,map_zoom,map_pan,
    output reg [2:0] map_slot,
    output reg [8:0] map_x,
    output reg [7:0] map_y,
    output reg slide_anim,
    output reg [4:0] slide_phase,
    output reg [2:0] slide_old,
    output reg auto_play_en,
    output wire loading,
    output reg load_error,
    output reg [6:0] carousel_image_id,
    output wire [12:0] carousel_progress
);
`include "guide_site_config.vh"
wire rt_clk=clk;
`include "runtime_site_fields.vh"
reg [1:0] motion_state;
reg motion_vertical,motion_negative;
reg [9:0] motion_distance;
reg [4:0] motion_frame;
reg motion_rewind;
`include "eased_motion_table.vh"
reg layout_fading_out;
wire layout_busy=layout_fading_out || !layout_alpha[4];
assign transition_busy=motion_state!=0 || layout_busy;
assign scene_motion={motion_vertical,motion_negative,(motion_state!=0),motion_distance};
reg frame_d,outstanding,failed,cancel_issued;
reg queued_next;
reg animation_photo_pending,animation_prefetch;
reg [2:0] prefetch_step;
reg [3:0] floor_prefetch_frames;
reg [29:0] prefetch_context,request_prefetch_context;
reg [21:0] request_key,committed_key,failed_key;
reg [4:0] slide_number;
reg [31:0] auto_count,interval;
wire need_photo=detail_requested || panel_height!=0;
wire [4:0] wanted_room=floor_idx*5'd10+room_idx;
wire [6:0] wanted_primary=map_requested?(RUNTIME_CONFIG?rt_maps[floor_idx]:{5'd0,site_map_slot(floor_idx)}):rt_playlist[slide_number];
// Page context selects the resource before transaction identity, loading,
// prefetch and protection are computed. Physical slots remain independent.
wire [6:0] wanted_photo=RUNTIME_CONFIG?(map_requested?rt_point_photos[wanted_room]:rt_photos[wanted_room]):{5'd0,site_photo(wanted_room)};
// A closed index detail has no photo/floor/room image dependency.
wire index_cursor_only=!map_requested && !need_photo;
// wanted_key 位段：[21:15] 主图 ID，[14:8] 照片 ID，[7] 需要照片，[6:5] 楼层，
// [4:1] 房间，[0] 地图页。只移动索引光标时低 15 位清零，不引起加载。
wire [21:0] wanted_key={wanted_primary,index_cursor_only?15'd0:{wanted_photo,need_photo,floor_idx,room_idx,map_requested}};
// 本笔请求是否会换页面或换楼层地图（需要先播放离场动画）
wire scene_change=ready && (request_key[0]!=map_mode || (request_key[0] && request_key[6:5]!=floor));
// 前景请求成功且目标仍是用户当前想看的
wire successful_response=outstanding && !request_prefetch && response_toggle==request_toggle && response_ok && wanted_key==request_key;
// 提交门限：不换场景可直接提交；换场景要等旧画面完全离场（位移到 800 或 480）
wire response_gate=!scene_change || (motion_state==1 && motion_distance==(motion_vertical?480:800));
wire [4:0] next_slide=slide_number+1>=rt_slide_count?0:slide_number+1'b1;
wire [3:0] room_count=RUNTIME_CONFIG?rt_counts[floor_idx]:site_room_count(floor_idx);
wire [3:0] next_room=room_idx+1>=room_count?4'd0:room_idx+1'b1;
// Keep the existing two lookup ports. Compute both possible addresses
// before the wrap selection so the room-count path avoids an adder.
wire [4:0] following_room_id=wanted_room+5'd1;
wire [4:0] first_room_id=floor_idx*5'd10;
wire [4:0] next_room_id=room_idx+1>=room_count?first_room_id:following_room_id;
wire [6:0] next_photo=RUNTIME_CONFIG?(map_requested?rt_point_photos[next_room_id]:rt_photos[next_room_id]):{5'd0,site_photo(next_room_id)};
wire selecting_floor=map_requested && floor_selecting;
wire [1:0] next_floor=floor_idx==cfg_floors-1?2'd0:floor_idx+1'b1;
wire [1:0] hint_floor=selecting_floor?((floor_cursor==floor_idx)?next_floor:floor_cursor):map_requested?next_floor:floor_idx;
// Index: carousel + current/next room + next carousel + two-slot map.
// Floor selection: current/target maps + current point + return carousel.
// Point browsing: current map + current/next points + return carousel.
// Protect the entire desired set, including hints not yet visited this pass:
// protecting only a prefix can evict a warm next image before its lookup.
wire pending_map=map_entry_pending && !map_requested;
wire [29:0] wanted_prefetch_context={wanted_key,selecting_floor,hint_floor,pending_map,room_idx};
wire prefetch_context_changed=prefetch_context!=wanted_prefetch_context;
wire [6:0] cursor_map=RUNTIME_CONFIG?rt_maps[hint_floor]:{5'd0,site_map_slot(hint_floor)};
wire [6:0] current_map=RUNTIME_CONFIG?rt_maps[floor_idx]:{5'd0,site_map_slot(floor_idx)};
wire [2:0] prefetch_count=map_requested?3'd3:3'd4;
// 预取候选（按优先级）：
//   索引页           下一张轮播 → 本层地图 → 本房照片 → 下一房照片
//   索引页等待进地图  本层地图 → 下一张轮播 → 本房照片 → 下一房照片
//   地图楼层选择      光标楼层地图 → 观察点照片 → 返回用轮播
//   地图选点          本点照片 → 下一点照片 → 返回用轮播
// 光标停在本层时 hint_floor 取下一层，预取下一层地图。
wire [6:0] hint0=map_requested?(selecting_floor?cursor_map:wanted_photo):(pending_map?current_map:rt_playlist[next_slide]);
wire [6:0] hint1=map_requested?(selecting_floor?wanted_photo:next_photo):(pending_map?rt_playlist[next_slide]:current_map);
wire [6:0] hint2=map_requested?rt_playlist[slide_number]:wanted_photo;
wire [6:0] hint3=next_photo;
reg [6:0] prefetch_id;
wire [31:0] prefetch_keep_ids=map_requested?{4'b0111,7'd0,hint2,hint1,hint0}:
    {4'b1111,hint3,hint2,hint1,hint0};
always @*
    case(prefetch_step)
        0:prefetch_id=hint0;
        1:prefetch_id=hint1;
        2:prefetch_id=hint2;
        default:prefetch_id=hint3;
    endcase
wire prefetch_duplicate=prefetch_id==wanted_primary || (need_photo && prefetch_id==wanted_photo) ||
    (prefetch_step>0 && prefetch_id==hint0) || (prefetch_step>1 && prefetch_id==hint1) ||
    (prefetch_step>2 && prefetch_id==hint2);
// A cursor move may cancel a speculative load even when the foreground key
// is unchanged. Confirming that same map promotes it instead of aborting it.
// Keep the original request stable until cancellation/completion responds.
// Foreground room changes may cancel an obsolete PHOTO phase as well.
// The loader gates this branch by phase, so a still-needed primary finishes.
wire hint_in_set=request_primary==hint0 || request_primary==hint1 || request_primary==hint2 ||
    (prefetch_count==4 && request_primary==hint3) ||
    (animation_prefetch && request_primary==next_photo);
// A newly selected map takes priority over a still-running photo hint.
// New foreground content preempts hints unless the resource is promoted
// to that foreground primary/photo by the exceptions below.
// Starting/cancelling a pending entry must not restart its same map.
// Room-only changes may leave that map running; a due carousel or opened
// detail still preempts it to keep the visible index usable.
wire same_index_map=!map_requested && request_primary==current_map &&
    !need_photo && !request_key[0] && request_key[21:15]==wanted_primary;
wire hint_still_wanted=hint_in_set && (wanted_key==request_key || same_index_map) &&
    !(pending_map && request_prefetch_context!=wanted_prefetch_context && request_primary!=current_map) && !(selecting_floor &&
    request_prefetch_context!=wanted_prefetch_context && request_primary!=cursor_map);
assign prefetch_cancel=outstanding &&
    (request_prefetch?(cancel_issued || (!hint_still_wanted && request_primary!=wanted_primary &&
    !(need_photo && request_primary==wanted_photo))):
    (wanted_key!=request_key && request_need_photo && request_primary==wanted_primary &&
    request_photo!=wanted_photo && request_photo!=wanted_primary));
// Index cursor metadata does not acquire image slots or wait on SD.
wire index_metadata_only=ready && index_cursor_only && !map_mode && !committed_key[7];
wire same_selection=map_requested==map_mode && floor_idx==floor && room_idx==room;
// Opacity is the contribution of the native photo: zero retains detail,
// sixteen is the settled full view. Every intermediate frame carries both.
assign photo_view_active=photo_view_alpha!=0;
wire photo_pause=full_requested || photo_view_active;
wire photo_full_target=full_requested && detail_requested && same_selection &&
    committed_key[7] && ready && panel_height==8'd210 && !transition_busy && !slide_anim;
// Controls keep the index request active until its target is resident and
// no foreground/animation/mailbox handoff can still evict or retarget it.
assign map_entry_ready=ready && !map_mode && cached_maps[floor_idx] &&
    !loading && !transition_busy && !slide_anim && !outstanding;
wire timeline_busy;
wire carousel_wait=!ready || (!map_requested && wanted_primary!=committed_key[21:15]);
wire auto_due=!photo_pause && !map_requested && !transition_busy && !loading && !timeline_busy && auto_play_en && auto_count>=interval-1;
wire advance_slide=!photo_pause && !slide_anim && !map_requested && (next_pulse || queued_next || auto_due);
// Only change layout while its content is invisible. Old/new geometry and
// reader descriptor still change together at the normal frame boundary.
always @(posedge clk or posedge rst) begin
    if(rst) begin carousel_native<=0;layout_alpha<=16;layout_fading_out<=0;end
    else if(frame_request && !frame_d) begin
        if(layout_fading_out) begin
            if(layout_alpha!=0) layout_alpha<=layout_alpha-1'b1;
            else begin carousel_native<=carousel_native_requested;layout_fading_out<=0;end
        end else if(!layout_alpha[4]) layout_alpha<=layout_alpha+1'b1;
        else if(ready && !map_mode && !map_requested && motion_state==0 && !slide_anim &&
                panel_height==0 && !detail_requested && !outstanding && !advance_slide &&
                wanted_key==committed_key && carousel_native!=carousel_native_requested)
            layout_fading_out<=1;
    end
end

carousel_timeline #(
    .CLK_FREQ_HZ(CLK_FREQ_HZ)
) timeline(
    .clk(clk),
    .rst(rst),
    .frame_tick(frame_request && !frame_d),
    .enabled(site_ready && !photo_pause && !map_requested && auto_play_en),
    .waiting(carousel_wait),
    .animating(slide_anim),
    .failed(load_error),
    .restart(advance_slide),
    .expired(auto_due),
    .elapsed(auto_count),
    .interval(interval),
    .progress(carousel_progress),
    .cycle_busy(timeline_busy)
);
// Scene handoff/cache hit is not an SD load. Suppress speculative resources
// unless the current visible request has promoted that same image.
assign visible_loading=loading && image_loading &&
    (loading_resource==wanted_primary || (need_photo && loading_resource==wanted_photo));
// Surface actual background map I/O as well as an explicitly queued entry.
assign map_loading=ready && !map_mode &&
    ((pending_map && !cached_maps[floor_idx]) || (image_loading && loading_resource==current_map));
assign bg=0;
assign loading=site_ready && (!ready || wanted_key!=committed_key) && !load_error;
always @*
    case(cfg_period)
        0:interval=CLK_FREQ_HZ*5;
        1:interval=CLK_FREQ_HZ*2;
        2:interval=CLK_FREQ_HZ*10;
        default:interval=CLK_FREQ_HZ*30;
    endcase
always @(posedge clk or posedge rst) begin
    if(rst) begin
        motion_state<=0;
        motion_vertical<=0;
        motion_negative<=0;
        motion_distance<=0;
        motion_frame<=0;
        motion_rewind<=0;
        map_view<={14'd4096,12'd640,11'd480};
        map_scale<=4096;
        slide_anim<=0;
        slide_phase<=0;
        slide_old<=0;
        queued_next<=0;
        animation_photo_pending<=0;
        animation_prefetch<=0;
        request_prefetch<=0;
        request_keep<=0;
        prefetch_step<=0;
        floor_prefetch_frames<=0;
        prefetch_context<=0;
        request_prefetch_context<=0;
        frame_d<=0;
        outstanding<=0;
        failed<=0;
        cancel_issued<=0;
        request_key<=0;
        committed_key<=0;
        failed_key<=0;
        request_toggle<=0;
        request_primary<=0;
        request_photo<=0;
        request_need_photo<=0;
        request_tag<=0;
        decision_toggle<=0;
        decision_accept<=0;
        ready<=0;
        full<=0;
        photo_view_alpha<=0;
        panel_height<=0;
        scene_tag<=0;
        slide<=0;
        photo<=0;
        floor<=0;
        room<=0;
        map_mode<=1;
        map_zoom<=0;
        map_pan<=0;
        map_slot<=0;
        map_x<=0;
        map_y<=0;
        auto_play_en<=0;
        auto_count<=0;
        slide_number<=0;
        load_error<=0;
        carousel_image_id<=0;
    end else begin
        frame_d<=frame_request;
        if(site_ready) begin
            // ---- 页面/楼层切换动画，每帧推进一次 ----
            // motion_state 0 空闲：新图已加载成功（successful_response）且需换场景时才启动；
            // 1 旧画面离场（第 1~12 帧）；期间若用户改了目标，结果不再匹配，转 2 倒放；
            // 2 新画面入场（离场到底、提交后从第 13 帧走到第 29 帧），或倒放回原位。
            if(frame_request && !frame_d) begin
                if(EASED_TRANSITIONS) begin
                    if(motion_state==0 && successful_response && scene_change && panel_height==0) begin
                        motion_state<=1;
                        motion_vertical<=request_key[0]==map_mode;
                        motion_negative<=request_key[0] || map_mode==request_key[0];
                        motion_frame<=1;
                        motion_rewind<=0;
                        motion_distance<=eased_scene_distance(5'd1,request_key[0]==map_mode);
                    end else if(motion_state==1) begin
                        if(!successful_response) begin
                            motion_state<=2;
                            motion_rewind<=1;
                        end else if(motion_frame<5'd12) begin
                            motion_frame<=motion_frame+1'b1;
                            motion_distance<=eased_scene_distance(motion_frame+1'b1,motion_vertical);
                        end
                    end else if(motion_state==2) begin
                        if(motion_rewind) begin
                            if(motion_frame<=1) begin
                                motion_state<=0;
                                motion_distance<=0;
                                motion_frame<=0;
                            end else begin
                                motion_frame<=motion_frame-1'b1;
                                motion_distance<=eased_scene_distance(motion_frame-1'b1,motion_vertical);
                            end
                        end else if(motion_frame>=29) begin
                            motion_state<=0;
                            motion_distance<=0;
                            motion_frame<=0;
                        end else begin
                            motion_frame<=motion_frame+1'b1;
                            motion_distance<=eased_scene_distance(motion_frame+1'b1,motion_vertical);
                        end
                    end
                end else begin
                    if(motion_state==0 && successful_response && scene_change && panel_height==0) begin
                        motion_state<=1;
                        motion_vertical<=request_key[0]==map_mode;
                        motion_negative<=request_key[0] || map_mode==request_key[0];
                        motion_distance<=request_key[0]==map_mode?60:100;
                    end else if(motion_state==1) begin
                        if(!successful_response) begin
                            motion_state<=2;
                        end else if(motion_distance<(motion_vertical?480:800)) motion_distance<=motion_distance+(motion_vertical?60:100);
                    end else if(motion_state==2) begin
                        if(motion_distance<=(motion_vertical?60:100)) begin
                            motion_state<=0;
                            motion_distance<=0;
                        end else motion_distance<=motion_distance-(motion_vertical?60:100);
                    end
                end
            end
            if(outstanding && prefetch_cancel) cancel_issued<=1;
            if(wanted_key!=committed_key || !map_requested || selecting_floor) animation_photo_pending<=0;
            if(auto_toggle_pulse) auto_play_en<=!auto_play_en;
            // Preserve elapsed time while a native photo is requested or fading.
            // A slide already underway finishes before the photo fade can start.
            if(!photo_pause && !map_requested && auto_play_en && !slide_anim && !timeline_busy && !auto_toggle_pulse && auto_count<interval-1)
                auto_count<=auto_count+1'b1;
            // One bounded pending NEXT during animation; never retarget either image.
            if(map_requested) queued_next<=0;
            if(slide_anim) begin
                if(next_pulse && !map_requested && !photo_pause) queued_next<=1;
            end else if(advance_slide) begin
                slide_number<=next_slide;
                auto_count<=0;
                queued_next<=0;
            end

            if(failed && failed_key!=wanted_key) begin
                failed<=0;
                load_error<=0;
            end
            // ---- 发出前景请求 ----
            // 条件：无在途事务、无动画，用户想看的与已提交的不同，且不是刚失败的同一目标。
            // request_key 在此快照，事务结束前不再改变；tag = 当前 scene_tag + 1。
            if(background_ready && !transition_busy && !slide_anim && !outstanding && (!ready || wanted_key!=committed_key) && !(failed && failed_key==wanted_key)) begin
                request_prefetch<=0;
                animation_prefetch<=0;
                request_keep<=0;
                prefetch_step<=0;
                request_toggle<=!request_toggle;
                request_primary<=wanted_primary;
                request_photo<=wanted_photo;
                request_need_photo<=need_photo;
                // Advance from the committed scene, not from discarded requests. Even an
                // unlimited run of discarded loads can never alias the active reader tag.
                request_key<=wanted_key;
                request_tag<=scene_tag+1'b1;
                outstanding<=1;
                cancel_issued<=0;
            end
            // Match the old floor-selector policy: target map immediately, lower
            // priority photo/carousel hints after twelve stable frames.
            if(frame_request && !frame_d) begin
                if(transition_busy || loading || !selecting_floor) floor_prefetch_frames<=0;
                else if(floor_prefetch_frames<12) floor_prefetch_frames<=floor_prefetch_frames+1'b1;
            end
            // Start useful prefetch as soon as the foreground handoff completes.
            // Index/point browsing have no extra dwell; floor selection retains its old delay.
            // After the map commits, use its return animation to prepare the NEXT point.
            // The optional hint survives the animation ending, but not a context change.
            // The manager still waits for reader handoff before reusing any old slot.
            if(background_ready && ready && motion_state==2 && animation_photo_pending &&
                !outstanding && wanted_key==committed_key && map_requested && !selecting_floor) begin
                    request_prefetch<=1;
                    animation_prefetch<=1;
                    request_toggle<=!request_toggle;
                    request_primary<=next_photo;
                    request_photo<=0;
                    request_need_photo<=0;
                    request_tag<=scene_tag;
                    request_key<=wanted_key;
                    outstanding<=1;
                    cancel_issued<=0;
                    request_prefetch_context<=wanted_prefetch_context;
                    request_keep<=prefetch_keep_ids;
                    animation_photo_pending<=0;
                end
            // ---- 发出预取请求 ----
            // 前台完全空闲（wanted==committed）时按 hint0~hint3 依次尝试，重复项跳过；
            // 楼层选择中低优先级候选要等光标停留 12 帧。预取用当前 scene_tag，永不提交。
            if(background_ready && ready && !transition_busy && !slide_anim && !outstanding && wanted_key==committed_key &&
                !prefetch_context_changed && (!selecting_floor || prefetch_step==0 || floor_prefetch_frames==12) && prefetch_step<prefetch_count) begin
                    if(!prefetch_duplicate) begin
                        request_prefetch<=1;
                        animation_prefetch<=0;
                        request_toggle<=!request_toggle;
                        request_primary<=prefetch_id;
                        request_photo<=0;
                        request_need_photo<=0;
                        request_tag<=scene_tag;
                        request_key<=wanted_key;
                        outstanding<=1;
                        cancel_issued<=0;
                        request_prefetch_context<=wanted_prefetch_context;
                        // Retain higher-priority hints needed by this interaction.
                        request_keep<=prefetch_keep_ids;
                    end
                    prefetch_step<=prefetch_step+1'b1;
                end
            // A response is only accepted at a video frame request. The manager keeps
            // the old + pending reservations until the resulting tag reaches SDRAM read.
            // ---- 裁决应答（decision） ----
            // 预取：立即结束，decision_accept=0（只留在缓存里）。
            // 前景：只在帧请求时刻裁决。失败或已过时 → 拒绝；成功且到达提交门限 → 接受，
            // 一次性更新槽号、楼层、房间、地图视野与 scene_tag；成功但门限未到 → 下帧再判。
            if(outstanding && response_toggle==request_toggle && (request_prefetch || (frame_request && !frame_d && (!response_ok || wanted_key!=request_key || response_gate)))) begin
                decision_toggle<=request_toggle;
                outstanding<=0;
                if(request_prefetch) begin
                    decision_accept<=0;
                    // If the user returned during abort, retry the cancelled working set.
                    if(!response_ok && cancel_issued && wanted_key==committed_key) prefetch_step<=0;
                end else if(response_ok && wanted_key==request_key) begin
                    if(scene_change) begin
                        motion_state<=2;
                        motion_negative<=!motion_negative;
                        if(EASED_TRANSITIONS) begin
                            motion_frame<=5'd13;
                            motion_rewind<=0;
                            motion_distance<=eased_scene_distance(5'd13,motion_vertical);
                        end
                    end
                    if(scene_change && request_key[0] && !selecting_floor) begin
                        animation_photo_pending<=1;
                    end
                    decision_accept<=1;
                    committed_key<=request_key;
                    ready<=1;
                    scene_tag<=request_tag;
                    load_error<=0;
                    failed<=0;
                    // Only animate a ready-to-ready carousel image change in the index page.
                    // Both slots remain in the reader's applied mask until the final frame.
                    if(ready && !map_mode && !map_requested && !full &&
                        committed_key[21:15]!=request_key[21:15] && response_primary!=slide) begin
                            slide_old<=slide;
                            slide_phase<=1;
                            slide_anim<=1;
                        end
                    slide<=response_primary;
                    map_slot<=response_primary;
                    photo<=response_photo;
                    floor<=floor_idx;
                    room<=room_idx;
                    map_mode<=map_requested;
                    map_view<=requested_view;
                    map_scale<=requested_scale;
                    map_zoom<=zoom_requested;
                    map_pan<=pan_requested;
                    map_x<=origin_x;
                    map_y<=origin_y;
                    if(!map_requested) carousel_image_id<=wanted_primary;
                end else begin
                    decision_accept<=0;
                    if(!response_ok && wanted_key==request_key && !cancel_issued && !prefetch_cancel) begin
                        failed<=1;
                        failed_key<=request_key;
                        load_error<=1;
                    end
                end
            end
            if(frame_request && !frame_d) begin
                if(index_metadata_only && !transition_busy) begin
                    floor<=floor_idx;
                    room<=room_idx;
                end
                if(slide_anim) begin
                    if(map_requested || slide_phase>=(EASED_TRANSITIONS?29:19)) begin
                        slide_anim<=0;
                        slide_phase<=0;
                    end else slide_phase<=slide_phase+1'b1;
                end
                // Direct crossfade, with no blank or black interstitial frame.
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
                if(!detail_requested) begin
                    if(!photo_view_active && panel_height!=0) panel_height<=panel_height-21;
                end else if(!transition_busy && same_selection && committed_key[7] && ready && panel_height<210) panel_height<=panel_height+21;
                if(same_selection) begin
                    map_view<=requested_view;
                    map_scale<=requested_scale;
                    map_zoom<=zoom_requested;
                    map_pan<=pan_requested;
                    map_x<=origin_x;
                    map_y<=origin_y;
                end
            end
            // Context changes restart the candidate pass after the current mailbox drains.
            if(prefetch_context_changed) begin
                prefetch_context<=wanted_prefetch_context;
                floor_prefetch_frames<=0;
                // Selection changes priority; already cached resources remain cache hits.
                prefetch_step<=0;
            end
        end
    end
end
endmodule
