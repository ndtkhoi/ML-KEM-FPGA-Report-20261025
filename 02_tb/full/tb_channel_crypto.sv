`timescale 1ns/1ps
module tb_channel_crypto;
    logic clk=0;always #5 clk=~clk;
    logic rst_n=0,clear=0,start=0,dec=0,we=0,la=0;
    logic [255:0] key;
    logic [95:0] iv;
    logic [127:0] tin,tout;
    logic [8:0] len;
    logic [5:0] alen;
    logic [7:0] wa,wd,ra,rd;
    wire busy,done,ok;
    wire [31:0] cycles;
    aes_gcm_core dut(.clk(clk),.rst_n(rst_n),.zeroize(clear),.start(start),.decrypt(dec),
        .key(key),.iv(iv),.tag_in(tin),.data_length(len),.aad_length(alen),
        .load_we(we),.load_aad(la),.load_address(wa),.load_data(wd),.read_address(ra),.read_data(rd),
        .tag_out(tout),.busy(busy),.done(done),.auth_ok(ok),.cycles(cycles));
    logic ks=0,ho=0,kw=0,mode=0;
    logic [7:0] ka,kd;
    logic [255:0] ikm;
    wire [575:0] km;
    wire [255:0] hash;
    wire kb,kdone;
    channel_kdf kdf(.clk(clk),.rst_n(rst_n),.zeroize(clear),.start(ks),.hash_only(ho),
        .mode_1024(mode),.ikm(ikm),.session_id(128'h000102030405060708090a0b0c0d0e0f),.epoch(64'd7),
        .load_we(kw),.load_address(ka),.load_data(kd),.hash_length(9'd256),
        .material(km),.digest(hash),.busy(kb),.done(kdone));
    logic ast=0;wire adone;wire [127:0] ao;
    aes256_block aes(.clk(clk),.rst_n(rst_n),.zeroize(clear),.start(ast),
        .key(256'h000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f),
        .block_in(128'h00112233445566778899aabbccddeeff),.block_out(ao),.busy(),.done(adone));
    logic [255:0] keys[0:9];logic [95:0] ivs[0:9];logic [127:0] tags[0:9];
    logic [8:0] lens[0:9];logic [5:0] alens[0:9];
    logic [7:0] input_v[0:2559],output_v[0:2559],aad_v[0:319];
    logic [575:0] kexpected[0:1];logic [255:0] hexpected[0:0];
    integer i,j,trial,t;
    task automatic run_gcm(input bit decrypting,input bit bad);
        begin
            @(negedge clk);dec=decrypting;tin=tags[i]^(bad?128'd1:128'd0);
            for(j=0;j<alens[i];j=j+1)begin we=1;la=1;wa=j;wd=aad_v[i*32+j];@(negedge clk);end
            for(j=0;j<lens[i];j=j+1)begin we=1;la=0;wa=j;wd=decrypting?output_v[i*256+j]:input_v[i*256+j];@(negedge clk);end
            we=0;start=1;@(negedge clk);start=0;t=0;
            while(!done && t<20000)begin @(negedge clk);t=t+1;if(busy && rd!==0)$fatal(1,"plaintext before auth");end
            if(!done || ok==bad)$fatal(1,"GCM status case=%0d dec=%0d bad=%0d",i,decrypting,bad);
            if(!decrypting && tout!==tags[i])$fatal(1,"tag case=%0d got=%h expected=%h",i,tout,tags[i]);
            for(j=0;j<lens[i];j=j+1)begin
                ra=j;repeat(2)@(negedge clk);
                if(rd!==(bad?8'd0:(decrypting?input_v[i*256+j]:output_v[i*256+j])))$fatal(1,"payload mismatch case=%0d byte=%0d",i,j);
            end
        end
    endtask
    initial begin
        key=0;iv=0;tin=0;len=0;alen=0;wa=0;wd=0;ra=0;ka=0;kd=0;ikm=0;
        $readmemh("03_vectors/channel/key.mem",keys);$readmemh("03_vectors/channel/iv.mem",ivs);
        $readmemh("03_vectors/channel/tag.mem",tags);$readmemh("03_vectors/channel/len.mem",lens);
        $readmemh("03_vectors/channel/alen.mem",alens);$readmemh("03_vectors/channel/input.mem",input_v);
        $readmemh("03_vectors/channel/output.mem",output_v);$readmemh("03_vectors/channel/aad.mem",aad_v);
        $readmemh("03_vectors/channel/kdf.mem",kexpected);$readmemh("03_vectors/channel/hash.mem",hexpected);
        repeat(3)@(negedge clk);rst_n=1;ast=1;@(negedge clk);ast=0;wait(adone);@(negedge clk);
        if(ao!==128'h8ea2b7ca516745bfeafc49904b496089)$fatal(1,"AES256 FIPS197 KAT %h",ao);
        $display("AES256_FIPS197: PASS");
        for(i=0;i<10;i=i+1)begin
            key=keys[i];iv=ivs[i];len=lens[i];alen=alens[i];
            run_gcm(0,0);run_gcm(1,0);run_gcm(1,1);
            $display("AES256_GCM case=%0d bytes=%0d aad=%0d: PASS encrypt decrypt tamper",i,len,alen);
        end
        for(j=0;j<32;j=j+1)ikm[8*j+:8]=j;
        for(i=0;i<2;i=i+1)begin
            mode=i;ks=1;@(negedge clk);ks=0;wait(kdone);@(negedge clk);
            if(km!==kexpected[i])$fatal(1,"HKDF mode=%0d got=%h expected=%h",i,km,kexpected[i]);
        end
        ho=1;for(j=0;j<256;j=j+1)begin kw=1;ka=j;kd=j;@(negedge clk);end
        kw=0;ks=1;@(negedge clk);ks=0;wait(kdone);@(negedge clk);
        if(hash!==hexpected[0])$fatal(1,"plaintext digest");
        clear=1;@(negedge clk);clear=0;repeat(300)@(negedge clk);
        if(km!==0 || hash!==0 || rd!==0)$fatal(1,"zeroize");
        $display("CHANNEL_CRYPTO: ALL TESTS PASS");$finish;
    end
    initial begin #10000000;$fatal(1,"watchdog");end
endmodule
