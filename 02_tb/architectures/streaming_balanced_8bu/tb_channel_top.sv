`timescale 1ns/1ps
module tb_channel_top;
    logic CLOCK_50=0;always #10 CLOCK_50=~CLOCK_50;
    logic [3:0] KEY=4'b1110;logic [9:0] SW=0;
    wire [9:0] LEDR;wire [6:0] HEX0,HEX1,HEX2,HEX3,HEX4,HEX5;
    logic UART_RX=1;wire UART_TX;
    mlkem_channel_top #(.UART_CLOCK_HZ(4_000_000),.UART_BAUD(1_000_000))dut(.*);
    string line="",response="",err="",data="",tag="",phash="",payload,expected;
    bit ended=0;logic [7:0] b;
    logic [7:0] kem_ct[0:1087],inc[0:271],outc[0:271],msg[0:255];
    logic [8:0] lengths[0:1];logic [255:0] digest[0:0];integer ml,ol,j;
    function automatic byte hc(input logic [3:0] n);hc=n<10?8'h30+n:8'h61+n-10;endfunction
    function automatic string hx(input byte x);hx={hc(x[7:4]),hc(x[3:0])};endfunction
    function automatic logic [31:0] cb(input logic [31:0] a,input byte d);
        logic [31:0] v;integer n;begin v=a^d;for(n=0;n<8;n++)v=v[0]?((v>>1)^32'hedb88320):(v>>1);cb=v;end
    endfunction
    task automatic put(input byte d);
        integer n;begin
            @(negedge dut.clk_sys);UART_RX=0;repeat(4)@(negedge dut.clk_sys);
            for(n=0;n<8;n++)begin UART_RX=d[n];repeat(4)@(negedge dut.clk_sys);end
            UART_RX=1;repeat(6)@(negedge dut.clk_sys);
        end
    endtask
    task automatic command(input string prefix,input string opcode,input string p,input string expected_error="00");
        string body,frame;logic [31:0] crc;integer n,t;
        begin
            wait(!dut.service_busy&&dut.route==0);ended=0;response="";err="";phash="";data="";tag="";
            body={opcode,"70",$sformatf("%04x",p.len()/2),p};crc=32'hffffffff;
            for(n=0;n<body.len();n++)crc=cb(crc,body.getc(n));
            frame={prefix,body,$sformatf("%08x",~crc),"\n"};for(n=0;n<frame.len();n++)put(frame.getc(n));
            t=0;while(!ended&&t<2000000)begin @(negedge dut.clk_sys);t++;end
            if(!ended||err!=expected_error)$fatal(1,"serial top %s err=%s response=%s",opcode,err,response);
            wait(!dut.service_busy&&dut.route==0);repeat(5)@(negedge dut.clk_sys);
            $display("CHANNEL_TOP op=%s error=%s LEDR=%b",opcode,err,LEDR);
        end
    endtask
    initial forever begin
        @(negedge UART_TX);repeat(6)@(posedge dut.clk_sys);
        for(integer n=0;n<8;n++)begin b[n]=UART_TX;repeat(4)@(posedge dut.clk_sys);end
        if(UART_TX!==1)$fatal(1,"stop bit");
        if(b==10)begin
            response={response,line,"\n"};
            if(line.len()>=7&&line.substr(0,6)=="ERROR: ")err=line.substr(7,line.len()-1).tolower();
            if(line.len()>=10&&line.substr(0,9)=="DATA_HEX: ")data=line.substr(10,line.len()-1).tolower();
            if(line.len()>=5&&line.substr(0,4)=="TAG: ")tag=line.substr(5,line.len()-1).tolower();
            if(line.len()>=16&&line.substr(0,15)=="PLAINTEXT_SHA3: ")phash=line.substr(16,line.len()-1).tolower();
            if(line=="END")ended=1;line="";
        end else if(b!=13)line={line,b};
    end
    initial begin
        $readmemh("03_vectors/channel/message_lengths.mem",lengths);ml=lengths[0];ol=lengths[1];
        $readmemh("03_vectors/channel/top_kem_ct.mem",kem_ct);
        $readmemh("03_vectors/channel/top_rx.mem",inc,0,ml+15);$readmemh("03_vectors/channel/top_tx.mem",outc,0,ol+15);
        $readmemh("03_vectors/channel/message_out.mem",msg,0,ol-1);$readmemh("03_vectors/channel/message_hash.mem",digest);
        repeat(8)@(negedge CLOCK_50);KEY[0]=1;wait(dut.reset_sync_n);wait(!dut.service_busy);
        payload="";for(j=0;j<64;j++)payload={payload,hx(j)};command("!","K",payload);
`ifdef CONTINUOUS_BANKED_BOARD_DEMO
        if(!LEDR[5])$fatal(1,"private key missing");
`else
        if(!LEDR[2])$fatal(1,"private key missing");
`endif
        payload="";for(j=0;j<1088;j++)payload={payload,hx(kem_ct[j])};command("!","D",payload);
        command("$","S","000102030405060708090a0b0c0d0e0f");
`ifdef CONTINUOUS_BANKED_BOARD_DEMO
        if(!LEDR[6])$fatal(1,"session LED missing");
`else
        if(!LEDR[4])$fatal(1,"session LED missing");
`endif
        payload="0000000000000000";for(j=0;j<ml+16;j++)payload={payload,hx(inc[j]^(j==ml?1:0))};
        command("$","U",payload,"a1");
`ifdef CONTINUOUS_BANKED_BOARD_DEMO
        if(phash!="-"||!LEDR[8])$fatal(1,"tamper not indicated");
`else
        if(phash!="-"||!LEDR[1])$fatal(1,"tamper not indicated");
`endif
        payload="0000000000000000";for(j=0;j<ml+16;j++)payload={payload,hx(inc[j])};command("$","U",payload);
`ifdef CONTINUOUS_BANKED_BOARD_DEMO
        if(phash!=$sformatf("%064x",digest[0])||!LEDR[7])$fatal(1,"decryption/LED");
`else
        if(phash!=$sformatf("%064x",digest[0])||!LEDR[5])$fatal(1,"decryption/LED");
`endif
        command("$","U",payload,"a2");
`ifdef CONTINUOUS_BANKED_BOARD_DEMO
        if(!LEDR[9])$fatal(1,"replay LED");
`else
        if(!LEDR[6])$fatal(1,"replay LED");
`endif
        payload="";expected="";for(j=0;j<ol;j++)payload={payload,hx(msg[j])};
        for(j=0;j<ol+16;j++)expected={expected,hx(outc[j])};command("$","P",payload);
`ifdef CONTINUOUS_BANKED_BOARD_DEMO
        if({data,tag}!=expected||!LEDR[7])$fatal(1,"serial ciphertext mismatch");
`else
        if({data,tag}!=expected||!LEDR[0])$fatal(1,"serial ciphertext mismatch");
`endif
        SW[0]=1;repeat(6)@(negedge dut.clk_sys);
`ifdef CONTINUOUS_BANKED_BOARD_DEMO
        if(!dut.sw_sync[0]||!LEDR[0])$fatal(1,"SW0 mode selection");
`else
        if(HEX0!==7'b1111001||HEX3!==7'b1111001)$fatal(1,"HEX packet counters");
`endif
        SW=0;command("!","Z","");
`ifdef CONTINUOUS_BANKED_BOARD_DEMO
        if(LEDR[5]||LEDR[6])$fatal(1,"zeroize key/session");
`else
        if(LEDR[2]||LEDR[4])$fatal(1,"zeroize key/session");
`endif
        // Wipe must reach the shared ML-KEM sponge as well as the public flags.
        // This catches an accidentally disconnected primitive zeroize port.
        if(dut.u_service.u_core.u_sponge.sponge_state!==1600'd0 ||
           dut.u_service.u_core.u_sponge.u_permutation.state!==1600'd0 ||
           dut.u_service.u_core.u_sponge.u_permutation.round_mid!==1600'd0 ||
           dut.u_service.u_core.u_sponge.result_valid!==1'b0)
            $fatal(1,"zeroize did not scrub ML-KEM Keccak state");
        command("$","P","00","a0");
        $display("CHANNEL_TOP: ALL TESTS PASS serial_pins MLKEM_KeyGen_Decaps HKDF AES_GCM tamper replay LED HEX zeroize");$finish;
    end
    initial begin #100000000;$fatal(1,"watchdog");end
endmodule
