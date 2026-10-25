`timescale 1ns/1ps
// Exhaustive combinational check of the exact decoded-coefficient RAM input.
// Functional byte-stream sequencing remains covered by tb_codec_sampler.
module tb_codec_reduction_guard;
    logic clk=0;
    integer raw,width,expected,checked=0;
    byte_codec_core dut(.clk(clk),.rst_n(1'b0),.start(1'b0),.encode(1'b0),.d(4'd0),
        .load_coefficient_we(1'b0),.load_coefficient_address(8'd0),.load_coefficient_data(12'd0),
        .load_byte_we(1'b0),.load_byte_address(9'd0),.load_byte_data(8'd0),
        .read_coefficient_address(8'd0),.read_byte_address(9'd0),
        .read_coefficient_data(),.read_byte_data(),.busy(),.done(),.invalid_d(),.cycle_count());
    initial begin
        force dut.busy=1'b1;
        force dut.bit_buffer=raw;
        force dut.d_reg=width;
        for(width=1;width<=12;width++) begin
            if(width==1 || width==4 || width==5 || width==10 || width==11 || width==12) begin
                for(raw=0;raw<4096;raw++) begin
                    #1;
                    expected=raw&((1<<width)-1);
                    if(width==12) expected=expected%3329;
                    if(dut.coefficient_write_data!==expected[11:0])
                        $fatal(1,"decode reduction d=%0d raw=%0d got=%0d expected=%0d",width,raw,dut.coefficient_write_data,expected);
                    checked++;
                end
            end
        end
        release dut.busy;release dut.bit_buffer;release dut.d_reg;
        $display("CODEC_REDUCTION_GUARD: ALL TESTS PASS checked=%0d six_widths all_12bit_values",checked);
        $finish;
    end
    initial begin #100000;$fatal(1,"codec reduction watchdog");end
endmodule
