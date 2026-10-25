`timescale 1ns/1ps
module tb_channel_keydemo;
    logic CLOCK_50=0; always #10 CLOCK_50=~CLOCK_50;
    logic [3:0] KEY=4'b1110;
    logic [9:0] SW=0;
    logic UART_RX=1;
    wire UART_TX;
    wire [9:0] LEDR;
    wire [6:0] HEX0,HEX1,HEX2,HEX3,HEX4,HEX5;
    mlkem_channel_keydemo_top #(.UART_CLOCK_HZ(4000000),.UART_BAUD(1000000),
        .KEY_DEBOUNCE_CYCLES(8)) dut(.*);
    defparam dut.u_service.RNG_TIMEOUT_CYCLES=2000;
    // Deterministic RNG boundary for independent golden-vector checks.
    // Physical TRNG entropy is not claimed by this simulation.
    logic [255:0] rd,rz,rm;
    logic rng_done=0, rng_allow=1, rng_alarm=0;
    always @(posedge dut.clk_sys) rng_done<=dut.rng_generate && rng_allow;
    logic [7:0] golden_ek[0:1567],golden_ct[0:1567],golden_ss[0:31],golden_fp[0:31];
    string expected_byte;
    string line="",op="",error="",status="",selftest="",fp="",mode="";
    string ops[0:2],fps[0:2],tests[0:2],errors[0:2];
    logic [31:0] cycles_hex=0,cycles_dec=0;
    logic [7:0] b;
    integer blocks=0,starts=0,expected_mode=768,eklen=1184,ctlen=1088;
    bit check_vectors=1;
    always @(negedge dut.clk_sys) begin
        if(dut.board_start) starts++;
        if(check_vectors && dut.u_service.core_done && dut.u_service.core_pass) begin
            if(dut.u_service.operation==1)
                for(integer j=0;j<eklen;j++)
                    if(dut.u_service.u_core.u_byte_store.memory[j]!==golden_ek[j])
                        $fatal(1,"KeyGen golden byte %0d",j);
            if(dut.u_service.operation==2) begin
                for(integer j=0;j<ctlen;j++)
                    if(dut.u_service.u_core.u_byte_store.memory[4800+j]!==golden_ct[j])
                        $fatal(1,"Encaps ciphertext golden byte %0d",j);
                for(integer j=0;j<32;j++)
                    if(dut.u_service.ss_enc[8*j+:8]!==golden_ss[j]) $fatal(1,"Encaps secret golden");
            end
            if(dut.u_service.operation==3)
                for(integer j=0;j<32;j++)
                    if(dut.u_service.ss_dec[8*j+:8]!==golden_ss[j]) $fatal(1,"Decaps secret golden");
        end
    end
    initial forever begin
        @(negedge UART_TX); repeat(6) @(posedge dut.clk_sys);
        for(integer j=0;j<8;j++) begin b[j]=UART_TX;repeat(4)@(posedge dut.clk_sys);end
        if(UART_TX!==1) $fatal(1,"UART stop bit");
        if(b==10) begin
            if(line.len()>=4 && line.substr(0,3)=="OP: ") op=line.substr(4,line.len()-1);
            if(line.len()>=6 && line.substr(0,5)=="MODE: ") mode=line.substr(6,line.len()-1);
            if(line.len()>=7 && line.substr(0,6)=="ERROR: ") error=line.substr(7,line.len()-1);
            if(line.len()>=8 && line.substr(0,7)=="STATUS: ") status=line.substr(8,line.len()-1);
            if(line.len()>=10 && line.substr(0,9)=="SELFTEST: ") selftest=line.substr(10,line.len()-1);
            if(line.len()>=9 && line.substr(0,8)=="SS_SHA3: ") fp=line.substr(9,line.len()-1);
            if(line.len()>=12 && line.substr(0,11)=="CYCLES_HEX: ")
                if($sscanf(line,"CYCLES_HEX: %h",cycles_hex)!=1) $fatal(1,"bad hex cycles");
            if(line.len()>=12 && line.substr(0,11)=="CYCLES_DEC: ")
                if($sscanf(line,"CYCLES_DEC: %d",cycles_dec)!=1) $fatal(1,"bad decimal cycles");
            if(line=="END") begin
                if(blocks>=3) $fatal(1,"duplicate run/report");
                if(mode!=$sformatf("%0d",expected_mode)) $fatal(1,"mode not latched");
                if(cycles_hex!==cycles_dec) $fatal(1,"hex/decimal cycle mismatch");
                if((error=="00") != (status=="OK")) $fatal(1,"status/error inconsistent");
                ops[blocks]=op;fps[blocks]=fp;tests[blocks]=selftest;errors[blocks]=error;
                blocks++;
                $display("KEYDEMO mode=%s op=%s cycles=%0d error=%s selftest=%s",mode,op,cycles_dec,error,selftest);
            end
            line="";
        end else if(b!=13) line={line,b};
    end
    task automatic idle;
        wait(!dut.service_busy && dut.route==0);repeat(20)@(negedge dut.clk_sys);
    endtask
    task automatic prepare(input integer m);
        string prefix;
        begin
            idle(); KEY[1]=1;repeat(30)@(negedge dut.clk_sys);
            blocks=0;op="";error="";selftest="";line="";
            expected_mode=m;SW[0]=(m==1024);eklen=(m==1024)?1568:1184;ctlen=(m==1024)?1568:1088;
            prefix=$sformatf("03_vectors/service/%0d_a",m);
            $readmemh({prefix,"_ek.mem"},golden_ek,0,eklen-1);
            $readmemh({prefix,"_ct.mem"},golden_ct,0,ctlen-1);
            $readmemh({prefix,"_ss.mem"},golden_ss);$readmemh({prefix,"_fp.mem"},golden_fp);
            repeat(10)@(negedge dut.clk_sys);
        end
    endtask
    task automatic press;
        begin
            // Three short bounces must not start a request.
            repeat(3) begin KEY[1]=0;repeat(2)@(negedge dut.clk_sys);
                KEY[1]=1;repeat(2)@(negedge dut.clk_sys);end
            KEY[1]=0;wait(dut.u_service.demo_active);
        end
    endtask
    task automatic inject_host_frame;
        string frame;
        begin
            frame="!Z7000008F48FD7A\n";
            for(integer i=0;i<frame.len();i++) begin
                @(negedge dut.clk_sys);UART_RX=0;repeat(4)@(negedge dut.clk_sys);
                for(integer j=0;j<8;j++) begin UART_RX=(frame.getc(i)>>j)&1;repeat(4)@(negedge dut.clk_sys);end
                UART_RX=1;repeat(6)@(negedge dut.clk_sys);
            end
        end
    endtask
    initial begin
        for(integer j=0;j<32;j++) begin rd[8*j+:8]=j;rz[8*j+:8]=j+32;rm[8*j+:8]=j+64;end
        force dut.rng_ready=rng_allow;
        force dut.rng_done=rng_done;
        force dut.rng_d=rd;force dut.rng_z=rz;force dut.rng_m=rm;
        force dut.health=1'b1;force dut.alarm=rng_alarm;
        repeat(8)@(negedge CLOCK_50);KEY[0]=1;wait(dut.reset_sync_n);
        for(integer m=768;m<=1024;m+=256) begin
            prepare(m);press();
            // Later switch changes must not change an in-progress transaction.
            SW[0]=!SW[0];
            inject_host_frame(); // Incoming host traffic cannot interrupt KEY1.
            wait(blocks==3);idle();
            if(ops[0]!="K" || ops[1]!="E" || ops[2]!="D" ||
               tests[0]!="RUNNING" || tests[1]!="RUNNING" || tests[2]!="PASS")
                $fatal(1,"K/E/D ordering or self-test result");
            if(fps[1]!=fps[2] || fps[1].len()!=64) $fatal(1,"digest mismatch");
            for(integer j=0;j<32;j++) begin
                expected_byte=$sformatf("%02x",golden_fp[j]);
                if(fps[2].substr(2*j,2*j+1)!=expected_byte.toupper())
                    $fatal(1,"printed fingerprint golden");
            end
            if(dut.kem_display_code!=={golden_fp[0],golden_fp[1],golden_fp[2]} || !LEDR[7])
                $fatal(1,"board fingerprint/PASS LED");
            if(dut.u_service.demo_secret!==0 || dut.u_service.demo_secret_valid)
                $fatal(1,"reference secret retained");
            repeat(100)@(negedge dut.clk_sys);
            if(blocks!=3 || starts!=(m==768?1:2)) $fatal(1,"held/bouncing key retriggered");
        end
        // The final PASS must depend on equality of the raw 256-bit secrets.
        prepare(768);press();
        wait(dut.u_service.state==dut.u_service.DEMO_NEXT && dut.u_service.operation==2);
        force dut.u_service.demo_secret=256'd0;
        wait(blocks==3);release dut.u_service.demo_secret;idle();
        if(tests[2]!="FAIL" || errors[2]!="E2" || LEDR[7] || dut.key_ready)
            $fatal(1,"mismatch must FAIL and wipe key");
        // Unavailable entropy must terminate with FAIL instead of hanging.
        prepare(768);rng_allow=0;press();wait(blocks==1);idle();
        if(tests[0]!="FAIL" || errors[0]!="E1" || dut.key_ready) $fatal(1,"RNG timeout");
        rng_allow=1;
        prepare(768);rng_alarm=1;press();wait(blocks==1);idle();
        if(tests[0]!="FAIL" || errors[0]!="E1" || dut.key_ready) $fatal(1,"RNG alarm");
        rng_alarm=0;
        // Reset in flight aborts the transaction; a held button does not restart.
        prepare(768);press();wait(dut.u_service.core_busy && dut.u_service.operation==1);
        KEY[0]=0;repeat(10)@(negedge CLOCK_50);KEY[0]=1;wait(dut.reset_sync_n);idle();
        if(dut.u_service.demo_active || dut.key_ready || dut.u_service.demo_secret!==0)
            $fatal(1,"reset failed to abort/clear");
        $display("KEYDEMO: ALL TESTS PASS both_modes golden_bytes serial_pins debounce held_key mode_latch mismatch RNG_timeout reset");
        $finish;
    end
    initial begin #100000000;$fatal(1,"KEYDEMO watchdog");end
endmodule

