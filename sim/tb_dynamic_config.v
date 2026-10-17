`timescale 1ns/1ps
// Real sd_site_assets configuration FSM, with the file-reader boundary driven
// directly. SD SPI/FAT electrical behavior is outside this test's scope.
module tb_dynamic_config;
    reg clk=0, video_clk=0, rst=1;
    always #5 clk=~clk;
    always #7 video_clk=~video_clk;
    reg [12:0] cfg_video_addr=0;
    wire [7:0] cfg_video_data;
    wire config_ready, background_ready, font_write_en;
    wire [12:0] font_write_addr;
    wire [17:0] font_write_data;
    wire [3:0] error_code;
    reg fs_idle_drive=1, mounted_drive=1;
    reg open_done_drive=0, open_ok_drive=1;
    reg file_valid_drive=0, file_end_drive=0;
    reg [31:0] file_size_drive=27648;
    reg [7:0] file_data_drive=0;
    reg [3:0] fs_error_drive=0;
    reg [7:0] packet[0:27647];
    reg [17:0] font_shadow[0:5631];
    integer font_writes=0, cycle=0, last_font_cycle=-1;
    integer case_number=0, checked_words=0, checked_sectors=0;
    integer stream_bytes=27648;
    reg active=0;
    reg abort_seen=0;
    reg [5:0] flow_seen=0;

    sd_site_assets #(.CLK_FREQ_HZ(1000), .ENABLE_SD_AUDIO(0)) dut(
        .clk(clk), .rst(rst), .cfg_video_clk(video_clk),
        .cfg_video_addr(cfg_video_addr), .cfg_video_data(cfg_video_data),
        .font_write_en(font_write_en), .font_write_addr(font_write_addr),
        .font_write_data(font_write_data),
        .config_ready(config_ready), .background_ready(background_ready),
        .error_code(error_code),
        .audio_music(1'b0), .audio_event(4'd0), .audio_clk(video_clk),
        .audio_rst(rst), .audio_take(1'b0),
        .request_prefetch(1'b0), .prefetch_cancel(1'b0), .request_keep(32'd0),
        .request_toggle(1'b0), .request_primary(7'd0), .request_photo(7'd0),
        .request_need_photo(1'b0), .request_tag(8'd0),
        .decision_toggle(1'b0), .decision_accept(1'b0),
        .applied_valid(1'b0), .applied_tag(8'd0), .applied_mask(6'd0),
        .write_abort_done(1'b0), .frame_done_pulse(1'b0), .write_req_ack(1'b0),
        .write_fifo_used(9'd0), .SD_MISO(1'b1),
        .audio_fallback(), .audio_error(), .audio_available(), .audio_sample(),
        .cached_maps(), .image_loading(), .loading_resource(),
        .response_toggle(), .response_ok(), .response_primary(), .response_photo(),
        .write_abort(), .write_buf_idx(), .write_tail_idx(), .slot_tails(),
        .write_req(), .write_en(), .write_data(), .write_stride(), .write_words(),
        .write_first_offset(), .write_bottom_up(), .slot_widths(), .slot_strides(),
        .slot_heights(), .SD_nCS(), .SD_DCLK(), .SD_MOSI()
    );

    function [17:0] expected_word;
        input integer index;
        integer p;
        begin
            if(index<4096) begin
                p=8192+index*4;
                expected_word={packet[p+2][1:0],packet[p+1],packet[p]};
            end else begin
                p=24576+(index-4096)*2;
                expected_word={2'd0,packet[p+1],packet[p]};
            end
        end
    endfunction

    always @(posedge clk) begin
        cycle=cycle+1;
        if(active && !rst) begin
            if(dut.state<=5) flow_seen[dut.state]=1'b1;
            if(dut.fs_abort) abort_seen=1;
            if(font_write_en) begin
                if(font_writes>=5632 || font_write_addr!==font_writes[12:0])
                    $fatal(1,"case %0d font address/order: got %0d expected %0d",case_number,font_write_addr,font_writes);
                if(font_write_data!==expected_word(font_writes))
                    $fatal(1,"case %0d font data %0d: got %h expected %h",case_number,font_writes,font_write_data,expected_word(font_writes));
                font_shadow[font_write_addr]=font_write_data;
                font_writes=font_writes+1;
                checked_words=checked_words+1;
                last_font_cycle=cycle;
                if(config_ready) $fatal(1,"configuration ready before font write completion");
            end
            if(config_ready && (font_writes!=5632 || cycle<=last_font_cycle))
                $fatal(1,"ready before all font words have reached the write interface");
        end
    end

    task reset_case;
        input integer n;
        input [8*100-1:0] filename;
        input integer declared_size;
        input integer actual_size;
        begin
            @(negedge clk);
            active=0; rst=1; file_valid_drive=0; file_end_drive=0;
            fs_error_drive=0; abort_seen=0;
            fs_idle_drive=1; mounted_drive=1;
            open_done_drive=0; open_ok_drive=1;
            file_size_drive=declared_size; stream_bytes=actual_size;
            case_number=n; font_writes=0; last_font_cycle=-1; flow_seen=0;
            $readmemh(filename,packet);
            repeat(5) @(negedge clk);
            rst=0; active=1;
            // Let BOOT, CFG_OPEN and registered open_done sampling operate.
            wait(dut.fs_open===1'b1);
            @(negedge clk); fs_idle_drive=0;
            repeat(3) @(negedge clk);
            open_done_drive=1;
            @(negedge clk); open_done_drive=0; fs_idle_drive=1;
        end
    endtask

    task send_sectors;
        input integer sector_count;
        integer sector, byte_in_sector, position, last;
        begin
            position=0;
            for(sector=0;sector<sector_count;sector=sector+1) begin
                wait(dut.file_req===1'b1 && dut.file_sector==sector && dut.state==3);
                @(negedge clk);
                if(dut.file_sector!==sector) $fatal(1,"sector request mismatch");
                checked_sectors=checked_sectors+1;
                fs_idle_drive=0;
                repeat(2) @(negedge clk);
                last=(stream_bytes-position>=512)?512:stream_bytes-position;
                for(byte_in_sector=0;byte_in_sector<last;byte_in_sector=byte_in_sector+1) begin
                    // Both back-to-back valid bytes and idle gaps occur. The
                    // loader must count valid bytes, not elapsed clock cycles.
                    if((byte_in_sector%11)==3) begin
                        file_valid_drive=0;
                        repeat(2) @(negedge clk);
                    end
                    file_data_drive=packet[position]; file_valid_drive=1;
                    position=position+1;
                    @(negedge clk);
                end
                file_valid_drive=0; file_end_drive=1;
                @(negedge clk); file_end_drive=0;
                // Draining is deliberately slower than the data pulse.
                repeat(4) @(negedge clk);
                fs_idle_drive=1;
            end
        end
    endtask

    task send_packet;
        begin
            send_sectors(54);
        end
    endtask

    task inject_read_error;
        integer byte_index, frozen_writes;
        begin
            // Sector 16 starts the font payload. Fail partway through sector
            // 17, without file_end or fs_idle, as a failed FAT/sector read can.
            send_sectors(17);
            wait(dut.file_req===1'b1 && dut.file_sector==17 && dut.state==3);
            @(negedge clk); fs_idle_drive=0;
            checked_sectors=checked_sectors+1;
            for(byte_index=0;byte_index<13;byte_index=byte_index+1) begin
                file_valid_drive=1;
                file_data_drive=packet[17*512+byte_index];
                @(negedge clk);
            end
            file_valid_drive=0;
            file_end_drive=0;
            fs_error_drive=7;
            check_failure(131);
            if(!abort_seen) $fatal(1,"filesystem failure did not produce fs_abort");
            frozen_writes=font_writes;
            repeat(20) @(negedge clk);
            if(font_write_en || font_writes!=frozen_writes || dut.file_req)
                $fatal(1,"font or file activity continued after failed configuration");
            $display("PASS: case 11 filesystem error without file_end aborted and halted font writes");
        end
    endtask

    task check_success;
        integer i;
        begin
            wait(config_ready===1'b1);
            repeat(3) @(negedge clk);
            if(error_code!==0 || !background_ready || dut.state!==14 || dut.cfg_pos!==27648)
                $fatal(1,"case %0d accepted with wrong final state/count",case_number);
            if(font_writes!=5632 || flow_seen!==6'b111111)
                $fatal(1,"case %0d incomplete words/FSM coverage",case_number);
            for(i=0;i<5632;i=i+1)
                if(font_shadow[i]!==expected_word(i)) $fatal(1,"warm reset left stale font word %0d",i);
            for(i=0;i<8192;i=i+1) begin
                // Direct storage check catches font payload wrapping into RAM.
                if(dut.cfg_mem[i]!==packet[i]) $fatal(1,"payload overwrote cfg RAM at %0d",i);
                // Also exercise the real asynchronous video read port.
                @(negedge video_clk); cfg_video_addr=i;
                @(posedge video_clk); #1;
                if(cfg_video_data!==packet[i]) $fatal(1,"config video read mismatch at %0d",i);
            end
            $display("PASS: case %0d correct package, 54 sectors, 5632 ordered font writes, 8192 config bytes",case_number);
        end
    endtask

    task check_failure;
        input integer expected_writes;
        begin
            wait(dut.state==20);
            repeat(20) @(negedge clk);
            if(config_ready || background_ready || error_code!==9)
                $fatal(1,"case %0d malformed package became ready or wrong error",case_number);
            if(expected_writes>=0 && font_writes!=expected_writes)
                $fatal(1,"case %0d unexpected font writes %0d",case_number,font_writes);
            $display("PASS: case %0d invalid package rejected (font writes %0d)",case_number,font_writes);
        end
    endtask

    initial begin
        // The real file-reader instances remain elaborated. Only their public
        // outputs and SD-init readiness are replaced by deterministic stimuli.
        force dut.sd_ready=1'b1;
        force dut.mounted=mounted_drive;
        force dut.fs_idle=fs_idle_drive;
        force dut.open_done=open_done_drive;
        force dut.open_ok=open_ok_drive;
        force dut.file_size=file_size_drive;
        force dut.file_data=file_data_drive;
        force dut.file_valid=file_valid_drive;
        force dut.file_end=file_end_drive;
        force dut.fs_error=fs_error_drive;
        reset_case(0,"package_real.hex",27648,27648);
        send_packet(); check_success();
        // Warm reset intentionally preserves font_shadow. Every address must
        // be overwritten with a different valid payload on the second boot.
        reset_case(1,"package_warm.hex",27648,27648);
        send_packet(); check_success();
        reset_case(2,"package_bad_payload_sum.hex",27648,27648);
        send_packet(); check_failure(5632);
        reset_case(3,"package_bad_padding.hex",27648,27648);
        send_packet(); check_failure(5632);
        reset_case(4,"package_old_version.hex",27648,27648);
        send_packet(); check_failure(5632);
        reset_case(5,"package_real.hex",8192,8192);
        check_failure(0);
        reset_case(6,"package_real.hex",27648,27647);
        send_packet(); check_failure(5631);
        reset_case(7,"package_real.hex",27647,27647);
        check_failure(0);
        reset_case(8,"package_bad_notes_id.hex",27648,27648);
        send_packet(); check_failure(5632);
        reset_case(9,"package_bad_header_sum.hex",27648,27648);
        send_packet(); check_failure(5632);
        reset_case(10,"package_bad_format.hex",27648,27648);
        send_packet(); check_failure(5632);
        reset_case(11,"package_real.hex",27648,27648);
        inject_read_error();
        $display("PASS: dynamic config suite; cases=12 checked_font_words=%0d checked_sectors=%0d",checked_words,checked_sectors);
        $finish;
    end
    initial begin
        #20000000;
        $fatal(1,"watchdog case=%0d state=%0d pos=%0d sector=%0d",case_number,dut.state,dut.cfg_pos,dut.cfg_sector);
    end
endmodule
