`timescale 1ns/1ps
module tb_channel_record;
    logic clk=0;always #5 clk=~clk;
    logic rst_n=0,rx_valid=0,rx_error=0,ready=1,kclear=0,kvalid=0,mode=0,role=0;
    logic [7:0] rx_data,tx_data;logic [255:0] secret;
    wire tx_valid,busy,active,opdone,pass,rm;
    wire [7:0] error;wire [1:0] op;wire [8:0] result_length;
    wire [31:0] txc,rxc,afc,rpc;
    channel_record_uart #(.RX_TIMEOUT_CYCLES(100))dut(.clk(clk),.rst_n(rst_n),.rx_valid(rx_valid),.rx_error(rx_error),.rx_data(rx_data),
        .tx_valid(tx_valid),.tx_data(tx_data),.tx_ready(ready),.kem_clear(kclear),.kem_valid(kvalid),.kem_mode(mode),.kem_encaps(role),.kem_secret(secret),
        .service_busy(busy),.active(active),.op_done(opdone),.op_pass(pass),.last_error(error),.last_op(op),.last_mode(rm),
        .result_length(result_length),.tx_count(txc),.rx_count(rxc),.auth_fail_count(afc),.replay_count(rpc));
    string line="",err="",data="",tag="",hash="",epoch_text="",payload,txexpected;
    bit ended=0;integer i,j,c,ml,ol,boundary_case,boundary_len,tick=0;
    logic [7:0] msg[0:255],inp[0:271],outp[0:271];logic [8:0] lengths[0:1];logic [255:0] expected_hash[0:0];
    logic [255:0] boundary_hash[0:1];
    function automatic byte hc(input logic [3:0] n);hc=n<10?8'h30+n:8'h61+n-10;endfunction
    function automatic string hx(input byte b);hx={hc(b[7:4]),hc(b[3:0])};endfunction
    function automatic logic [31:0] cb(input logic [31:0] a,input byte b);
        logic [31:0] v;integer n;begin v=a^b;for(n=0;n<8;n++)v=v[0]?((v>>1)^32'hedb88320):(v>>1);cb=v;end
    endfunction
    always @(negedge clk)begin tick++;ready=(tick%7!=0);end
    always @(posedge clk)if(tx_valid&&ready)begin
        if(tx_data==10)begin
            if(line.len()>=7&&line.substr(0,6)=="ERROR: ")err=line.substr(7,line.len()-1).tolower();
            if(line.len()>=10&&line.substr(0,9)=="DATA_HEX: ")data=line.substr(10,line.len()-1).tolower();
            if(line.len()>=5&&line.substr(0,4)=="TAG: ")tag=line.substr(5,line.len()-1).tolower();
            if(line.len()>=16&&line.substr(0,15)=="PLAINTEXT_SHA3: ")hash=line.substr(16,line.len()-1).tolower();
            if(line.len()>=7&&line.substr(0,6)=="EPOCH: ")epoch_text=line.substr(7,line.len()-1).tolower();
            if(line=="END")ended=1;
            line="";
        end else if(tx_data!=13)line={line,tx_data};
    end
    task automatic put(input byte b);begin @(negedge clk);rx_valid=1;rx_data=b;@(negedge clk);rx_valid=0;@(negedge clk);end endtask
    task automatic request(input string opcode,input string p,input string expected_error,input bit badcrc=0);
        string body,frame;logic [31:0] crc;integer n,limit;
        begin
            wait(!busy);ended=0;err="";data="";tag="";hash="";
            body={opcode,mode?"1":"7","0",$sformatf("%04x",p.len()/2),p};crc=32'hffffffff;
            for(n=0;n<body.len();n++)crc=cb(crc,body.getc(n));crc=~crc;if(badcrc)crc=crc^1;
            frame={"$",body,$sformatf("%08x",crc),"\n"};for(n=0;n<frame.len();n++)put(frame.getc(n));
            limit=0;while(!ended&&limit<100000)begin @(negedge clk);limit++;end
            if(!ended||err!=expected_error)$fatal(1,"record op=%s err=%s expected=%s state=%0d",opcode,err,expected_error,dut.state);
        end
    endtask
    initial begin
        rx_data=0;secret=0;for(j=0;j<32;j++)secret[8*j+:8]=j;
        $readmemh("03_vectors/channel/message_lengths.mem",lengths);ml=lengths[0];ol=lengths[1];
        $readmemh("03_vectors/channel/message_out.mem",msg,0,ol-1);$readmemh("03_vectors/channel/message_hash.mem",expected_hash);
        $readmemh("03_vectors/channel/boundary_hash.mem",boundary_hash);
        for(c=0;c<4;c++)begin
            rst_n=0;repeat(3)@(negedge clk);mode=(c>=2);role=c%2;rst_n=1;wait(!busy);
            $readmemh($sformatf("03_vectors/channel/rx_%0d_%0d.mem",mode?1024:768,role),inp,0,ml+15);
            $readmemh($sformatf("03_vectors/channel/tx_%0d_%0d.mem",mode?1024:768,role),outp,0,ol+15);
            request("S","000102030405060708090a0b0c0d0e0f","a0");
            wait(!busy);@(negedge clk);kvalid=1;@(negedge clk);kvalid=0;
            request("S","000102030405060708090a0b0c0d0e0f","f1",1);if(active)$fatal(1,"CRC started session");
            request("S","000102030405060708090a0b0c0d0e0f","00");
            if(!active||epoch_text!="0000000000000001")$fatal(1,"session setup");
            payload="0000000000000000";for(j=0;j<ml+16;j++)payload={payload,hx(inp[j]^(j==0?1:0))};
            request("U",payload,"a1");if(hash!="-"||rxc!=0||afc!=1)$fatal(1,"tamper release");
            payload="0000000000000000";for(j=0;j<ml+16;j++)payload={payload,hx(inp[j])};
            request("U",payload,"00");if(hash!=$sformatf("%064x",expected_hash[0])||rxc!=1)$fatal(1,"plaintext hash %s",hash);
            request("U",payload,"a2");if(hash!="-"||rpc!=1||rxc!=1)$fatal(1,"replay accepted");
            payload="";for(j=0;j<ol;j++)payload={payload,hx(msg[j])};request("P",payload,"00");
            txexpected="";for(j=0;j<ol+16;j++)txexpected={txexpected,hx(outp[j])};
            if({data,tag}!=txexpected||txc!=1)$fatal(1,"outbound mismatch got=%s%s expected=%s",data,tag,txexpected);
            // Ca bien UART that: payload rong va du 256 byte, hai chieu, seq 1/2.
            for(boundary_case=0;boundary_case<2;boundary_case++)begin
                boundary_len=(boundary_case==0)?0:256;
                $readmemh($sformatf("03_vectors/channel/rx_boundary_%0d_%0d_%0d.mem",mode?1024:768,role,boundary_len),inp,0,boundary_len+15);
                $readmemh($sformatf("03_vectors/channel/tx_boundary_%0d_%0d_%0d.mem",mode?1024:768,role,boundary_len),outp,0,boundary_len+15);
                payload=$sformatf("%016x",64'd1+boundary_case);
                for(j=0;j<boundary_len+16;j++)payload={payload,hx(inp[j])};
                request("U",payload,"00");
                if(hash!=$sformatf("%064x",boundary_hash[boundary_case])||result_length!=boundary_len||rxc!=boundary_case+2)
                    $fatal(1,"boundary U length=%0d",boundary_len);
                payload="";for(j=0;j<boundary_len;j++)payload={payload,hx(j[7:0])};
                request("P",payload,"00");
                txexpected="";for(j=0;j<boundary_len;j++)txexpected={txexpected,hx(outp[j])};
                if(data!=((boundary_len==0)?"-":txexpected)||result_length!=boundary_len||txc!=boundary_case+2)
                    $fatal(1,"boundary P data length=%0d",boundary_len);
                txexpected="";for(j=0;j<16;j++)txexpected={txexpected,hx(outp[boundary_len+j])};
                if(tag!=txexpected)$fatal(1,"boundary P tag length=%0d",boundary_len);
            end
            // Khoi phuc vector dau de kiem tra epoch tren cung message, seq=0.
            $readmemh($sformatf("03_vectors/channel/tx_%0d_%0d.mem",mode?1024:768,role),outp,0,ol+15);
            payload="";for(j=0;j<ol;j++)payload={payload,hx(msg[j])};
            txexpected="";for(j=0;j<ol+16;j++)txexpected={txexpected,hx(outp[j])};
            request("S","000102030405060708090a0b0c0d0e0f","a0");
            // Gia lap mot lan ML-KEM moi: epoch khong duoc reset, key moi se khac.
            wait(!busy);@(negedge clk);kclear=1;@(negedge clk);kclear=0;repeat(300)@(negedge clk);
            request("P",payload,"a0");if(active)$fatal(1,"key clear failed");
            wait(!busy);@(negedge clk);kvalid=1;@(negedge clk);kvalid=0;
            request("S","000102030405060708090a0b0c0d0e0f","00");
            if(epoch_text!="0000000000000002")$fatal(1,"epoch reuse");
            request("P",payload,"00");
            if({data,tag}==txexpected)$fatal(1,"new epoch reused traffic keys/nonce");
            wait(!busy);force dut.u_session.tx_seq=64'hffffffff;
            request("P",payload,"a6");release dut.u_session.tx_seq;
            $display("CHANNEL_RECORD mode=%0d FPGA_encaps=%0d: PASS two_directions tamper replay epoch clear zero_max_payload",mode?1024:768,role);
        end
        $display("CHANNEL_RECORD: ALL TESTS PASS");$finish;
    end
    initial begin #30000000;$fatal(1,"watchdog");end
endmodule
