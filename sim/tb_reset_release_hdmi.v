`timescale 1ns/1ps

module glbl;
    wire gsrn = 1'b1;
endmodule

module reset_video_case(output reg done=0);
    reg clk=0,async_reset=0;
    always #12.5 clk=~clk;
    wire root;
    wire [6:0] leaves;
    reset_sync u_root(.clk(clk),.async_reset(async_reset),.reset_out(root));
    video_reset_leaves_from_top u_leaves(.video_clk(clk),.rst_video_root(root),.leaves(leaves));
    integer trial,edge_number,releases=0;
    real released_at=-100.0;
    always @(negedge leaves[0]) begin
        if($realtime>0.01) begin
            if(clk!==0 || leaves!==0) $fatal(1,"video leaves did not release together on falling edge");
            released_at=$realtime;
            releases=releases+1;
        end
    end
    always @(posedge clk)
        if(leaves===7'd0 && $realtime-released_at<12.499)
            $fatal(1,"video reset lacked half-cycle release margin");
    initial begin
        for(trial=0;trial<16;trial=trial+1) begin
            #(0.37+trial*0.41);async_reset=1;
            #0.001;
            if(root!==1 || leaves!==7'h7f) $fatal(1,"video assertion is not asynchronous");
            #(0.23+trial*0.17);async_reset=0;
            for(edge_number=1;edge_number<=3;edge_number=edge_number+1) begin
                @(posedge clk);#0.001;
                if(leaves!==7'h7f) $fatal(1,"video reset released on rising edge");
            end
            @(negedge clk);#0.001;
            if(leaves!==0) $fatal(1,"video reset failed to release after synchronized root");
            repeat(5) @(negedge clk);
        end
        if(releases!=16) $fatal(1,"video release count mismatch");
        $display("VIDEO_RESET_PASS trials=16 leaves=7 half_cycle_ns=12.5");
        done=1;
    end
endmodule

module hdmi_reset_case #(parameter real PIXEL_PHASE=0.0)(output reg done=0);
    reg pixel_clk=0,serial_clk=0,async_reset=0;
    always #2.5 serial_clk=~serial_clk;
    initial begin #(2.5+PIXEL_PHASE);pixel_clk=1;forever #12.5 pixel_clk=~pixel_clk;end
    wire root_reset;
    reset_sync u_root(.clk(serial_clk),.async_reset(async_reset),.reset_out(root_reset));
    reg [9:0] word=0;
    wire [9:0] in0=word,in1=word^10'h155,in2=~word,in3=10'b1111100000;
    wire [3:0] serial_out;
    hdmi_phy_wrapper dut(.I_pixel_clk(pixel_clk),.I_serial_clk(serial_clk),.I_rst(root_reset),
        .I_tmds_channel_0(in0),.I_tmds_channel_1(in1),.I_tmds_channel_2(in2),.I_tmds_channel_clk(in3),
        .O_tmds_ch0_p(serial_out[0]),.O_tmds_ch1_p(serial_out[1]),
        .O_tmds_ch2_p(serial_out[2]),.O_tmds_clk_p(serial_out[3]));
    function [9:0] reverse10;
        input [9:0] value;
        integer bit_number;
        begin for(bit_number=0;bit_number<10;bit_number=bit_number+1)
            reverse10[bit_number]=value[9-bit_number];end
    endfunction
    always @(posedge pixel_clk) word<=word+1'b1;
    integer loads=0,total_loads=0,serial_edges=0,last_load_edge=0,last_word=-1;
    integer trials=0,assertions=0,output_checks=0;
    real word_changed_at=0.0,minimum_age=1.0e9,last_fall=0.0,released_at=-100.0;
    always @(word) word_changed_at=$realtime;
    always @(negedge serial_clk) last_fall=$realtime;
    always @(negedge dut.serial_logic_reset) begin
        if($realtime>0.01) begin
            if(serial_clk!==0 || $realtime-last_fall>0.001)
                $fatal(1,"serial logic reset released away from falling edge");
            released_at=$realtime;
        end
    end
    always @(posedge root_reset) begin
        loads=0;
        #0.001;
        if(dut.serial_logic_reset!==1 || dut.u0_lane_lvds_8_1.S_shift_data!==0 ||
            dut.u1_lane_lvds_8_1.S_shift_data!==0 || dut.u2_lane_lvds_8_1.S_shift_data!==0 ||
            dut.u3_lane_lvds_8_1.S_shift_data!==0 || dut.u0_lane_lvds_8_1.S_odd_even!==0)
            $fatal(1,"HDMI fabric asynchronous assertion failed");
        assertions=assertions+1;
    end
    reg [9:0] observed0,observed1,observed2,observed3;
    always @(posedge serial_clk) begin
        serial_edges=serial_edges+1;
        if(dut.serial_logic_reset===0 && $realtime-released_at<2.499)
            $fatal(1,"HDMI fabric reset lacked half-cycle release margin");
        if(!dut.serial_logic_reset && dut.u0_lane_lvds_8_1.S_load_en_2d) begin
            observed0=reverse10(in0);observed1=reverse10(in1);
            observed2=reverse10(in2);observed3=reverse10(in3);
            if(loads>5) begin
                if(serial_edges-last_load_edge!=5) $fatal(1,"HDMI capture cadence changed");
                if(word!==((last_word+1)&1023)) $fatal(1,"HDMI word lost/repeated phase=%f",PIXEL_PHASE);
                if($realtime-word_changed_at<19.999) $fatal(1,"HDMI capture window shortened");
                if($realtime-word_changed_at<minimum_age) minimum_age=$realtime-word_changed_at;
            end
            last_word=word;last_load_edge=serial_edges;loads=loads+1;total_loads=total_loads+1;
            #0.001;
            if(dut.u0_lane_lvds_8_1.S_shift_data!==observed0 || dut.u1_lane_lvds_8_1.S_shift_data!==observed1 ||
                dut.u2_lane_lvds_8_1.S_shift_data!==observed2 || dut.u3_lane_lvds_8_1.S_shift_data!==observed3)
                $fatal(1,"HDMI lane parallel capture mismatch");
        end
    end
    // Validate both DDR output edges using the official EG_LOGIC_ODDR model.
    // Negedge output is d1 retained by ODDR at the preceding rising edge.
    reg [3:0] expected_positive,expected_negative;
    always @(posedge serial_clk) begin
        expected_positive={dut.u3_lane_lvds_8_1.S_oddr_data[1],dut.u2_lane_lvds_8_1.S_oddr_data[1],
            dut.u1_lane_lvds_8_1.S_oddr_data[1],dut.u0_lane_lvds_8_1.S_oddr_data[1]};
        expected_negative={dut.u3_lane_lvds_8_1.S_oddr_data[0],dut.u2_lane_lvds_8_1.S_oddr_data[0],
            dut.u1_lane_lvds_8_1.S_oddr_data[0],dut.u0_lane_lvds_8_1.S_oddr_data[0]};
        #0.2;
        if(!root_reset && loads>6) begin
            if(serial_out!==expected_positive) $fatal(1,"ODDR rising-edge output mismatch");
            output_checks=output_checks+1;
        end
    end
    always @(negedge serial_clk) begin
        #0.2;
        if(!root_reset && loads>6) begin
            if(serial_out!==expected_negative) $fatal(1,"ODDR falling-edge output mismatch");
            output_checks=output_checks+1;
        end
    end
    initial begin
        for(trials=0;trials<4;trials=trials+1) begin
            #(0.31+PIXEL_PHASE+trials*0.37);async_reset=1;
            #(0.13+trials*0.29);async_reset=0;
            wait(loads>=600);
        end
        if(assertions!=4 || total_loads!=2400 || output_checks<23000)
            $fatal(1,"incomplete HDMI reset test %d %d %d",assertions,total_loads,output_checks);
        $display("HDMI_RESET_PASS phase_ns=%0.3f resets=4 words_per_lane=%0d minimum_stability_ns=%0.3f ddr_edge_checks=%0d",PIXEL_PHASE,total_loads,minimum_age,output_checks);
        done=1;
    end
endmodule

module tb_reset_release_hdmi;
    wire [6:0] done;
    reset_video_case video(done[0]);
    hdmi_reset_case #(.PIXEL_PHASE(0.0)) c0(done[1]);
    hdmi_reset_case #(.PIXEL_PHASE(0.1)) c1(done[2]);
    hdmi_reset_case #(.PIXEL_PHASE(1.0)) c2(done[3]);
    hdmi_reset_case #(.PIXEL_PHASE(2.5)) c3(done[4]);
    hdmi_reset_case #(.PIXEL_PHASE(4.0)) c4(done[5]);
    hdmi_reset_case #(.PIXEL_PHASE(4.9)) c5(done[6]);
    initial begin wait(&done);$display("PASS: falling-edge reset leaves, six-phase four-lane HDMI capture and official ODDR output regression");$finish;end
    initial begin #100000;$fatal(1,"reset/HDMI regression timeout");end
endmodule
