`timescale 1ns/1ps

module tb_keccak_sponge;

    logic clk;
    logic rst_n;
    logic start;
    logic [1:0] mode;
    logic [11:0] input_length;
    logic [10:0] output_length;
    logic input_we;
    logic [10:0] input_address;
    logic [7:0] input_data;
    logic [9:0] output_address;
    logic [7:0] output_data;
    logic busy;
    logic done;
    logic [31:0] cycle_count;
    logic [3:0] debug_state;

    logic [7:0] input_vector [0:2047];
    logic [7:0] expected_vector [0:1023];
    integer index;
    integer errors;

    keccak_sponge dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .zeroize        (1'b0),
        .start          (start),
        .mode           (mode),
        .input_length   (input_length),
        .output_length  (output_length),
        .input_we       (input_we),
        .input_address  (input_address),
        .input_data     (input_data),
        .output_address (output_address),
        .output_data    (output_data),
        .busy           (busy),
        .done           (done),
        .cycle_count    (cycle_count),
        .debug_state    (debug_state)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task automatic run_case(
        input string case_name,
        input string input_file,
        input string expected_file,
        input logic [1:0] selected_mode,
        input integer message_bytes,
        input integer digest_bytes
    );
        integer local_errors;
        begin
            for (index = 0; index < 2048; index = index + 1)
                input_vector[index] = 8'd0;
            for (index = 0; index < 1024; index = index + 1)
                expected_vector[index] = 8'd0;
            if (message_bytes > 0)
                $readmemh(input_file, input_vector, 0, message_bytes - 1);
            $readmemh(expected_file, expected_vector, 0, digest_bytes - 1);

            for (index = 0; index < message_bytes; index = index + 1) begin
                @(negedge clk);
                input_we      = 1'b1;
                input_address = index[10:0];
                input_data    = input_vector[index];
            end
            @(negedge clk);
            input_we      = 1'b0;
            mode          = selected_mode;
            input_length  = message_bytes[11:0];
            output_length = digest_bytes[10:0];
            start         = 1'b1;
            @(negedge clk);
            start = 1'b0;

            fork : wait_or_timeout
                begin
                    wait (done == 1'b1);
                end
                begin
                    repeat (20000) @(posedge clk);
                    $fatal(1, "%s timeout state=%0d", case_name, debug_state);
                end
            join_any
            disable wait_or_timeout;

            local_errors = 0;
            for (index = 0; index < digest_bytes; index = index + 1) begin
                @(negedge clk);
                output_address = index[9:0];
                @(posedge clk);
                #1;
                if (output_data !== expected_vector[index]) begin
                    if (local_errors < 8)
                        $display(
                            "%s mismatch byte=%0d got=%02x expected=%02x",
                            case_name, index, output_data, expected_vector[index]
                        );
                    local_errors = local_errors + 1;
                end
            end
            if (local_errors != 0)
                $fatal(1, "%s failed errors=%0d", case_name, local_errors);
            $display("%s: PASS cycles=%0d", case_name, cycle_count);
        end
    endtask

    initial begin
        rst_n          = 1'b0;
        start          = 1'b0;
        mode           = 2'd0;
        input_length   = 12'd0;
        output_length  = 11'd0;
        input_we       = 1'b0;
        input_address  = 11'd0;
        input_data     = 8'd0;
        output_address = 10'd0;
        errors          = 0;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        // The sponge deliberately pipelines its wide datapath-clear token by
        // one clock.  Do not present start in that release cycle.
        @(negedge clk);

        run_case(
            "SHA3_256_EMPTY",
            "03_vectors/full/sponge/sha3_256_empty_input.hex",
            "03_vectors/full/sponge/sha3_256_empty_expected.hex",
            2'd0, 0, 32
        );
        run_case(
            "SHA3_512_ABC",
            "03_vectors/full/sponge/sha3_512_abc_input.hex",
            "03_vectors/full/sponge/sha3_512_abc_expected.hex",
            2'd1, 3, 64
        );
        run_case(
            "SHAKE128_MULTIBLOCK",
            "03_vectors/full/sponge/shake128_multiblock_input.hex",
            "03_vectors/full/sponge/shake128_multiblock_expected.hex",
            2'd2, 200, 400
        );
        run_case(
            "SHAKE256_LONG",
            "03_vectors/full/sponge/shake256_long_input.hex",
            "03_vectors/full/sponge/shake256_long_expected.hex",
            2'd3, 1600, 512
        );

        $display("KECCAK_SPONGE_REGRESSION: PASS");
        $finish;
    end

endmodule
