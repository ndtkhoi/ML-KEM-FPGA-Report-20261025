`timescale 1ns/1ps

module tb_random_subsystem;

    logic clk;
    logic rst_n;

    logic shake_start;
    logic shake_zeroize;
    logic [511:0] shake_entropy;
    logic [255:0] shake_state;
    logic [767:0] shake_vectors;
    logic [255:0] shake_next_state;
    logic [31:0] shake_crc;
    logic [31:0] shake_cycles;
    logic shake_busy;
    logic shake_done;

    logic raw_bit;
    logic raw_valid;
    logic [31:0] raw_samples;
    logic startup_done;
    logic health_pass;
    logic health_alarm;
    logic inject_alarm=0;
    logic [15:0] rct_fails;
    logic [15:0] apt_fails;
    logic [9:0] apt_ones;
    logic [31:0] checked_samples;
    logic rng_generate;
    logic rng_zeroize;
    logic [255:0] seed_d;
    logic [255:0] seed_z;
    logic [255:0] message_m;
    logic [31:0] rng_crc;
    logic [31:0] rng_cycles;
    logic [31:0] reseed_count;
    logic pool_full;
    logic rng_ready;
    logic rng_busy;
    logic rng_done;

    logic fault_clear;
    logic fault_bit;
    logic fault_valid;
    logic fault_startup_done;
    logic fault_health_pass;
    logic fault_alarm;
    logic [15:0] fault_rct_fails;
    logic [15:0] fault_apt_fails;
    logic [9:0] fault_apt_ones;
    logic [31:0] fault_samples;

    integer byte_index;
    logic [31:0] first_crc;
    logic [31:0] second_crc;

    shake256_drbg u_shake_kat (
        .clk(clk), .rst_n(rst_n), .start(shake_start),
        .zeroize(shake_zeroize), .entropy_input(shake_entropy),
        .previous_state(shake_state), .request_counter(32'd1),
        .random_vectors(shake_vectors), .next_state(shake_next_state),
        .vector_crc32(shake_crc), .cycle_count(shake_cycles),
        .busy(shake_busy), .done(shake_done)
    );

    fpga_ro_entropy #(
        .RO_COUNT(8), .RO_STAGES(3), .SAMPLE_DIV(2)
    ) u_entropy (
        .clk(clk), .rst_n(rst_n), .enable(1'b1),
        .raw_bit(raw_bit), .raw_valid(raw_valid),
        .sample_count(raw_samples)
    );

    entropy_health u_health (
        .clk(clk), .rst_n(rst_n), .clear(1'b0),
        .raw_bit(raw_bit), .raw_valid(raw_valid),
        .startup_done(startup_done), .health_pass(health_pass),
        .alarm_latched(health_alarm), .rct_fail_count(rct_fails),
        .apt_fail_count(apt_fails), .last_apt_ones(apt_ones),
        .checked_samples(checked_samples)
    );

    mlkem_random_manager u_manager (
        .clk(clk), .rst_n(rst_n), .generate_start(rng_generate),
        .zeroize(rng_zeroize), .raw_bit(raw_bit), .raw_valid(raw_valid),
        .health_pass(health_pass), .health_alarm(health_alarm || inject_alarm),
        .seed_d(seed_d), .seed_z(seed_z), .message_m(message_m),
        .vector_crc32(rng_crc), .generate_cycles(rng_cycles),
        .reseed_count(reseed_count), .pool_full(pool_full),
        .ready(rng_ready), .busy(rng_busy), .done(rng_done)
    );

    entropy_health #(
        .RCT_LIMIT(8), .APT_WINDOW(16),
        .APT_LOW_ONES(4), .APT_HIGH_ONES(12)
    ) u_fault_health (
        .clk(clk), .rst_n(rst_n), .clear(fault_clear),
        .raw_bit(fault_bit), .raw_valid(fault_valid),
        .startup_done(fault_startup_done),
        .health_pass(fault_health_pass),
        .alarm_latched(fault_alarm),
        .rct_fail_count(fault_rct_fails),
        .apt_fail_count(fault_apt_fails),
        .last_apt_ones(fault_apt_ones),
        .checked_samples(fault_samples)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task automatic pulse_rng_generate;
        begin
            wait (rng_ready);
            @(negedge clk);
            rng_generate = 1'b1;
            @(negedge clk);
            rng_generate = 1'b0;
            wait (rng_done);
            @(posedge clk);
        end
    endtask

    task automatic send_fault_bit(input logic value);
        begin
            @(negedge clk);
            fault_bit   = value;
            fault_valid = 1'b1;
            @(negedge clk);
            fault_valid = 1'b0;
        end
    endtask

    initial begin
        rst_n         = 1'b0;
        shake_start   = 1'b0;
        shake_zeroize = 1'b0;
        shake_entropy = 512'd0;
        shake_state   = 256'd0;
        rng_generate  = 1'b0;
        rng_zeroize   = 1'b0;
        fault_clear   = 1'b0;
        fault_bit     = 1'b0;
        fault_valid   = 1'b0;

        for (byte_index = 0; byte_index < 64; byte_index = byte_index + 1)
            shake_entropy[8 * byte_index +: 8] = byte_index[7:0];
        for (byte_index = 0; byte_index < 32; byte_index = byte_index + 1)
            shake_state[8 * byte_index +: 8] = (8'hA0 + byte_index[7:0]);

        repeat (8) @(posedge clk);
        rst_n = 1'b1;
`ifdef MLKEM_STREAMING_BALANCED_4BU
        // The 4BU DRBG physically scrubs its retained Keccak state for 25
        // clocks after reset before accepting the first request.
        wait (!shake_busy);
`endif

        // KAT doi chieu voi Python hashlib.shake_256.
        @(negedge clk);
        shake_start = 1'b1;
        @(negedge clk);
        shake_start = 1'b0;
        wait (shake_done);
        #1;
        if (shake_vectors !== 768'h6da9c6b79ba56148c6ee38e3c4ec793dc85dd441d0b7480bccc73c63612d1db653685c003fbd3ee98f79859f5b0728e366e99a913758d8da0a266d497891b80dc63b42543574d73e71b6693f20cc76e232a5fbd299579acccfbb3fac22458888)
            $fatal(1, "SHAKE256 DRBG vector mismatch");
        if (shake_next_state !== 256'hfeb96d48ade47121c99b4f746f1da871df7b101a2ff8dfd3fb6e10fa84f425a7)
            $fatal(1, "SHAKE256 DRBG next-state mismatch");
        if (shake_crc !== 32'h7782556E)
            $fatal(1, "SHAKE256 DRBG CRC mismatch got=%08x", shake_crc);

        // Health test phai qua tren mo hinh va hai lan sinh phai khac nhau.
        wait (health_pass && rng_ready);
        if (rct_fails || apt_fails)
            $fatal(1, "Simulation entropy health unexpectedly failed");

        pulse_rng_generate();
        first_crc = rng_crc;
        if ((seed_d === 256'd0) || (seed_z === 256'd0) ||
            (message_m === 256'd0) || (rng_crc == 32'd0) ||
            (reseed_count != 32'd1))
            $fatal(1, "First random-manager result invalid");

        pulse_rng_generate();
        second_crc = rng_crc;
        if ((rng_crc == first_crc) || (reseed_count != 32'd2))
            $fatal(1, "Two random-manager runs did not differ");

        // Chuoi 8 bit 0 lien tiep phai kich RCT va khoa health output.
        for (byte_index = 0; byte_index < 8; byte_index = byte_index + 1)
            send_fault_bit(1'b0);
        if (!fault_alarm || (fault_rct_fails == 0) || fault_health_pass)
            $fatal(1, "RCT fault injection was not detected");

        @(negedge clk);
        rng_zeroize = 1'b1;
        @(negedge clk);
        rng_zeroize = 1'b0;
        @(posedge clk);
        if ((seed_d !== 256'd0) || (seed_z !== 256'd0) ||
            (message_m !== 256'd0) || (rng_crc !== 32'd0))
            $fatal(1, "Random subsystem zeroize failed");

        // Interrupt a permutation in its populated middle stage through the
        // SAME manager health-alarm input that was the failing recovery source.
        wait(rng_ready);
        @(negedge clk);rng_generate=1;
        @(negedge clk);rng_generate=0;
        wait(u_manager.u_drbg.u_permutation.busy &&
             u_manager.u_drbg.u_permutation.round_phase);
        @(negedge clk);inject_alarm=1;
        #1;if(rng_ready)$fatal(1,"alarm did not block ready immediately");
        @(negedge clk);
        if(rng_done || rng_busy || seed_d!==0 || seed_z!==0 || message_m!==0 ||
           u_manager.entropy_pool!==0 || u_manager.drbg_state!==0)
            $fatal(1,"alarm did not invalidate public vectors and pool");
        @(negedge clk);
`ifdef MLKEM_STREAMING_BALANCED_4BU
        wait(!u_manager.u_drbg.busy);
        @(negedge clk);
`endif
        if(u_manager.u_drbg.u_permutation.state!==0 ||
           u_manager.u_drbg.u_permutation.round_mid!==0 ||
           u_manager.u_drbg.u_permutation.read_lane_data!==0 ||
           u_manager.u_drbg.u_permutation.busy || u_manager.u_drbg.u_permutation.done)
            $fatal(1,"local synchronous clear did not erase primitive in two clocks");
        repeat(80)begin
            @(negedge clk);
            if(rng_done || rng_ready || rng_busy || seed_d!==0 ||
               u_manager.u_drbg.u_permutation.state!==0)
                $fatal(1,"stale RNG transaction while health alarm active");
        end
        inject_alarm=0;
        pulse_rng_generate();
        if(rng_crc==0 || reseed_count!=3)$fatal(1,"RNG restart after alarm-clear failed");
`ifdef MLKEM_STREAMING_BALANCED_4BU
        $display("DRBG_ALARM_CLEAR: PASS abort_mid_round sequential_25_lane_scrub no_stale_done restart");
`else
        $display("DRBG_ALARM_CLEAR: PASS abort_mid_round clear_within_two_clocks no_stale_done restart");
`endif

        // A one-cycle direct zeroize pulse must also flush an active primitive.
        @(negedge clk);shake_start=1;
        @(negedge clk);shake_start=0;
        wait(u_shake_kat.u_permutation.busy && u_shake_kat.u_permutation.round_phase);
        @(negedge clk);shake_zeroize=1;
        @(negedge clk);shake_zeroize=0;
`ifdef MLKEM_STREAMING_BALANCED_4BU
        wait(!shake_busy);
        @(negedge clk);
`endif
        if(shake_vectors!==0 || shake_next_state!==0 || shake_done || shake_busy)
            $fatal(1,"direct DRBG zeroize did not clear outputs");
        @(negedge clk);
        if(u_shake_kat.u_permutation.state!==0 || u_shake_kat.u_permutation.round_mid!==0)
            $fatal(1,"direct DRBG zeroize did not flush pipeline");
        repeat(80)begin @(negedge clk);if(shake_done)$fatal(1,"stale DRBG done after abort");end
`ifdef MLKEM_STREAMING_BALANCED_4BU
        $display("DRBG_PULSE_CLEAR: PASS mid_round zeroize_one_clock sequential_25_lane_scrub");
`else
        $display("DRBG_PULSE_CLEAR: PASS mid_round zeroize_one_clock");
`endif

        $display(
            "TRNG_HEALTH_SHAKE256_DRBG: PASS samples=%0d apt_ones=%0d first_crc=%08x second_crc=%08x",
            checked_samples, apt_ones, first_crc, second_crc
        );
        $finish;
    end
    initial begin #2000000;$fatal(1,"random subsystem watchdog");end

endmodule
