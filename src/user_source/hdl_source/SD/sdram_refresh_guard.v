`ifndef SDRAM_REFRESH_GUARD_V
`define SDRAM_REFRESH_GUARD_V
// Reserve the application interface before issuing a manual AUTO REFRESH.
// Existing bursts finish normally; frame controllers see busy and admit no new burst.
// 【说明】刷新保护（ext_mem_clk）：约每 31.25 µs 先等总线连续 16 拍空闲，再插一次 AUTO REFRESH；
//         刷新期间对外表现为忙，帧控制器不发新突发。
module sdram_refresh_guard #(
    parameter PERIOD=3906
)(
    input clk,rst,init_done,core_busy,core_refresh_busy,app_rd_en,app_wr_en,
    output busy,
    output request
);
localparam RUN=0,DRAIN=1,REQUEST=2,WAIT_BUSY=3,WAIT_DONE=4;
reg [2:0] state;
reg [12:0] timer;
reg [4:0] quiet;
reg period_end;
assign busy=(state!=RUN);
assign request=(state==REQUEST);
always @(posedge clk or posedge rst) begin
    if(rst) begin
        state<=RUN;
        timer<=0;
        quiet<=0;
        period_end<=PERIOD==1;
    end else if(!init_done) begin
        state<=RUN;
        timer<=0;
        quiet<=0;
        period_end<=PERIOD==1;
    end else begin
        // Count start-to-start. Deferral is bounded by the in-flight application burst.
        // Predict the terminal count one cycle early; preserve the exact period.
        period_end<=PERIOD==1 || timer==PERIOD-2;
        if(period_end) timer<=0;
        else timer<=timer+1'b1;
        case(state)
            RUN:if(period_end) begin
                state<=DRAIN;
                quiet<=0;
            end
            DRAIN:if(app_rd_en || app_wr_en || core_busy || core_refresh_busy) quiet<=0;
            else if(quiet==15) begin
                state<=REQUEST;
                quiet<=0;
            end else quiet<=quiet+1'b1;
            REQUEST:state<=WAIT_BUSY;
            WAIT_BUSY:if(core_refresh_busy) state<=WAIT_DONE;
            WAIT_DONE:if(!core_refresh_busy) state<=RUN;
            default:state<=DRAIN;
        endcase
    end
end
endmodule
`endif
