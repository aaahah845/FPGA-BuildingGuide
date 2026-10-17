`timescale 1ns/1ps
module tb_shared_input_timing;
reg clk=0;always #5 clk=~clk;
reg rst=1,button_n=1,cancel=0;
reg[6:0]divider=0;
wire ms_tick=divider==99;
always @(posedge clk)if(rst)divider<=0;else divider<=ms_tick?0:divider+1'b1;
wire held,short_event,long_event;
direction_key_event #(.CLK_FREQ_HZ(100000),.DEBOUNCE_MS(10),.LONG_PRESS_MS(50),.USE_MS_TICK(1)) dut(
 .clk(clk),.rst(rst),.button_n(button_n),.cancel(cancel),.ms_tick(ms_tick),
 .held(held),.short_event(short_event),.long_event(long_event));
integer cycle=0,shorts=0,longs=0,long_cycle=0,held_cycle=0;
reg last_held=0;
always @(posedge clk)begin
 cycle=cycle+1;
 if(short_event)shorts=shorts+1;
 if(long_event)begin longs=longs+1;long_cycle=cycle;end
 if(held && !last_held)held_cycle=cycle;
 last_held=held;
end
task wait_cycles;input integer count;begin repeat(count)@(negedge clk);end endtask
task ck;input condition;input[799:0]message;begin
 if(condition!==1'b1)$fatal(1,"%s cycle=%0d short=%0d long=%0d",message,cycle,shorts,longs);
end endtask
task released;begin button_n=1;wait_cycles(1200);ck(!held,"stable release");end endtask
integer phase,started,s0,l0,delta,k;
initial begin
 wait_cycles(5);rst=0;wait_cycles(1500);
 // Every millisecond phase is exercised; debounce must never accept early.
 for(phase=0;phase<100;phase=phase+1)begin
   while(divider!=phase)@(negedge clk);
   started=cycle;button_n=0;s0=shorts;l0=longs;
   wait_cycles(1000);ck(!held,"debounce accepted less than 10ms stable input");
   while(!held && cycle-started<1110)@(negedge clk);
   ck(held,"debounce did not accept within 11ms plus synchronizer delay");
   wait_cycles(200);released;
   ck(shorts==s0+1 && longs==l0,"one short event on stable release at every tick phase");
 end
 // Both sides of a tick edge, with long duration measured from accepted hold.
 for(phase=0;phase<4;phase=phase+1)begin
   while(divider!=(phase==0?0:phase==1?1:phase==2?98:99))@(negedge clk);
   button_n=0;s0=shorts;l0=longs;
   wait_cycles(1200);ck(held,"long press becomes held");
   while(longs==l0 && cycle-held_cycle<5105)@(negedge clk);
   delta=long_cycle-held_cycle;
   ck(longs==l0+1 && delta>=4998 && delta<=5002,"50ms long threshold kept at each tick phase");
   wait_cycles(6000);ck(longs==l0+1,"held long gesture cannot repeat");
   released;ck(shorts==s0,"release after long cannot click");
 end
 // Chatter including brief agreement with the old level clears partial history.
 s0=shorts;l0=longs;
 for(k=0;k<20;k=k+1)begin button_n=0;wait_cycles(750);button_n=1;wait_cycles(5);end
 wait_cycles(1200);ck(!held && shorts==s0 && longs==l0,"inter-tick chatter cannot accumulate");
 // Context changes discard an in-flight gesture and require a fresh press.
 button_n=0;wait_cycles(2000);cancel=1;wait_cycles(1);cancel=0;
 wait_cycles(7000);released;
 ck(shorts==s0 && longs==l0,"cancel suppresses held long and later release click");
 button_n=0;wait_cycles(1500);released;
 ck(shorts==s0+1 && longs==l0,"fresh gesture after cancellation works");
 $display("PASS: shared millisecond input timing: 100 debounce phases, long thresholds, no repeat/double action, chatter reset and context cancellation");
 $finish;
end
initial begin #10000000;$fatal(1,"shared input timing timeout");end
endmodule
