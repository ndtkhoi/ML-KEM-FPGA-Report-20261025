`timescale 1ns/1ps
// Expected failure: A2 sampler's caller must not write while busy.
module tb_sampler_busy_contract;
    logic clk=0; always #3.125 clk=~clk;
    logic rst_n=0,start=0,we=0;
    wire busy;
    mlkem_sampler dut(.clk(clk),.rst_n(rst_n),.start(start),.sample_cbd(1'b0),
        .load_byte_we(we),.load_byte_address(10'd0),.load_byte_data(8'hff),
        .read_coefficient_address(8'd0),.read_coefficient_data(),
        .busy(busy),.done(),.sample_error(),.cycle_count());
    initial begin
        repeat(3) @(negedge clk);rst_n=1;
        @(negedge clk);start=1;
        @(negedge clk);start=0;
        if(!busy)$fatal(1,"CONTRACT_TEST_DID_NOT_START");
        we=1;
        repeat(3) @(negedge clk);
        $fatal(1,"MISSING_EXPECTED_BUSY_ASSERTION");
    end
endmodule
