`timescale 1ns/1ps

module tb_multiply_ntts;

    logic clk;
    logic rst_n;
    logic start;
    logic load_a_we;
    logic load_b_we;
    logic [7:0] load_address;
    logic [11:0] load_a_data;
    logic [11:0] load_b_data;
    logic [7:0] read_address;
    logic [11:0] read_data;
    logic busy;
    logic done;
    logic [31:0] cycle_count;
    logic [6:0] debug_pair_index;

    logic [11:0] input_a [0:255];
    logic [11:0] input_b [0:255];
    logic [11:0] expected [0:255];

    integer index;
    integer error_count;
    integer measured_cycles;

    multiply_ntts_core dut (
        .clk              (clk),
        .rst_n            (rst_n),
        .start            (start),
        .load_a_we        (load_a_we),
        .load_b_we        (load_b_we),
        .load_address     (load_address),
        .load_a_data      (load_a_data),
        .load_b_data      (load_b_data),
        .read_address     (read_address),
        .read_data        (read_data),
        .busy             (busy),
        .done             (done),
        .cycle_count      (cycle_count),
        .debug_pair_index (debug_pair_index)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    initial begin
        $readmemh("03_vectors/ntt/mul_a.hex", input_a);
        $readmemh("03_vectors/ntt/mul_b.hex", input_b);
        $readmemh("03_vectors/ntt/mul_expected.hex", expected);

        rst_n           = 1'b0;
        start           = 1'b0;
        load_a_we       = 1'b0;
        load_b_we       = 1'b0;
        load_address    = 8'd0;
        load_a_data     = 12'd0;
        load_b_data     = 12'd0;
        read_address    = 8'd0;
        error_count     = 0;
        measured_cycles = 0;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;

        for (index = 0; index < 256; index = index + 1) begin
            @(negedge clk);
            load_a_we    = 1'b1;
            load_b_we    = 1'b1;
            load_address = index[7:0];
            load_a_data  = input_a[index];
            load_b_data  = input_b[index];
        end

        @(negedge clk);
        load_a_we = 1'b0;
        load_b_we = 1'b0;
        start   = 1'b1;
        @(negedge clk);
        start   = 1'b0;

        fork : timeout_block
            begin
                wait (done == 1'b1);
            end
            begin
                repeat (4000) @(posedge clk);
                $fatal(
                    1,
                    "MultiplyNTTs timeout pair_index=%0d",
                    debug_pair_index
                );
            end
        join_any
        disable timeout_block;

        measured_cycles = cycle_count;

        for (index = 0; index < 256; index = index + 1) begin
            @(negedge clk);
            read_address = index[7:0];
            @(posedge clk);
            #1;

            if (read_data !== expected[index]) begin
                if (error_count < 8)
                    $display(
                        "MULTIPLY_NTTS FAIL coefficient=%0d got=%0d expected=%0d",
                        index, read_data, expected[index]
                    );
                error_count = error_count + 1;
            end
        end

        if (error_count == 0) begin
            $display(
                "MULTIPLY_NTTS_FIPS203_ALG11: PASS coefficients=256 cycles=%0d",
                measured_cycles
            );
            $finish;
        end else begin
            $fatal(1, "MULTIPLY_NTTS_FIPS203_ALG11: FAIL errors=%0d", error_count);
        end
    end

endmodule
