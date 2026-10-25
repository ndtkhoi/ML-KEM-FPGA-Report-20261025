`timescale 1ns/1ps
// A2 registered-clear contract. Not a post-fit timing test.
// Count edges from kem_clear sampling: session/public read invalidated at 2,
// KDF/AES state at 3, sponge/permutation datapath at 4. RAM wipe is sequential.
module tb_channel_pipeline_guards;
    logic clk=0; always #3.333 clk=~clk;
    logic rst_n=0,kem_clear=0,kem_valid=0,start=0,load_we=0;
    logic [1:0] op=0;
    logic [7:0] rd,err;
    wire active,busy,done;
    wire [63:0] epoch;
    channel_session dut(
        .clk(clk),.rst_n(rst_n),.kem_clear(kem_clear),.kem_valid(kem_valid),
        .kem_mode(1'b0),.kem_encaps(1'b1),.kem_secret(256'h0123456789abcdef),
        .start(start),.request_mode(1'b0),.op(op),
        .session_id_in(128'h000102030405060708090a0b0c0d0e0f),.tag_in(128'd0),
        .sequence_in(64'd0),.data_length(9'd1),.load_we(load_we),
        .load_address(8'd0),.load_data(8'h5a),.read_address(8'd0),
        .read_data(rd),.error_code(err),.active(active),.busy(busy),.done(done),
        .epoch(epoch),.result_sequence(),.session_id(),.tag_out(),.plaintext_hash(),
        .result_length(),.tx_count(),.rx_count(),.auth_fail_count(),.replay_count(),.cycles());

    always @(negedge clk) if (rst_n) begin
        if(dut.u_kdf.u_hash.u_permutation.done) begin
            // KDF selects three phases/round: 24 * 3 clocks. The ML-KEM
            // sponge keeps its two-phase schedule and separate tests.
            if(dut.u_kdf.u_hash.u_permutation.cycle_count!==7'd72 ||
               dut.u_kdf.u_hash.u_permutation.round_mid!==1600'd0)
                $fatal(1,"Keccak phase count / temporary erase");
        end
    end
    task automatic begin_derive;
        begin
            @(negedge clk);kem_valid=1;
            @(negedge clk);kem_valid=0;
            @(negedge clk);op=0;start=1;
            @(negedge clk);start=0;
        end
    endtask
    task automatic begin_seal;
        begin
            @(negedge clk);load_we=1;
            @(negedge clk);load_we=0;op=1;start=1;
            @(negedge clk);start=0;
        end
    endtask
    task automatic clear_and_check;
        integer j;
        reg [63:0] saved_epoch;
        begin
            saved_epoch=epoch;
            // One-cycle input pulse must propagate through every local clear.
            @(negedge clk);kem_clear=1;
            @(posedge clk);#1;
            if(dut.session_clear_q!==1'b1)
                $fatal(1,"clear request not captured at edge 1");
            @(negedge clk);kem_clear=0;
            @(posedge clk);#1;
            if(active!==0 || busy!==0 || done!==0 || dut.pending!==0 ||
               dut.pending_key!==0 || dut.key_e!==0 || dut.key_d!==0 ||
               dut.prefix_e!==0 || dut.prefix_d!==0 ||
               dut.public_read_valid_q!==0 || rd!==0)
                $fatal(1,"session/public output not invalidated at edge 2");
            @(posedge clk);#1;
            if(dut.u_kdf.material!==0 || dut.u_kdf.key_shift!==0 ||
               dut.u_kdf.body_shift!==0 || dut.u_kdf.prk!==0 ||
               dut.u_gcm.key_reg!==0 || dut.u_gcm.u_aes.key_even!==0 ||
               dut.u_gcm.u_aes.key_odd!==0 || rd!==0)
                $fatal(1,"KDF/AES state not erased at edge 3");
            @(posedge clk);#1;
            if(dut.u_kdf.material!==0 || dut.u_kdf.key_shift!==0 || dut.u_kdf.body_shift!==0 ||
               dut.u_kdf.info_shift!==0 || dut.u_kdf.prk!==0 || dut.u_kdf.build_byte_q!==0 ||
               dut.u_kdf.u_hash.u_permutation.state!==0 ||
               dut.u_kdf.u_hash.u_permutation.round_mid!==0 ||
               dut.u_kdf.u_hash.u_permutation.theta_d_q!==0 ||
               dut.u_kdf.u_hash.sponge_state!==0 || dut.u_kdf.u_hash.absorb_mask!==0 ||
               dut.u_kdf.u_hash.absorb_byte_q!==0 || dut.u_kdf.u_hash.squeeze_lane!==0 ||
               dut.u_kdf.u_hash.perm_load_lane_data!==0 || dut.u_kdf.sponge_out!==0 ||
               dut.u_kdf.u_hash.result_valid!==0 || dut.u_gcm.key_reg!==0 ||
               dut.u_gcm.u_aes.key_even!==0 || dut.u_gcm.u_aes.key_odd!==0 ||
               dut.u_gcm.u_aes.next_even!==0 || dut.u_gcm.u_aes.schedule_temp!==0)
                $fatal(1,"local clear pipeline retained key/state");
            repeat(300)begin
                @(posedge clk);#1;
                if(active!==0 || busy!==0 || done!==0 || rd!==0 || epoch!==saved_epoch)
                    $fatal(1,"stale operation resurrected or epoch reset");
            end
            for(j=0;j<256;j++)
                if(dut.u_gcm.input_mem[j]!==0 || dut.u_gcm.output_mem[j]!==0)
                    $fatal(1,"GCM RAM wipe incomplete: %0d",j);
        end
    endtask
    initial begin
        repeat(4)@(negedge clk);rst_n=1;
        begin_derive();
        wait(dut.u_kdf.u_hash.u_permutation.busy && dut.u_kdf.u_hash.u_permutation.round_phase);
        clear_and_check();
        begin_derive();wait(done);@(negedge clk);
        if(!active || err!==0 || epoch!==2)$fatal(1,"derive after KDF abort");
        begin_seal();wait(dut.u_gcm.u_aes.busy);repeat(12)@(negedge clk);
        clear_and_check();
        begin_derive();wait(done);@(negedge clk);
        if(!active || err!==0 || epoch!==3)$fatal(1,"derive after AES abort");
        begin_seal();wait(done);@(negedge clk);
        if(err!==0 || !dut.last_seal)$fatal(1,"seal after abort");
        clear_and_check();
        $display("CHANNEL_PIPELINE_GUARDS: ALL TESTS PASS clear_during_Keccak_AES after_result clear_pulse=1 session_edges=2 primitive_edges=4 ram_wipe_checked no_stale_done epoch_preserved");
        $finish;
    end
    initial begin #5000000;$fatal(1,"watchdog");end
endmodule


