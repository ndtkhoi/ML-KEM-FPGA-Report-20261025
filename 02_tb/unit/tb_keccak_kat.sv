`timescale 1ns/1ps

module tb_keccak_kat;

    logic clk;
    logic rst_n;
    logic start;
    logic load_we;
    logic [4:0] load_lane_index;
    logic [63:0] load_lane_data;
    logic [4:0] read_lane_index;
    logic [63:0] read_lane_data;
    logic busy;
    logic done;
    logic [6:0] cycle_count;
    logic [4:0] debug_round_index;

    integer lane;
    integer error_count;
    integer lanes_to_check;
    logic [63:0] expected;

    localparam integer TEST_SHA3_256 = 0;
    localparam integer TEST_SHA3_512 = 1;
    localparam integer TEST_SHAKE128 = 2;
    localparam integer TEST_SHAKE256 = 3;

    keccak_f1600_core dut (
        .zeroize(1'b0),
        .clk               (clk),
        .rst_n             (rst_n),
        .start             (start),
        .load_we           (load_we),
        .load_lane_index   (load_lane_index),
        .load_lane_data    (load_lane_data),
        .read_lane_index   (read_lane_index),
        .read_lane_data    (read_lane_data),
        .busy              (busy),
        .done              (done),
        .cycle_count       (cycle_count),
        .debug_round_index (debug_round_index)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    function automatic [63:0] expected_lane;
        input integer test_id;
        input integer lane_index;
        begin
            expected_lane = 64'd0;
            case (test_id)
                TEST_SHA3_256: begin
                    case (lane_index)
                        0: expected_lane = 64'h66D71EBFF8C6FFA7;
                        1: expected_lane = 64'h62D661A05647C151;
                        2: expected_lane = 64'hFA493BE44DFF80F5;
                        3: expected_lane = 64'h4A43F8804B0AD882;
                        default: expected_lane = 64'd0;
                    endcase
                end

                TEST_SHA3_512: begin
                    case (lane_index)
                        0: expected_lane = 64'hC59A3AA2CC739FA6;
                        1: expected_lane = 64'h6E755A18DC67B5C8;
                        2: expected_lane = 64'h5958E24F1682C997;
                        3: expected_lane = 64'hA6805C47C1DCD1E0;
                        4: expected_lane = 64'h4CF9F5F13A12B215;
                        5: expected_lane = 64'h58C53A2C40E9E311;
                        6: expected_lane = 64'hE3D3B6959D1900F5;
                        7: expected_lane = 64'h26CD1D2886857501;
                        default: expected_lane = 64'd0;
                    endcase
                end

                TEST_SHAKE128: begin
                    case (lane_index)
                        0: expected_lane = 64'h7D828FE8A42B9C7F;
                        1: expected_lane = 64'h3E85057650456061;
                        2: expected_lane = 64'h88BCEFF693803BD7;
                        3: expected_lane = 64'h26EF66FAAC6E1AEB;
                        default: expected_lane = 64'd0;
                    endcase
                end

                TEST_SHAKE256: begin
                    case (lane_index)
                        0: expected_lane = 64'h138DA80B2BDDB946;
                        1: expected_lane = 64'h24EB3E74EB3F3B23;
                        2: expected_lane = 64'h821BB862EA52CD3F;
                        3: expected_lane = 64'h2F76D56E64270CB5;
                        default: expected_lane = 64'd0;
                    endcase
                end

                default: expected_lane = 64'd0;
            endcase
        end
    endfunction

    task automatic clear_state;
        begin
            for (lane = 0; lane < 25; lane = lane + 1) begin
                @(negedge clk);
                load_we         = 1'b1;
                load_lane_index = lane[4:0];
                load_lane_data  = 64'd0;
            end
            @(negedge clk);
            load_we = 1'b0;
        end
    endtask

    task automatic load_padding;
        input [7:0] domain;
        input integer final_lane;
        begin
            clear_state();

            @(negedge clk);
            load_we         = 1'b1;
            load_lane_index = 5'd0;
            load_lane_data  = {56'd0, domain};

            @(negedge clk);
            load_lane_index = final_lane[4:0];
            load_lane_data  = 64'h8000000000000000;

            @(negedge clk);
            load_we = 1'b0;
        end
    endtask

    task automatic run_permutation;
        begin
            @(negedge clk);
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;

            fork : timeout_block
                begin
                    wait (done == 1'b1);
                end
                begin
                    // The retimed primitive executes 24 rounds in 48 clocks.
                    repeat (64) @(posedge clk);
                    $fatal(
                        1,
                        "Keccak timeout round=%0d",
                        debug_round_index
                    );
                end
            join_any
            disable timeout_block;
            if (cycle_count !== 6'd48)
                $fatal(1,"Unexpected Keccak latency: %0d",cycle_count);
        end
    endtask

    task automatic check_digest;
        input integer test_id;
        input integer digest_lane_count;
        begin
            for (lane = 0; lane < digest_lane_count; lane = lane + 1) begin
                read_lane_index = lane[4:0];
                #1;
                expected = expected_lane(test_id, lane);
                if (read_lane_data !== expected) begin
                    $display(
                        "KECCAK KAT FAIL test=%0d lane=%0d got=%016h expected=%016h",
                        test_id,
                        lane,
                        read_lane_data,
                        expected
                    );
                    error_count = error_count + 1;
                end
            end
        end
    endtask

    initial begin
        rst_n           = 1'b0;
        start           = 1'b0;
        load_we         = 1'b0;
        load_lane_index = 5'd0;
        load_lane_data  = 64'd0;
        read_lane_index = 5'd0;
        error_count     = 0;
        lanes_to_check  = 0;
        expected        = 64'd0;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;

        // Empty SHA3-256: rate=136 bytes, domain=0x06.
        load_padding(8'h06, 16);
        run_permutation();
        check_digest(TEST_SHA3_256, 4);
        $display("SHA3_256_EMPTY_KAT: checked cycles=%0d", cycle_count);

        // Empty SHA3-512: rate=72 bytes, domain=0x06.
        load_padding(8'h06, 8);
        run_permutation();
        check_digest(TEST_SHA3_512, 8);
        $display("SHA3_512_EMPTY_KAT: checked cycles=%0d", cycle_count);

        // Empty SHAKE128: rate=168 bytes, domain=0x1F.
        load_padding(8'h1F, 20);
        run_permutation();
        check_digest(TEST_SHAKE128, 4);
        $display("SHAKE128_EMPTY_KAT: checked cycles=%0d", cycle_count);

        // Empty SHAKE256: rate=136 bytes, domain=0x1F.
        load_padding(8'h1F, 16);
        run_permutation();
        check_digest(TEST_SHAKE256, 4);
        $display("SHAKE256_EMPTY_KAT: checked cycles=%0d", cycle_count);

        if (error_count == 0) begin
            $display("KECCAK_SHA3_SHAKE_KAT: PASS tests=4");
            $finish;
        end else begin
            $fatal(1, "KECCAK_SHA3_SHAKE_KAT: FAIL errors=%0d", error_count);
        end
    end

endmodule
