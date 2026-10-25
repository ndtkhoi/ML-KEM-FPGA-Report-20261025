`timescale 1ns/1ps

module tb_ntt_intt;

    logic clk;
    logic rst_n;
    logic start;
    logic inverse;
    logic load_we;
    logic [7:0] load_address;
    logic [11:0] load_data;
    logic [7:0] read_address;
    logic [11:0] read_data;
    logic busy;
    logic done;
    logic [31:0] cycle_count;
    logic [7:0] debug_length;
    logic [7:0] debug_j;
    logic [6:0] debug_zeta_index;

    logic [11:0] ntt_input [0:255];
    logic [11:0] ntt_expected [0:255];
    logic [11:0] intt_input [0:255];
    logic [11:0] intt_expected [0:255];

    integer index;
    integer error_count;
    integer errors_before;
    integer ntt_cycles;
    integer intt_cycles;

`ifdef MLKEM_STREAMING_BALANCED_2BU
    ntt_core_stream2 dut (
`else
    ntt_core dut (
`endif
        .clk              (clk),
        .rst_n            (rst_n),
        .start            (start),
        .inverse          (inverse),
        .load_we          (load_we),
        .load_address     (load_address),
        .load_data        (load_data),
        .read_address     (read_address),
        .read_data        (read_data),
        .busy             (busy),
        .done             (done),
        .cycle_count      (cycle_count),
        .debug_length     (debug_length),
        .debug_j          (debug_j),
        .debug_zeta_index (debug_zeta_index)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task automatic load_polynomial(input logic select_intt_input);
        begin
            for (index = 0; index < 256; index = index + 1) begin
                @(negedge clk);
                load_we      = 1'b1;
                load_address = index[7:0];
                if (select_intt_input)
                    load_data = intt_input[index];
                else
                    load_data = ntt_input[index];
            end
            @(negedge clk);
            load_we = 1'b0;
        end
    endtask

    task automatic start_operation(input logic operation_inverse);
        begin
            @(negedge clk);
            inverse = operation_inverse;
            start   = 1'b1;
            @(negedge clk);
            start   = 1'b0;
        end
    endtask

    task automatic wait_for_done;
        integer timeout_count;
        begin
            timeout_count = 0;
            while ((done != 1'b1) && (timeout_count < 20000)) begin
                @(posedge clk);
                timeout_count = timeout_count + 1;
            end
            if (done != 1'b1)
                $fatal(
                    1,
                    "NTT/INTT timeout length=%0d j=%0d zeta_index=%0d",
                    debug_length,
                    debug_j,
                    debug_zeta_index
                );
        end
    endtask

    task automatic compare_output(input logic select_intt_expected);
        begin
            for (index = 0; index < 256; index = index + 1) begin
                @(negedge clk);
                read_address = index[7:0];
                @(posedge clk);
`ifdef MLKEM_STREAMING_BALANCED_2BU
                // stream4 registers both the M10K output and the external
                // bank-selection mux.  The integrated service core already
                // prefetches by two addresses; mirror that two-cycle latency
                // in this direct unit-level readback as well.
                @(posedge clk);
`endif
                #1;

                if (select_intt_expected) begin
                    if (read_data !== intt_expected[index]) begin
                        if ((error_count - errors_before) < 8)
                            $display(
                                "INTT FAIL coefficient=%0d got=%0d expected=%0d",
                                index, read_data, intt_expected[index]
                            );
                        error_count = error_count + 1;
                    end
                end else begin
                    if (read_data !== ntt_expected[index]) begin
                        if ((error_count - errors_before) < 8)
                            $display(
                                "NTT FAIL coefficient=%0d got=%0d expected=%0d",
                                index, read_data, ntt_expected[index]
                            );
                        error_count = error_count + 1;
                    end
                end
            end
        end
    endtask

    initial begin
        $readmemh("03_vectors/ntt/ntt_input.hex", ntt_input);
        $readmemh("03_vectors/ntt/ntt_expected.hex", ntt_expected);
        $readmemh("03_vectors/ntt/intt_input.hex", intt_input);
        $readmemh("03_vectors/ntt/intt_expected.hex", intt_expected);

        rst_n         = 1'b0;
        start         = 1'b0;
        inverse       = 1'b0;
        load_we       = 1'b0;
        load_address  = 8'd0;
        load_data     = 12'd0;
        read_address  = 8'd0;
        error_count   = 0;
        errors_before = 0;
        ntt_cycles    = 0;
        intt_cycles   = 0;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;

        load_polynomial(1'b0);
        start_operation(1'b0);
        wait_for_done();
        ntt_cycles    = cycle_count;
        errors_before = error_count;
        compare_output(1'b0);

        if (error_count == errors_before)
            $display(
                "NTT_FIPS203_ALG9: PASS coefficients=256 cycles=%0d",
                ntt_cycles
            );

        load_polynomial(1'b1);
        start_operation(1'b1);
        wait_for_done();
        intt_cycles   = cycle_count;
        errors_before = error_count;
        compare_output(1'b1);

        if (error_count == errors_before)
            $display(
                "INTT_FIPS203_ALG10: PASS coefficients=256 cycles=%0d",
                intt_cycles
            );

        if (error_count == 0) begin
            $display(
                "NTT_INTT_ROUND_TRIP: PASS ntt_cycles=%0d intt_cycles=%0d",
                ntt_cycles,
                intt_cycles
            );
            $finish;
        end else begin
            $fatal(1, "NTT_INTT_ROUND_TRIP: FAIL errors=%0d", error_count);
        end
    end

endmodule
