`timescale 1ns/1ps
// Independent mathematical oracle plus pipeline memory hazards/reset coverage.
module tb_ntt_banked_guards;
    logic clk=0; always #3.333 clk=~clk;
    logic rst_n=0,start=0,inverse=0,load_we=0;
    logic [7:0] load_address=0,read_address=0;
    logic [11:0] load_data=0;
    wire [11:0] read_data;
    wire busy,done;
    wire [31:0] cycle_count;
    wire [7:0] debug_length,debug_j;
    wire [6:0] debug_zeta_index;
    ntt_core_stream2 dut(.*);
    logic mul_start=0,ma_we=0,mb_we=0;
    logic [7:0] mul_load_address=0,mul_read_address=0;
    logic [11:0] ma_data=0,mb_data=0;
    wire [11:0] mul_read_data;
    wire mul_busy,mul_done;
    wire [31:0] mul_cycles;
    multiply_ntts_core mul(.clk(clk),.rst_n(rst_n),.start(mul_start),
        .load_a_we(ma_we),.load_b_we(mb_we),.load_address(mul_load_address),
        .load_a_data(ma_data),.load_b_data(mb_data),.read_address(mul_read_address),
        .read_data(mul_read_data),.busy(mul_busy),.done(mul_done),
        .cycle_count(mul_cycles),.debug_pair_index());
    integer a[0:255],b[0:255],gold[0:255],saved[0:255],na[0:255],nb[0:255];
    integer product_gold[0:255],convolution[0:255],actual[0:255];
    integer seed=32'h37f5ac19, test_id, i,j,v,transforms=0,multiplications=0,aborts=0;
    integer read_seen[0:255],write_seen[0:255],stage_reads,stage_writes;
    integer stage_checks=0,issue_streak=0,write_streak=0;
    integer mul_writes=0;
    integer versions[0:255], read_marks[0:6][0:255], write_marks[0:6][0:255];
    integer all_reads=0,all_writes=0,rs,ws;
    integer expected_cycles=459;
    logic previous_mul_write=0;
    logic stage_tracking=0,previous_issue=0,previous_write=0;
    function automatic integer twiddle(input integer idx);
        integer rev,k,acc,t;
        begin
            rev=0;t=idx;
            for(k=0;k<7;k++) begin rev=2*rev+(t%2);t=t/2;end
            acc=1;
            for(k=0;k<rev;k++) acc=(acc*17)%3329;
            twiddle=acc;
        end
    endfunction
    // FIPS 203 direct loops. INTT uses final *3303; deliberately does not
    // repeat the RTL's distributed division by two.
    task automatic reference_transform(input bit inv);
        integer len,s,k,z,x,y,t,n;
        begin
            k=inv?127:1;len=inv?2:128;
            while((inv && len<=128)||(!inv && len>=2)) begin
                for(s=0;s<256;s+=2*len) begin
                    z=twiddle(k);k+=inv?-1:1;
                    for(n=s;n<s+len;n++) begin
                        x=gold[n];y=gold[n+len];
                        if(inv) begin
                            gold[n]=(x+y)%3329;
                            gold[n+len]=(((y-x+3329)%3329)*z)%3329;
                        end else begin
                            t=(z*y)%3329;
                            gold[n]=(x+t)%3329;gold[n+len]=(x-t+3329)%3329;
                        end
                    end
                end
                len=inv?len*2:len/2;
            end
            if(inv) for(n=0;n<256;n++) gold[n]=(gold[n]*3303)%3329;
        end
    endtask
    task automatic load_gold;
        integer n;
        begin
            for(n=0;n<256;n++) begin
                @(negedge clk);load_we=1;load_address=n;load_data=gold[n];
            end
            @(negedge clk);load_we=0;
        end
    endtask
    task automatic run_transform(input bit inv,input bit noisy_inputs);
        integer timeout,n;
        begin
            reference_transform(inv);
            @(negedge clk);start=1;inverse=inv;
            @(negedge clk);start=0;inverse=!inv;timeout=0;
            while(!done && timeout<1500) begin
                @(negedge clk);timeout++;
                if(noisy_inputs) begin
                    // Busy-start and external writes must not alter the stream.
                    start=(timeout==20);load_we=(timeout>10 && timeout<30);
                    load_address=137;load_data=3328;
                end
            end
            start=0;load_we=0;
            if(expected_cycles<0) expected_cycles=cycle_count;
            if(!done || cycle_count!=expected_cycles || all_reads!=896 || all_writes!=896) $fatal(1,"NTT stream latency inv=%0d cycles=%0d",inv,cycle_count);
            for(n=0;n<256;n++) begin
                @(negedge clk);read_address=n;
                repeat(2) @(posedge clk);#1;
                actual[n]=read_data;
                if(read_data!==gold[n][11:0])
                    $fatal(1,"NTT oracle test=%0d inv=%0d idx=%0d got=%0d expected=%0d",test_id,inv,n,read_data,gold[n]);
            end
            @(negedge clk);
            if(done) $fatal(1,"NTT done pulse did not clear");
            transforms++;
        end
    endtask
    // Track coefficient versions before each read to detect cross-stage RAW
    // hazards, including read/write on the same edge (RAM returns old data).
    always @(posedge clk) begin
        if(!rst_n) begin
            all_reads=0;all_writes=0;previous_issue=0;previous_write=0;
            mul_writes=0;previous_mul_write=0;
        end else begin
            if(dut.state==dut.S_IDLE && start) begin
                all_reads=0;all_writes=0;previous_issue=0;previous_write=0;
                for(integer n=0;n<256;n++) begin
                    versions[n]=0;
                    for(integer st=0;st<7;st++) begin
                        read_marks[st][n]=0;write_marks[st][n]=0;
                    end
                end
            end
            if(dut.issue_valid) begin : read_check
                integer mask,aa,bb,ba,bank_b;
                mask=0;rs=all_reads/128;
                if(all_reads>=896 || (all_reads>0 && all_reads%128!=0 && !previous_issue))
                    $fatal(1,"2BU issue count/bubble");
                for(integer lane=0;lane<2;lane++) begin
                    aa=dut.issue_addr_a[lane];bb=dut.issue_addr_b[lane];
                    ba=((^(aa>>1))<<1)|(aa&1);bank_b=((^(bb>>1))<<1)|(bb&1);
                    if((mask&(1<<ba)) || (mask&(1<<bank_b)) || ba==bank_b)
                        $fatal(1,"2BU read bank conflict");
                    mask=mask|(1<<ba)|(1<<bank_b);
                    if(dut.bank_read_address[ba] !== (aa>>2) ||
                       dut.bank_read_address[bank_b] !== (bb>>2))
                        $fatal(1,"2BU physical read row mapping");
                    if(versions[aa]!=rs || versions[bb]!=rs)
                        $fatal(1,"2BU cross-stage RAW hazard stage=%0d a=%0d b=%0d",rs,aa,bb);
                    if(read_marks[rs][aa] || read_marks[rs][bb])
                        $fatal(1,"2BU duplicate read");
                    read_marks[rs][aa]=1;read_marks[rs][bb]=1;
                end
                if(mask!=15) $fatal(1,"2BU missing read bank");
                all_reads+=2;
            end
            if(dut.write_valid && busy) begin : write_check
                integer mask,aa,bb,ba,bank_b;
                mask=0;ws=all_writes/128;
                if(all_writes>=896 || (all_writes>0 && all_writes%128!=0 && !previous_write))
                    $fatal(1,"2BU write count/bubble");
                for(integer lane=0;lane<2;lane++) begin
                    aa=dut.write_addr_a[lane];bb=dut.write_addr_b[lane];
                    ba=((^(aa>>1))<<1)|(aa&1);bank_b=((^(bb>>1))<<1)|(bb&1);
                    if((mask&(1<<ba)) || (mask&(1<<bank_b)) || ba==bank_b)
                        $fatal(1,"2BU write bank conflict");
                    mask=mask|(1<<ba)|(1<<bank_b);
                    if(!dut.bank_write_enable[ba] || !dut.bank_write_enable[bank_b] ||
                       dut.bank_write_address[ba] !== (aa>>2) ||
                       dut.bank_write_address[bank_b] !== (bb>>2))
                        $fatal(1,"2BU physical write mapping");
                    if(write_marks[ws][aa] || write_marks[ws][bb])
                        $fatal(1,"2BU duplicate write");
                    write_marks[ws][aa]=1;write_marks[ws][bb]=1;
                    versions[aa]=ws+1;versions[bb]=ws+1;
                end
                if(mask!=15) $fatal(1,"2BU missing write bank");
                all_writes+=2;
                if(all_writes%128==0) begin
                    for(integer n=0;n<256;n++)
                        if(!read_marks[ws][n] || !write_marks[ws][n])
                            $fatal(1,"2BU stage missing coefficient");
                    stage_checks++;
                end
            end
            previous_issue=dut.issue_valid;previous_write=dut.write_valid;
            if(mul.state==mul.S_IDLE && mul_start) begin mul_writes=0;previous_mul_write=0;end
            if(mul.write_valid && mul_busy) begin
                if(mul.write_pair!=mul_writes || (mul_writes>0 && !previous_mul_write))
                    $fatal(1,"MultiplyNTTs reorder/bubble");
                mul_writes++;
            end
            previous_mul_write=mul.write_valid;
        end
    end
    task automatic run_multiply;
        integer n,z,t,cross_value,timeout;
        begin
            for(n=0;n<128;n++) begin
                z=twiddle(64+n/2);if(n%2) z=3329-z;
                t=(na[2*n+1]*nb[2*n+1])%3329;
                product_gold[2*n]=((na[2*n]*nb[2*n])%3329+(t*z)%3329)%3329;
                cross_value=(na[2*n]*nb[2*n+1]+na[2*n+1]*nb[2*n])%3329;
                product_gold[2*n+1]=cross_value;
            end
            for(n=0;n<256;n++) begin
                @(negedge clk);ma_we=1;mb_we=1;mul_load_address=n;
                ma_data=na[n];mb_data=nb[n];
            end
            @(negedge clk);ma_we=0;mb_we=0;mul_start=1;
            @(negedge clk);mul_start=0;timeout=0;
            while(!mul_done && timeout<300) begin @(negedge clk);timeout++;end
            if(!mul_done || mul_cycles!=143 || mul_writes!=128)
                $fatal(1,"MultiplyNTTs stream latency/count");
            for(n=0;n<256;n++) begin
                @(negedge clk);mul_read_address=n;@(posedge clk);#1;
                if(mul_read_data!==product_gold[n][11:0])
                    $fatal(1,"MultiplyNTTs oracle idx=%0d got=%0d exp=%0d",n,mul_read_data,product_gold[n]);
                gold[n]=mul_read_data;
            end
            multiplications++;
        end
    endtask
    initial begin #20000000; $fatal(1,"Banked guard watchdog"); end
    initial begin
        repeat(4) @(negedge clk);rst_n=1;
        for(test_id=0;test_id<24;test_id++) begin
            for(i=0;i<256;i++) begin
                case(test_id)
                    0:v=0;
                    1:v=3328;
                    2:v=(i==0);
                    3:v=(i==255);
                    4:v=(i%2)?3328:0;
                    default:v=$unsigned($random(seed))%3329;
                endcase
                gold[i]=v;saved[i]=v;
            end
            load_gold();run_transform(0,1);
            // Chained INTT consumes the actual result plane without reload.
            run_transform(1,0);
            for(i=0;i<256;i++) if(actual[i]!=saved[i]) $fatal(1,"in-place roundtrip");
            for(i=0;i<256;i++) gold[i]=$unsigned($random(seed))%3329;
            load_gold();run_transform(1,1);
        end
        for(test_id=0;test_id<8;test_id++) begin
            for(i=0;i<256;i++) begin
                a[i]=$unsigned($random(seed))%3329;b[i]=$unsigned($random(seed))%3329;
                convolution[i]=0;gold[i]=a[i];
            end
            load_gold();run_transform(0,0);for(i=0;i<256;i++) na[i]=actual[i];
            for(i=0;i<256;i++) gold[i]=b[i];
            load_gold();run_transform(0,0);for(i=0;i<256;i++) nb[i]=actual[i];
            run_multiply();load_gold();run_transform(1,0);
            for(i=0;i<256;i++) for(j=0;j<256;j++) begin
                v=(a[i]*b[j])%3329;
                if(i+j<256) convolution[i+j]=(convolution[i+j]+v)%3329;
                else convolution[i+j-256]=(convolution[i+j-256]-v+3329)%3329;
            end
            for(i=0;i<256;i++) if(actual[i]!=convolution[i])
                $fatal(1,"schoolbook negacyclic mismatch idx=%0d",i);
        end
        // Abort before fill, inside issue, during drain and after bank swaps.
        for(test_id=0;test_id<8;test_id++) begin
            for(i=0;i<256;i++) gold[i]=$unsigned($random(seed))%3329;
            load_gold();
            @(negedge clk);start=1;inverse=test_id%2;
            @(negedge clk);start=0;
            case(test_id)
                0:repeat(1) @(negedge clk);
                1:repeat(6) @(negedge clk);
                2:repeat(20) @(negedge clk);
                3:repeat(32) @(negedge clk);
                4:repeat(40) @(negedge clk);
                5:repeat(70) @(negedge clk);
                6:repeat(180) @(negedge clk);
                7:repeat(226) @(negedge clk);
            endcase
            #1;rst_n=0;repeat(3) @(negedge clk);rst_n=1;
            repeat(20) begin @(negedge clk);
                if(busy || done || dut.write_valid || mul.write_valid) $fatal(1,"stale work after reset");
            end
            load_gold();run_transform(test_id%2,0);aborts++;
        end
        // Reset also flushes both cascaded multiplier pipelines before restart.
        for(test_id=0;test_id<4;test_id++) begin
            @(negedge clk);mul_start=1;@(negedge clk);mul_start=0;
            repeat(5+test_id*40) @(negedge clk);
            #1;rst_n=0;repeat(3) @(negedge clk);rst_n=1;
            repeat(20) begin @(negedge clk);
                if(mul_busy || mul_done || mul.write_valid) $fatal(1,"stale MultiplyNTTs after reset");
            end
            run_multiply();aborts++;
        end
        $display("NTT_BANKED_GUARDS: ALL TESTS PASS transforms=%0d multiply_runs=%0d schoolbook_convolutions=8 reset_aborts=%0d stages=%0d ntt_intt_cycles=%0d mul_cycles=143 butterflies_per_issue=2",
            transforms,multiplications,aborts,stage_checks,expected_cycles);
        $finish;
    end
endmodule
