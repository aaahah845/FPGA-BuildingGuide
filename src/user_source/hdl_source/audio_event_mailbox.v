`ifndef AUDIO_EVENT_MAILBOX_V
`define AUDIO_EVENT_MAILBOX_V
// Latest-event-wins queue, payload held until destination acknowledgement.
// 【说明】事件邮箱：把单拍事件码跨时钟域送达，目标域收到后再接收下一个，防止丢失。
module audio_event_mailbox #(
    parameter WIDTH=2,
    parameter PRIORITY_MIN=0
)(
    input sclk,srst,
    input [WIDTH-1:0] event_in,
    input dclk,drst,
    output reg [WIDTH-1:0] event_out
);
reg [WIDTH-1:0] pending,held;
reg request,ack;
(* ASYNC_REG="TRUE" *) reg [1:0] ack_sync;
(* ASYNC_REG="TRUE" *) reg [2:0] request_sync;
(* ASYNC_REG="TRUE" *) reg [WIDTH-1:0] held_meta;
reg [WIDTH-1:0] held_sync;
always @(posedge sclk or posedge srst) begin
    if(srst) begin
        pending<=0;
        held<=0;
        request<=0;
        ack_sync<=0;
    end else begin
        ack_sync<={ack_sync[0],ack};
        if(request==ack_sync[1] && pending!=0) begin
            held<=pending;
            request<=!request;
            pending<=0;
        end
        if(event_in!=0 && (PRIORITY_MIN==0 || event_in>=PRIORITY_MIN || pending<PRIORITY_MIN)) pending<=event_in;
    end
end
always @(posedge dclk or posedge drst) begin
    if(drst) begin
        request_sync<=0;
        held_meta<=0;
        held_sync<=0;
        ack<=0;
        event_out<=0;
    end else begin
        request_sync<={request_sync[1:0],request};
        held_meta<=held;
        held_sync<=held_meta;
        event_out<=0;
        if(request_sync[2]!=ack) begin
            event_out<=held_sync;
            ack<=request_sync[2];
        end
    end
end
endmodule
`endif
