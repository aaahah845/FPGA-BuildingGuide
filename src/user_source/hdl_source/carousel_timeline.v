`ifndef CAROUSEL_TIMELINE_V
`define CAROUSEL_TIMELINE_V
// Same video clock as the broker. Q4 pixels cover the 480-pixel carousel.
// A fixed-point DSP scaler samples the real timer once per frame; no independent
// seconds clock can drift away from the actual slide request.
// 【说明】轮播进度条：间隔 2/5/10/30 s，进度 = 已过时间 × 预先算好的倒数（乘法器，无除法器）。
//         下一张未准备好时进度条停在满格等待；换图时进度条回缩。
module carousel_timeline #(
    parameter integer CLK_FREQ_HZ=40000000
)(
    input clk,rst,frame_tick,enabled,waiting,animating,failed,
    input restart,expired,
    input [31:0] elapsed,interval,
    output reg [12:0] progress,
    output wire cycle_busy
);
reg pending,retracting,anim_d;
reg [12:0] retract_start;
reg [4:0] retract_step;
assign cycle_busy=pending || retracting || animating;
// Compile-time reciprocals for the four supported periods move the scale
// operation to spare DSP resources, avoiding a wide fabric divider.
localparam integer DROP=CLK_FREQ_HZ>=1000000?$clog2(CLK_FREQ_HZ)-13:0;
localparam integer EW=$clog2(64'd30*CLK_FREQ_HZ+1)-DROP;
localparam integer GW=$clog2((64'd7680<<31)/(64'd2*CLK_FREQ_HZ)+1);
localparam [GW-1:0] G2=(64'd7680<<31)/(64'd2*CLK_FREQ_HZ),
    G5=(64'd7680<<31)/(64'd5*CLK_FREQ_HZ),G10=(64'd7680<<31)/(64'd10*CLK_FREQ_HZ),G30=(64'd7680<<31)/(64'd30*CLK_FREQ_HZ);
wire [GW-1:0] gain=interval==CLK_FREQ_HZ*2?G2:interval==CLK_FREQ_HZ*5?G5:interval==CLK_FREQ_HZ*10?G10:G30;
reg [EW-1:0] sample_time;
reg [GW-1:0] sample_gain;
reg [EW+GW-1:0] product;
reg [1:0] calc_pipe;
wire [EW+GW-1:0] scaled_progress=product>>(31-DROP);
// Original 9-frame half-life curve, interpolated every frame: 18 frames,
// twice the duration without reducing the visible refresh rate.
wire [12:0] retract_level=retract_start>>(retract_step>>1);
wire [12:0] next_retract=retract_step[0]?(retract_level-(retract_level>>2)):retract_level;
wire eligible=enabled && !waiting && !animating && !failed && !pending && !retracting;
always @(posedge clk or posedge rst) begin
    if(rst) begin
        progress<=0;
        pending<=0;
        retracting<=0;
        anim_d<=0;
        retract_start<=0;
        retract_step<=0;
        sample_time<=0;
        sample_gain<=0;
        product<=0;
        calc_pipe<=0;
    end else begin
        anim_d<=animating;
        calc_pipe<={calc_pipe[0],1'b0};
        if(calc_pipe[0]) product<=sample_time*sample_gain;
        if(calc_pipe[1] && eligible) progress<=scaled_progress>=7680?13'd7680:scaled_progress[12:0];
        if(frame_tick && enabled) begin
            if(retracting) begin
                if(retract_step>=18) begin
                    progress<=0;
                    retracting<=0;
                end else begin
                    progress<=next_retract;
                    retract_step<=retract_step+1'b1;
                end
            end else if(eligible) begin
                if(elapsed>=interval || interval==0) progress<=7680;
                else begin
                    sample_time<=elapsed>>DROP;
                    sample_gain<=gain;
                    calc_pipe<=1;
                end
            end
        end
        if(animating && !anim_d) begin
            pending<=0;
            retracting<=progress!=0;
            retract_start<=progress;
            retract_step<=1;
            calc_pipe<=0;
        end
        // Keep a completed bar on screen until the requested image can animate.
        if(restart) begin
            pending<=1;
            retracting<=0;
            calc_pipe<=0;
            if(expired) progress<=7680;
        end
        // A cache hit can keep the same physical image (duplicate playlist entry).
        if(pending && !waiting && !animating && !restart && !failed) begin
            pending<=0;
            retracting<=progress!=0;
            retract_start<=progress;
            retract_step<=1;
            calc_pipe<=0;
        end
    end
end
endmodule
`endif
