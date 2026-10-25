`timescale 1ns/1ps
module tb_compress_seq;
    logic clk=0;always #5 clk=~clk;
    logic rst_n=0,start=0,compress=0;
    logic [3:0] d=0;
    logic [11:0] value=0;
    wire [11:0] result;wire valid_d,busy,done;
    compress_seq dut(.*);
    integer widths[0:5]='{1,4,5,10,11,12};
    integer k,x,n,expected,total=0;
    task automatic check_one(input bit comp,input integer width,input integer v,input integer exp);
        begin
            @(negedge clk);compress=comp;d=width;value=v;start=1;
            @(negedge clk);start=0;d=0;value=0;compress=0;
            n=0;while(!done&&n<20)begin @(negedge clk);n++;end
            if(!done || result!==exp[11:0] || !valid_d)
                $fatal(1,"compress_seq comp=%0d d=%0d x=%0d got=%0d expected=%0d",comp,width,v,result,exp);
            total++;
        end
    endtask
    initial begin
        repeat(3)@(negedge clk);rst_n=1;
        for(k=0;k<6;k++) begin
            // Exhaustive tren mien he so chuan va toan bo codeword d bit.
            for(x=0;x<3329;x++)begin
                expected=(((x<<widths[k])+1664)/3329)&((1<<widths[k])-1);
                check_one(1,widths[k],x,expected);
            end
            for(x=0;x<(1<<widths[k]);x++)begin
                expected=(x*3329+(1<<(widths[k]-1)))>>widths[k];
                check_one(0,widths[k],x,expected);
            end
        end
        @(negedge clk);d=3;start=1;compress=1;value=3328;
        @(negedge clk);start=0;wait(done);@(negedge clk);
        if(valid_d||result!==0)$fatal(1,"invalid d not rejected");
        start=1;d=11;@(negedge clk);start=0;repeat(2)@(negedge clk);rst_n=0;
        @(negedge clk);if(busy||done||result!==0)$fatal(1,"reset during operation");rst_n=1;
        check_one(1,11,3328,2047);
        $display("COMPRESS_SEQ: ALL TESTS PASS exhaustive=%0d invalid_d reset latch_inputs",total);$finish;
    end
    initial begin #10000000;$fatal(1,"timeout");end
endmodule
