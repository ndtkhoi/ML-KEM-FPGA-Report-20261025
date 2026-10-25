`timescale 1ns/1ps
// Regression for the synchronous-RAM optimization. Not an entropy or side-channel certification.
module tb_opt100_memory_guards;
    logic clk=0; always #5 clk=~clk;
    logic rst_n=0,clear=0,start=0,dec=0,we=0,la=0;
    logic [255:0] key=0;
    logic [95:0] iv=0;
    logic [127:0] tin=0,tout;
    logic [8:0] len=0;
    logic [5:0] alen=0;
    logic [7:0] wa=0,wd=0,ra=0,rd;
    wire busy,done,ok;
    wire [31:0] cycles;
    aes_gcm_core dut(.clk(clk),.rst_n(rst_n),.zeroize(clear),.start(start),.decrypt(dec),
        .key(key),.iv(iv),.tag_in(tin),.data_length(len),.aad_length(alen),
        .load_we(we),.load_aad(la),.load_address(wa),.load_data(wd),.read_address(ra),.read_data(rd),
        .tag_out(tout),.busy(busy),.done(done),.auth_ok(ok),.cycles(cycles));

    logic ss=0,scbd=0,swe=0;
    logic [9:0] swa=0;
    logic [7:0] swd=0,sra=0;
    wire [11:0] srd;
    wire sbusy,sdone,serr;
    mlkem_sampler sampler(.clk(clk),.rst_n(rst_n),.start(ss),.sample_cbd(scbd),
        .load_byte_we(swe),.load_byte_address(swa),.load_byte_data(swd),
        .read_coefficient_address(sra),.read_coefficient_data(srd),
        .busy(sbusy),.done(sdone),.sample_error(serr),.cycle_count());

    logic [255:0] keys[0:9]; logic [95:0] ivs[0:9]; logic [127:0] tags[0:9];
    logic [8:0] lens[0:9]; logic [5:0] alens[0:9];
    logic [7:0] pv[0:2559],cv[0:2559],av[0:319];
    integer j,trial,timeout_cycles;
    logic [31:0] valid_cycles;

    task automatic load_gcm(input integer v,input bit decrypting,input logic [127:0] tag_mask);
        integer n;
        begin
            @(negedge clk);
            key=keys[v];iv=ivs[v];len=lens[v];alen=alens[v];dec=decrypting;tin=tags[v]^tag_mask;
            for(n=0;n<alens[v];n=n+1)begin
                we=1;la=1;wa=n;wd=av[v*32+n];@(negedge clk);
            end
            for(n=0;n<lens[v];n=n+1)begin
                we=1;la=0;wa=n;wd=decrypting?cv[v*256+n]:pv[v*256+n];@(negedge clk);
            end
            we=0;
        end
    endtask
    task automatic launch_gcm;
        begin
            start=1;#1;if(rd!==0)$fatal(1,"old result visible on start");
            @(negedge clk);start=0;
        end
    endtask
    task automatic await_gcm;
        integer t;
        begin
            t=0;
            while(!done && t<30000)begin
                @(negedge clk);t=t+1;
                if(busy && rd!==0)$fatal(1,"unauthenticated/busy output");
            end
            we=0;
            if(!done)$fatal(1,"GCM timeout");
        end
    endtask
    task automatic check_memories(input integer v,input bit good,input bit decrypting);
        integer n;
        logic [7:0] expected_byte;
        begin
            if(ok!==good)$fatal(1,"auth flag");
            if(dut.key_reg!==0 || dut.stream_reg!==0 || dut.h_reg!==0)
                $fatal(1,"intermediate key registers not cleared");
            for(n=0;n<256;n=n+1)begin
                if(dut.input_mem[n]!==0)$fatal(1,"input wipe byte %0d",n);
                if(!good && dut.output_mem[n]!==0)$fatal(1,"output wipe byte %0d",n);
                ra=n;@(posedge clk);#1;
                expected_byte=0;
                if(good && n<lens[v])expected_byte=decrypting?pv[v*256+n]:cv[v*256+n];
                if(rd!==expected_byte)$fatal(1,"read byte %0d got=%h expected=%h",n,rd,expected_byte);
                @(negedge clk);
            end
        end
    endtask
    task automatic sampler_load(input integer pattern,input integer count);
        integer n;
        begin
            for(n=0;n<count;n=n+1)begin
                @(negedge clk);swe=1;swa=n;swd=0;
                case(pattern)
                    0:swd=8'hff; // Two rejected 4095 candidates per group.
                    1:begin // First group contains 3328 (accept), 3329 (reject).
                        if(n==0)swd=8'h00;
                        if(n==1)swd=8'h1d;
                        if(n==2)swd=8'hd0;
                    end
                    2:swd=(n==127)?8'hf0:8'h3c;
                    default:swd=0;
                endcase
            end
            @(negedge clk);swe=0;
        end
    endtask
    task automatic sampler_run(input bit cbd,input bit error_expected);
        integer t;
        begin
            scbd=cbd;ss=1;@(negedge clk);ss=0;
            // A2 contract: caller must not write sampler input while busy.
            // Illegal writes are checked in a separate expected-fatal test.
            swe=0;t=0;
            while(!sdone && t<2000)begin @(negedge clk);t=t+1;end
            swe=0;
            if(!sdone || serr!==error_expected)$fatal(1,"sampler finish/error");
        end
    endtask
    initial begin
        $readmemh("03_vectors/channel/key.mem",keys);$readmemh("03_vectors/channel/iv.mem",ivs);
        $readmemh("03_vectors/channel/tag.mem",tags);$readmemh("03_vectors/channel/len.mem",lens);
        $readmemh("03_vectors/channel/alen.mem",alens);$readmemh("03_vectors/channel/input.mem",pv);
        $readmemh("03_vectors/channel/output.mem",cv);$readmemh("03_vectors/channel/aad.mem",av);
        repeat(3)@(negedge clk);rst_n=1;

        // Maximum message, tag errors at opposite ends. Latency must not depend on tag match.
        for(trial=0;trial<3;trial=trial+1)begin
            load_gcm(8,1,(trial==0)?128'd0:((trial==1)?128'd1:(128'd1<<127)));
            launch_gcm();
            // Check input latching and busy-load exclusion, not merely output equality.
            key=~key;iv=~iv;tin=~tin;len=0;alen=0;dec=0;
            we=1;la=0;wa=0;wd=8'ha5;
            await_gcm();
            if(trial==0)valid_cycles=cycles;
            else if(cycles!==valid_cycles)$fatal(1,"tag-dependent cycles");
            check_memories(8,trial==0,1);
        end
        $display("GCM_RAM_GUARDS: PASS max_payload tag_first_last constant_cycles=%0d wipe256 busy_load latched_inputs",valid_cycles);

        // Reuse after a long operation; addresses beyond this shorter result must be hidden.
        load_gcm(1,0,0);launch_gcm();await_gcm();
        if(tout!==tags[1])$fatal(1,"short tag");
        check_memories(1,1,0);
        #1;rst_n=0;#1;if(rd!==0)$fatal(1,"reset output guard");
        repeat(3)@(negedge clk);rst_n=1;

        // Abort while writing plaintext and then verify physical RAM wiping.
        load_gcm(8,1,0);launch_gcm();
        wait(dut.state==dut.D_BUILD);@(negedge clk);clear=1;
        #1;if(rd!==0)$fatal(1,"zeroize immediate output guard");
        repeat(2)@(negedge clk);clear=0;
        await_gcm();check_memories(8,0,1);

        // Bad lengths must terminate fail-closed, not address outside the small memories.
        load_gcm(1,0,0);len=257;launch_gcm();await_gcm();check_memories(1,0,0);
        load_gcm(1,0,0);alen=33;launch_gcm();await_gcm();check_memories(1,0,0);
        $display("GCM_RAM_GUARDS: PASS short_after_long reset zeroize_during_payload invalid_lengths");

        sampler_load(0,840);sampler_run(0,1);
        if(sampler.coefficient_count!==0)$fatal(1,"rejected candidates stored");
        sampler_load(1,840);sampler_run(0,0);
        if(sampler.coefficient_count!==256)$fatal(1,"last first-candidate count");
        for(j=0;j<256;j=j+1)begin
            sra=j;@(posedge clk);#1;
            if(srd!==((j==0)?12'd3328:12'd0))$fatal(1,"sample boundary byte %0d",j);
            @(negedge clk);
        end
        sampler_load(3,840);sampler_run(0,0);
        if(sampler.coefficient_count!==256)$fatal(1,"last second-candidate count");
        sampler_load(2,128);sampler_run(1,0);
        for(j=0;j<256;j=j+1)begin
            sra=j;@(posedge clk);#1;
            if(srd!==((j>=254)?12'd0:((j%2==0)?12'd3327:12'd2)))$fatal(1,"CBD byte %0d",j);
            @(negedge clk);
        end
        $display("SAMPLER_RAM_GUARDS: PASS reject_all q_boundary both_terminal_candidates CBD_signed last_byte caller_no_busy_write");
        $display("OPT100_MEMORY_GUARDS: ALL TESTS PASS");$finish;
    end
    initial begin #10000000;$fatal(1,"memory guard watchdog");end
endmodule
