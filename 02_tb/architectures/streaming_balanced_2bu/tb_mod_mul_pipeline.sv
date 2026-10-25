`timescale 1ns/1ps
// Streaming scoreboard for the seven-stage 160 MHz Barrett datapath.
module tb_mod_mul_pipeline;
    logic clk=0; always #3.333 clk=~clk;
    logic rst_n=0,in_valid=0;
    logic [11:0] a=0,b=0,r;
    logic out_valid;
    logic valid_expected[0:6];
    logic [11:0] result_expected[0:6];
    integer j,i,k,checked=0,reset_count=0;
    integer boundaries[0:11];
    logic [31:0] prng=32'h71ac0935;
    mod_mul_pipe dut(.*);
    always @(posedge clk) begin
        if(!rst_n) begin
            for(j=0;j<7;j=j+1) begin valid_expected[j]=0;result_expected[j]=0;end
        end else begin
            for(j=6;j>0;j=j-1) begin
                valid_expected[j]=valid_expected[j-1];
                result_expected[j]=result_expected[j-1];
            end
            valid_expected[0]=in_valid;
            result_expected[0]=(int'(a)*int'(b))%3329;
        end
        #0.001;
        if(out_valid!==valid_expected[6])$fatal(1,"valid/latency mismatch checked=%0d",checked);
        if(out_valid) begin
            if(r!==result_expected[6] || r>=3329)
                $fatal(1,"product mismatch got=%0d expected=%0d",r,result_expected[6]);
            checked=checked+1;
        end
    end
    task automatic reset_pipe;
        begin
            @(negedge clk);rst_n=0;in_valid=0;
            repeat(3)@(negedge clk);rst_n=1;reset_count=reset_count+1;
        end
    endtask
    initial begin
        boundaries[0]=0;boundaries[1]=1;boundaries[2]=2;boundaries[3]=1664;
        boundaries[4]=1665;boundaries[5]=2047;boundaries[6]=2048;
        boundaries[7]=3327;boundaries[8]=3328;boundaries[9]=3329;
        boundaries[10]=4094;boundaries[11]=4095;
        reset_pipe();
        for(k=0;k<12;k=k+1)for(i=0;i<4096;i=i+1)begin
            @(negedge clk);in_valid=1;a=i;b=boundaries[k];
        end
        @(negedge clk);in_valid=0;
        repeat(8)@(negedge clk);
        if(checked!=49152)$fatal(1,"boundary coverage count=%0d",checked);
        // Deterministic random inputs, bubbles, and reset with transactions pending.
        for(i=0;i<50000;i=i+1)begin
            @(negedge clk);
            prng=prng^(prng<<13);prng=prng^(prng>>17);prng=prng^(prng<<5);
            a=prng[11:0];b=prng[23:12];in_valid=(prng[25:24]!=0);
            if(i==10000 || i==25000)reset_pipe();
        end
        @(negedge clk);in_valid=0;repeat(9)@(negedge clk);
        $display("MOD_MUL_PIPELINE: ALL TESTS PASS checked=%0d boundary=49152 random_bubbles resets=%0d latency=6 throughput=1",checked,reset_count);
        $finish;
    end
    initial begin #2000000;$fatal(1,"watchdog");end
endmodule
