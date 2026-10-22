`timescale 1ns/1ps
// 【说明】写控制（ext_mem_clk）：把写 FIFO 中的 BMP 像素以最多 256 字的突发写入 SDRAM。
//         自下而上存储的 BMP 写入时地址倒走一行，存进 SDRAM 后即为自上而下；
//         逻辑偏移超过 307200 字时切到尾槽地址（大地图跨槽）。write_abort 一拍同步清零。
module frame_fifo_write
#
(
	parameter DYNAMIC_GEOMETRY = 0,
 parameter SCATTERED_SLOTS = 0,
	parameter MEM_DATA_BITS          = 32,
	parameter ADDR_BITS              = 21,
	parameter BURST_BITS             = 9,
	parameter BURST_SIZE             = 128,
	parameter WRITE_V_FLIP           = 1,      // 1: write image rows upside-down to cancel BMP bottom-up storage
	parameter FRAME_WIDTH            = 640,
	parameter FRAME_HEIGHT           = 480
)               
(
 input[2:0]write_tail_index,
 input [10:0] image_stride,input [20:0] image_first_offset,input image_bottom_up,
 	input                            rst,                  
	input                            write_abort,          // mem-clock-domain one-cycle abort event
	input                            mem_clk,                    // external memory controller user interface clock
	input							 Sdr_init_done,
	input							 Sdr_init_ref_vld,
    input							 Sdr_busy,
	input							 App_rd_busy,
    output							 O_wr_busy,
	
	output 							 App_wr_en,
	output  [ADDR_BITS - 1:0]	 	App_wr_addr,
	/*
    output reg                       wr_burst_req,               // to external memory controller,send out a burst write request  
	output reg[BURST_BITS - 1:0]     wr_burst_len,               // to external memory controller,data length of the burst write request, not bytes 
	output reg[ADDR_BITS - 1:0]      wr_burst_addr,              // to external memory controller,base address of the burst write request 
	input                            wr_burst_data_req,          // from external memory controller,write data request ,before data 1 clock 
	input                            wr_burst_finish,            // from external memory controller,burst write finish
	*/
	input                            write_req,                  // data write module write request,keep '1' until read_req_ack = '1'
	output reg                       write_req_ack,              // data write module write request response
	output                           write_finish,               // data write module write request finish
	input[ADDR_BITS - 1:0]           write_addr_0,               // data write module write request base address 0, used when write_addr_index = 0
	input[ADDR_BITS - 1:0]           write_addr_1,               // data write module write request base address 1, used when write_addr_index = 1
	input[ADDR_BITS - 1:0]           write_addr_2,               // data write module write request base address 1, used when write_addr_index = 2
	input[ADDR_BITS - 1:0]           write_addr_3,               // data write module write request base address 1, used when write_addr_index = 3
	input[2:0]                       write_addr_index,           // select valid base address from write_addr_0 write_addr_1 write_addr_2 write_addr_3
	input[ADDR_BITS - 1:0]           write_addr_4,write_addr_5,
	input[ADDR_BITS - 1:0]           write_len,                  // data write module write request data length
	output reg                       fifo_aclr,                  // to fifo asynchronous clear
	input[BURST_BITS - 1:0]         rdusedw                     // from FIFO read-domain used words
);
localparam ONE                       = 256'd1;                   //256 bit '1'   you can use ONE[n-1:0] for n bit '1'
localparam ZERO                      = 256'd0;                   //256 bit '0'

// Vertical flip address mapping for 640x480 frame buffer（每个槽 640×480 字；大地图跨两槽）.
// Input stream order remains unchanged; only SDRAM write addresses are remapped:
// stream row 0 -> memory row FRAME_HEIGHT-1, stream row 1 -> memory row FRAME_HEIGHT-2, ...
localparam [ADDR_BITS - 1:0] VFLIP_FIRST_ADDR_OFFSET = (FRAME_HEIGHT - 1) * FRAME_WIDTH;
localparam [ADDR_BITS - 1:0] VFLIP_LINE_JUMP         = (FRAME_WIDTH * 2) - 1;
localparam [15:0]            VFLIP_LINE_LAST_X       = FRAME_WIDTH - 1;

//write state machine code
localparam S_IDLE                    = 0;                        //idle state,waiting for write
localparam S_ACK                     = 1;                        //written request response
localparam S_CHECK_FIFO              = 2;                        //check the FIFO status, ensure that there is enough space to burst write
localparam S_WRITE_BURST             = 3;                        //begin a burst write
localparam S_WRITE_BURST_END         = 4;                        //a burst write complete
localparam S_END                     = 5;                        //a frame of data is written to complete


// Plan the next burst while idle: keep frame-wide arithmetic off the
// 125 MHz per-word write-enable and state-transition paths.
// （更正：当前 ext_mem_clk 为 100 MHz；125 MHz 是早期工程的存储时钟。）
localparam S_PLAN=6, S_PLAN_LIMIT=7, S_ROW_LOW=8, S_ROW_HIGH=9;
reg [11:0] row_remaining;
reg row_wrap;
reg logical_borrow, tail_borrow, primary_borrow;
reg [ADDR_BITS-1:0] remaining_words;
reg [BURST_BITS-1:0] burst_words, burst_last;
reg final_burst;
wire [BURST_BITS-1:0] frame_planned = remaining_words >= BURST_SIZE ? BURST_SIZE : remaining_words;

reg                                 write_req_d0;                //asynchronous write request, synchronize to 'mem_clk' clock domain,first beat
reg                                 write_req_d1;                //the second
reg                                 write_req_d2;                //third,Why do you need 3 ? Here's the design habit
reg[ADDR_BITS - 1:0]                write_len_d0;                //asynchronous write_len(write data length), synchronize to 'mem_clk' clock domain first
reg[ADDR_BITS - 1:0]                write_len_d1;                //second
reg[ADDR_BITS - 1:0]                write_len_latch;             //lock write data length
reg[ADDR_BITS - 1:0]                write_cnt;                   //write data counter
reg[2:0]                            write_addr_index_d0;
reg[2:0]                            write_addr_index_d1;
reg[3:0]                            state;                       //state machine
reg [ADDR_BITS - 1:0]	 App_wr_addr_r;
reg[2:0]tail_meta,tail_sync;
reg[20:0]logical_offset,tail_address;
reg primary_carry, logical_carry, tail_carry;
function[20:0]slot_base;input[2:0]idx;begin case(idx)
0:slot_base=write_addr_0;1:slot_base=write_addr_1;2:slot_base=write_addr_2;
3:slot_base=write_addr_3;4:slot_base=write_addr_4;5:slot_base=write_addr_5;
default:slot_base=0;endcase end endfunction
// Resolve the six-way slot choice before the ACK address addition.
// Request fields are held through the synchronizer/ACK handshake.
reg[20:0] primary_base, tail_base;
always @(posedge mem_clk or posedge rst)begin
 if(rst)begin primary_base<=0;tail_base<=0;end
 else begin
 primary_base<=slot_base(write_addr_index_d1);
 tail_base<=slot_base(tail_sync)-21'd307200;
 end
end
localparam integer ROW_X_BITS = DYNAMIC_GEOMETRY ? 11 : (FRAME_WIDTH > 1 ? $clog2(FRAME_WIDTH) : 1);
 reg[31:0] geometry_meta,geometry_sync,geometry_latched;
 reg[11:0]row_delta_latched;reg[10:0]line_last_latched;
 always @(posedge mem_clk or posedge rst)begin
 if(rst)begin geometry_meta<=0;geometry_sync<=0;geometry_latched<=0;row_delta_latched<=1280;line_last_latched<=639;end
 else begin geometry_meta<={image_bottom_up,image_stride,image_first_offset[19:0]};geometry_sync<=geometry_meta;
 if(state==S_ACK)begin
 geometry_latched<=geometry_sync;
 row_delta_latched<=({1'b0,geometry_sync[30:20]}<<1);
 line_last_latched<=geometry_sync[30:20]-1'b1;
 end end end
 wire flip=DYNAMIC_GEOMETRY?geometry_latched[31]:WRITE_V_FLIP;
wire [BURST_BITS-1:0] planned_words = flip && row_remaining < frame_planned ? row_remaining : frame_planned;
 wire ack_flip=DYNAMIC_GEOMETRY?geometry_sync[31]:WRITE_V_FLIP;
 wire[20:0]first=DYNAMIC_GEOMETRY?{1'b0,geometry_sync[19:0]}:VFLIP_FIRST_ADDR_OFFSET;
 wire[11:0]row_delta=DYNAMIC_GEOMETRY?row_delta_latched:(FRAME_WIDTH*2);
 wire[10:0]last_x=DYNAMIC_GEOMETRY?line_last_latched:VFLIP_LINE_LAST_X;
reg [ROW_X_BITS-1:0]                  wr_x;                       // bounded source-row coordinate

always @(posedge mem_clk or posedge rst)begin
 if(rst)begin tail_meta<=0;tail_sync<=0;logical_offset<=0;tail_address<=0;end
 else if(write_abort)begin logical_offset<=0;tail_address<=0;end
 else begin
 tail_meta<=write_tail_index;tail_sync<=tail_meta;
 if(state==S_ACK)begin
 logical_offset<=ack_flip?first:21'd0;
 tail_address<=tail_base+(ack_flip?first:21'd0);
 end else if(state==S_ROW_LOW && row_wrap)begin
 logical_offset[11:0]<=logical_offset[11:0]-row_delta;
 tail_address[11:0]<=tail_address[11:0]-row_delta;
 end else if(state==S_ROW_HIGH && row_wrap)begin
 logical_offset[20:12]<=logical_offset[20:12]-logical_borrow;
 tail_address[20:12]<=tail_address[20:12]-tail_borrow;
 end else if(App_wr_en)begin
 logical_offset[7:0]<=logical_offset[7:0]+1'b1;
 if(logical_carry)logical_offset[20:8]<=logical_offset[20:8]+1'b1;
 tail_address[7:0]<=tail_address[7:0]+1'b1;
 if(tail_carry)tail_address[20:8]<=tail_address[20:8]+1'b1;
 end
 end
end

// Bursts never cross a flipped row. Repair its next address while the
// write port is idle, with a 12-bit subtract followed by a 9-bit borrow.
always @(posedge mem_clk or posedge rst)begin
 if(rst)begin row_wrap<=0;logical_borrow<=0;tail_borrow<=0;primary_borrow<=0;end
 else if(write_abort || state==S_ACK)begin row_wrap<=0;logical_borrow<=0;tail_borrow<=0;primary_borrow<=0;end
 else begin
 if(App_wr_en && flip && wr_x==last_x)row_wrap<=1;
 if(state==S_ROW_LOW)begin
 logical_borrow<=logical_offset[11:0]<row_delta;
 tail_borrow<=tail_address[11:0]<row_delta;
 primary_borrow<=App_wr_addr_r[11:0]<row_delta;
 end
 if(state==S_ROW_HIGH)row_wrap<=0;
 end
end

// Predict low-byte wrap one accepted word ahead. Idle/setup cycles settle
// the flags before a burst, and stalls retain a pending carry at 0xff.

always @(posedge mem_clk or posedge rst)begin
 if(rst)begin primary_carry<=0;logical_carry<=0;tail_carry<=0;end
 else if(write_abort)begin primary_carry<=0;logical_carry<=0;tail_carry<=0;end
 else begin
 primary_carry<=App_wr_en ? App_wr_addr_r[7:0]==8'hfe : App_wr_addr_r[7:0]==8'hff;
 logical_carry<=App_wr_en ? logical_offset[7:0]==8'hfe : logical_offset[7:0]==8'hff;
 tail_carry<=App_wr_en ? tail_address[7:0]==8'hfe : tail_address[7:0]==8'hff;
 end
end

reg [BURST_BITS - 1:0] words_left;
wire [BURST_BITS - 1:0] burst_cnt = burst_words-words_left; // diagnostic count
wire								wr_burst_finish;

reg App_wr_en_r;
reg App_wr_en_d0;

reg [BURST_BITS - 1:0] rdusedw_d;
reg                         into_burst;
wire                        into_burst_next;
always @(posedge mem_clk or posedge rst)begin
 if(rst)begin remaining_words<=0;row_remaining<=0;burst_words<=BURST_SIZE;burst_last<=BURST_SIZE-1;final_burst<=0;end
 else if(write_abort)begin remaining_words<=0;row_remaining<=0;burst_words<=BURST_SIZE;burst_last<=BURST_SIZE-1;final_burst<=0;end
 else if(state==S_PLAN)begin remaining_words<=write_len_latch-write_cnt;row_remaining<={1'b0,last_x}-{1'b0,wr_x}+1'b1;end
 else if(state==S_PLAN_LIMIT)begin burst_words<=planned_words;burst_last<=planned_words-1'b1;final_burst<=remaining_words==planned_words;end
end
// Start as soon as one complete burst is available.  The old strict ">"
// condition could leave an exact 256-word FIFO fill waiting unnecessarily.
// Register both the FIFO occupancy and the decision.  Besides making the
// transaction boundary explicit, this cuts the old rd_addr -> used-count ->
// 21-bit add/compare -> read/write-arbiter path at 125 MHz（当前为 100 MHz）.
assign into_burst_next = (rdusedw_d >= burst_words) && ~App_rd_busy;//当rd在突发时不会进入burst

// Both physical counters advance in parallel; only a mux remains at the
// SDRAM port. The interface accepts per-word addresses (including row flips).
// Select the scattered segment one cycle ahead, alongside its counters.
// Keep the 21-bit compare out of the SDRAM address output path.
reg use_tail;
wire[8:0] row_next_high=logical_offset[20:12]-logical_borrow;
always @(posedge mem_clk or posedge rst)begin
 if(rst)use_tail<=0;
 else if(write_abort)use_tail<=0;
 else if(state==S_ACK)use_tail<=ack_flip && first>=21'd307200;
 else if(state==S_ROW_HIGH && row_wrap)use_tail<=row_next_high>=9'd75;
 else if(App_wr_en)use_tail<=logical_offset>=21'd307199;
end
assign App_wr_addr = SCATTERED_SLOTS && use_tail ? tail_address : App_wr_addr_r;
//assign O_wr_busy = (state != S_IDLE || (S_IDLE && write_req_d2));
assign O_wr_busy = (state == S_WRITE_BURST || (state == S_CHECK_FIFO && into_burst));//在突发，或者将要突发，则显示busy
assign wr_burst_finish = words_left == 0;
assign write_finish = (state == S_END) ? 1'b1 : 1'b0;            //write finish at state 'S_END'
assign App_wr_en = App_wr_en_d0;

always @(posedge mem_clk or posedge rst)
begin
	if(rst == 1'b1)
	begin
		rdusedw_d  <= ZERO[BURST_BITS - 1:0];
		into_burst <= 1'b0;
	end
	else if(write_abort)
	begin
		rdusedw_d  <= ZERO[BURST_BITS - 1:0];
		into_burst <= 1'b0;
	end
	else
	begin
		rdusedw_d <= rdusedw;
		if(state == S_CHECK_FIFO)
			into_burst <= into_burst_next;
		else
			into_burst <= 1'b0;
	end
end


always@(posedge mem_clk or posedge rst)
begin
	if(rst == 1'b1)
	begin
		write_req_d0    <=  1'b0;
		write_req_d1    <=  1'b0;
		write_req_d2    <=  1'b0;
		write_len_d0    <=  ZERO[ADDR_BITS - 1:0];              //equivalent to write_len_d0 <= 0;
		write_len_d1    <=  ZERO[ADDR_BITS - 1:0];              //equivalent to write_len_d1 <= 0;
		write_addr_index_d0    <=  2'b00;
		write_addr_index_d1    <=  2'b00;
	end
	else if(write_abort)
	begin
		write_req_d0    <=  1'b0;
		write_req_d1    <=  1'b0;
		write_req_d2    <=  1'b0;
		write_len_d0    <=  ZERO[ADDR_BITS - 1:0];
		write_len_d1    <=  ZERO[ADDR_BITS - 1:0];
		write_addr_index_d0 <= 2'b00;
		write_addr_index_d1 <= 2'b00;
	end
	else
	begin
		write_req_d0    <=  write_req;
		write_req_d1    <=  write_req_d0;
		write_req_d2    <=  write_req_d1;
		write_len_d0    <=  write_len;
		write_len_d1    <=  write_len_d0;
		write_addr_index_d0 <= write_addr_index;
		write_addr_index_d1 <= write_addr_index_d0;
	end 
end
always @(posedge mem_clk or posedge rst)
begin
	if(rst == 1'b1)
	begin
		words_left <= ZERO[BURST_BITS - 1:0];
		App_wr_addr_r <= ZERO[ADDR_BITS - 1:0];
		App_wr_en_d0 <= 1'b0;
		wr_x <= 16'd0;
	end
	else if(write_abort)
	begin
		words_left <= ZERO[BURST_BITS - 1:0];
		App_wr_addr_r <= ZERO[ADDR_BITS - 1:0];
		App_wr_en_d0 <= 1'b0;
		wr_x <= 16'd0;
	end
	else begin
	
		if(state == S_CHECK_FIFO)
			words_left <= burst_words;
		else if(App_wr_en)
			words_left <= words_left - 1'b1;
		else
			words_left <= words_left;
		//
		if(state == S_ACK)
			begin
				wr_x <= 16'd0;
                App_wr_addr_r <= primary_base + (ack_flip ? first : 21'd0);
			end
        else if(state==S_ROW_LOW && row_wrap)
            App_wr_addr_r[11:0] <= App_wr_addr_r[11:0]-row_delta;
        else if(state==S_ROW_HIGH && row_wrap)
            App_wr_addr_r[ADDR_BITS-1:12] <= App_wr_addr_r[ADDR_BITS-1:12]-primary_borrow;
        else if(App_wr_en)begin
            App_wr_addr_r[7:0] <= App_wr_addr_r[7:0] + 1'b1;
            if(primary_carry)App_wr_addr_r[ADDR_BITS-1:8] <= App_wr_addr_r[ADDR_BITS-1:8] + 1'b1;
            if(flip)wr_x <= wr_x==last_x ? 0 : wr_x+1'b1;
        end
		else
			App_wr_addr_r <= App_wr_addr_r;
		//
		if(App_wr_en_r && words_left!=0 && !(App_wr_en && words_left==1))begin
            App_wr_en_d0 <= 1'b1;
        end
		else
			App_wr_en_d0 <= 1'b0;
	
	end		
end
always@(posedge mem_clk or posedge rst)
begin
	if(rst == 1'b1)
	begin
		state <= S_IDLE;
		write_len_latch <= ZERO[ADDR_BITS - 1:0];
		
		//wr_burst_addr <= ZERO[ADDR_BITS - 1:0];
		//wr_burst_req <= 1'b0;
		App_wr_en_r <= 1'b0;
		
		write_cnt <= ZERO[ADDR_BITS - 1:0];
		fifo_aclr <= 1'b0;
		write_req_ack <= 1'b0;
		//wr_burst_len <= ZERO[BURST_BITS - 1:0];
		
		
	end
	else if(write_abort)
	begin
		state <= S_IDLE;
		write_len_latch <= ZERO[ADDR_BITS - 1:0];
		App_wr_en_r <= 1'b0;
		write_cnt <= ZERO[ADDR_BITS - 1:0];
		fifo_aclr <= 1'b0;
		write_req_ack <= 1'b0;
	end
	else 
		case(state)
			//idle state,waiting for write write_req_d2 == '1' goto the 'S_ACK'
			S_IDLE:
			begin
				if(write_req_d2 == 1'b1 && Sdr_init_done && write_addr_index_d1<6)
				begin
					state <= S_ACK;
				end
				write_req_ack <= 1'b0;
			end
			//'S_ACK' state completes the write request response, the FIFO reset, the address latch, and the data length latch
			S_ACK:
			begin
				//after write request revocation(write_req_d2 == '0'),goto 'S_CHECK_FIFO',write_req_ack goto '0'
				if(write_req_d2 == 1'b0)
				begin
					state <= S_PLAN;
					fifo_aclr <= 1'b0;
					write_req_ack <= 1'b0;
				end
				else
				begin
					//write request response
					write_req_ack <= 1'b1;
					//FIFO reset
					fifo_aclr <= 1'b1;
					//select valid base address from write_addr_0 write_addr_1 write_addr_2 write_addr_3
					/*
					if(write_addr_index_d1 == 2'd0)
						wr_burst_addr <= write_addr_0;
					else if(write_addr_index_d1 == 2'd1)
						wr_burst_addr <= write_addr_1;
					else if(write_addr_index_d1 == 2'd2)
						wr_burst_addr <= write_addr_2;
					else if(write_addr_index_d1 == 2'd3)
						wr_burst_addr <= write_addr_3;
					*/
					//latch data length
					write_len_latch <= write_len_d1;                    
				end
				//write data counter reset, write_cnt <= 0;
				write_cnt <= ZERO[ADDR_BITS - 1:0];
			end
			S_PLAN: state <= S_PLAN_LIMIT;
			S_PLAN_LIMIT: state <= S_CHECK_FIFO;
            S_ROW_LOW: state <= S_ROW_HIGH;
            S_ROW_HIGH: state <= S_PLAN;
			S_CHECK_FIFO:
			begin
				//if there is a write request at this time, enter the 'S_ACK' state
				if(write_req_d2 == 1'b1)
				begin
					state <= S_ACK;
				end
				//if the FIFO space is a burst write request, goto burst write state
				// The registered decision may predate a read burst grant.
				// Recheck ownership at the edge that actually starts writing.
				else if(into_burst && !App_rd_busy && !Sdr_init_ref_vld && !Sdr_busy)
				begin
					state <= S_WRITE_BURST;
					//wr_burst_len <= BURST_SIZE[BURST_BITS - 1:0];
					//wr_burst_req <= 1'b1;
					App_wr_en_r <= 1'b1;
				end
			end 
			
			S_WRITE_BURST:
			begin
				//burst finish
				if(wr_burst_finish == 1'b1)
				begin
					App_wr_en_r <= 1'b0;
					state <= S_WRITE_BURST_END;
					//write counter + burst length
					write_cnt <= write_cnt + burst_words;
					//the next burst write address is generated
					//wr_burst_addr <= wr_burst_addr + BURST_SIZE[ADDR_BITS - 1:0];
				end     
			end
			S_WRITE_BURST_END:
			begin
				//if there is a write request at this time, enter the 'S_ACK' state
				if(write_req_d2 == 1'b1)
				begin
					state <= S_ACK;
				end
				//if the write counter value is less than the frame length, continue writing,
				//otherwise the writing is complete
				else if(!final_burst)
				begin
					state <= row_wrap ? S_ROW_LOW : S_PLAN;
				end
				else
				begin
					state <= S_END;
				end
			end
			S_END:
			begin
				state <= S_IDLE;
			end
			default:
				state <= S_IDLE;
		endcase
end
endmodule

