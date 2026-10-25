`timescale 1ns/1ps
module tb_mlkem_service_core;
    logic clk=0; always #5 clk=~clk;
    logic rst_n=0, start=0, zeroize=0, mode_1024=0;
    logic [1:0] operation=0, read_object=0, load_object=0;
    logic [255:0] seed_d=0, seed_z=0, message_m=0;
    logic [11:0] read_address=0;
    wire [7:0] read_data;
    logic load_begin=0, load_mode_1024=0, load_valid=0;
    logic [12:0] load_length=0;
    logic [7:0] load_data=0;
    wire load_ready, load_done, load_error, key_ready, key_mode_1024;
    wire busy, done, zeroize_done, pass, fail, secret_valid;
    wire [7:0] error_code;
    wire [31:0] cycle_count;
    wire [255:0] shared_secret_encaps, shared_secret_decaps, secret_fingerprint;
    logic [7:0] ek_a[0:1567], ek_b[0:1567], ct_a[0:1567], ct_b[0:1567];
    logic [7:0] ss_a[0:31], ss_b[0:31], ss_bad[0:31], fp_a[0:31], fp_b[0:31], fp_bad[0:31];
    integer eklen, ctlen, i, m, cycles_valid;
    string prefix;
    mlkem_service_core dut(.*, .stage());

    // Check each actual RAM write against the pre-optimization selection,
    // including all 256 bit positions and both Encaps/re-encryption paths.
    integer mu_enc_writes=0, mu_dec_writes=0;
    integer poly_add_writes=0, poly_sub_writes=0;
    logic expected_mu_bit;
    always @(posedge clk) begin
        if (rst_n && dut.state == dut.ENC_MU_DONE) begin
            expected_mu_bit=dut.re_encrypt
                ? dut.message_prime_reg[dut.coefficient_index]
                : dut.m_latched[dut.coefficient_index];
            if (dut.mu_shift_reg[0] !== expected_mu_bit || !dut.poly_we_b ||
                dut.poly_addr_b !== {dut.SLOT_MU,dut.coefficient_index} ||
                dut.poly_data_b !== (expected_mu_bit ? 12'd1665 : 12'd0))
                $fatal(1,"mu stream mismatch mode=%0d inverse_path=%0d index=%0d",
                    m,dut.re_encrypt,dut.coefficient_index);
            if(dut.re_encrypt) mu_dec_writes++;
            else mu_enc_writes++;
        end
    end

    // Guard the 150 MHz timing optimization: the M10K outputs are captured,
    // both arithmetic results are then registered, and G_POLY_WRITE selects
    // the correct registered value in the following cycle.
    logic [12:0] expected_poly_sum;
    logic [11:0] expected_poly_add, expected_poly_sub;
    logic [11:0] expected_poly_a, expected_poly_b;
    logic expected_poly_valid=0;
    always @(negedge clk) begin
        if (!rst_n) begin
            expected_poly_valid = 0;
        end else if (dut.state == dut.G_POLY_CAPTURE) begin
            expected_poly_a = dut.poly_q_a;
            expected_poly_b = dut.poly_q_b;
            expected_poly_sum = {1'b0,dut.poly_q_a} + {1'b0,dut.poly_q_b};
            expected_poly_add = (expected_poly_sum >= 13'd3329)
                ? expected_poly_sum - 13'd3329 : expected_poly_sum[11:0];
            expected_poly_sub = (dut.poly_q_a >= dut.poly_q_b)
                ? dut.poly_q_a - dut.poly_q_b
                : ({1'b0,dut.poly_q_a} + 13'd3329 - {1'b0,dut.poly_q_b});
            expected_poly_valid = 1;
        end else if (dut.state == dut.G_POLY_EXECUTE) begin
            if (!expected_poly_valid || dut.poly_operand_a !== expected_poly_a ||
                dut.poly_operand_b !== expected_poly_b)
                $fatal(1,"registered poly operand mismatch index=%0d a=%0d/%0d b=%0d/%0d",
                    dut.coefficient_index,dut.poly_operand_a,expected_poly_a,
                    dut.poly_operand_b,expected_poly_b);
`ifdef CONTINUOUS_BANKED_CYCLE_OPT
            if (!dut.poly_we_b ||
                dut.poly_addr_b !== {dut.poly_dest_slot,dut.coefficient_index} ||
                dut.poly_data_b !== (dut.poly_subtract ? expected_poly_sub : expected_poly_add))
                $fatal(1,"cycle-opt direct poly write mismatch index=%0d subtract=%0d",
                    dut.coefficient_index,dut.poly_subtract);
            if (dut.poly_subtract) poly_sub_writes++;
            else poly_add_writes++;
            expected_poly_valid = 0;
`endif
        end else if (dut.state == dut.G_POLY_WRITE) begin
`ifndef CONTINUOUS_BANKED_CYCLE_OPT
            if (!expected_poly_valid || dut.poly_add_q !== expected_poly_add ||
                dut.poly_sub_q !== expected_poly_sub)
                $fatal(1,"registered poly arithmetic mismatch index=%0d add=%0d/%0d sub=%0d/%0d",
                    dut.coefficient_index,
                    dut.poly_add_q,expected_poly_add,dut.poly_sub_q,expected_poly_sub);
            if (!dut.poly_we_b ||
                dut.poly_addr_b !== {dut.poly_dest_slot,dut.coefficient_index} ||
                dut.poly_data_b !== (dut.poly_subtract ? expected_poly_sub : expected_poly_add))
                $fatal(1,"registered poly write mismatch index=%0d subtract=%0d",
                    dut.coefficient_index,dut.poly_subtract);
            if (dut.poly_subtract) poly_sub_writes++;
            else poly_add_writes++;
            expected_poly_valid = 0;
`endif
        end
    end

    task automatic run_op(input integer op, input integer expected_error);
        integer timeout,ntt_ticks,mul_ticks,hash_ticks,transfer_ticks;
        integer hash_io_ticks,sample_io_ticks,poly_ticks,transform_ticks;
        integer codec_ticks,message_ticks,other_ticks;
        begin
            @(negedge clk); operation=op; start=1;
            @(negedge clk); start=0;
            // Dau vao duoc phep thay doi sau canh start; core phai da latch.
            seed_d=0; seed_z=0; message_m=0;
            timeout=0;ntt_ticks=0;mul_ticks=0;hash_ticks=0;transfer_ticks=0;
            hash_io_ticks=0;sample_io_ticks=0;poly_ticks=0;transform_ticks=0;
            codec_ticks=0;message_ticks=0;other_ticks=0;
            while (!done && timeout<2000000) begin
`ifdef CONTINUOUS_BANKED_BYTE_STREAM_OPT
                if ((dut.state == dut.G_HASH_LOAD_WRITE) &&
                    (^dut.hash_input_q === 1'bx))
                    $fatal(1,"byte-stream hash input X source=%0d index=%0d length=%0d",
                        dut.hash_source_reg,dut.op_index,dut.hash_input_length);
                if ((dut.state == dut.G_HASH_OUT_CAP) &&
                    (^dut.hash_output_q === 1'bx))
                    $fatal(1,"byte-stream hash output X dest=%0d index=%0d length=%0d",
                        dut.hash_dest_reg,dut.op_index,dut.hash_output_length);
`endif
                if(dut.ntt_busy) ntt_ticks++;
                if(dut.mul_busy) mul_ticks++;
                if(dut.sponge_busy) hash_ticks++;
                case(dut.state)
                    dut.G_NTT_IN_REQ,dut.G_NTT_IN_CAP,dut.G_NTT_OUT_REQ,dut.G_NTT_OUT_CAP,
                    dut.G_MUL_IN_REQ,dut.G_MUL_IN_CAP,dut.G_MUL_OUT_REQ,dut.G_MUL_OUT_CAP:
                        transfer_ticks++;
                    default: begin end
                endcase
                case(dut.state)
                    dut.G_HASH_LOAD_READ,dut.G_HASH_LOAD_CAPTURE,dut.G_HASH_LOAD_WRITE,
                    dut.G_HASH_START,dut.G_HASH_OUT_REQ,dut.G_HASH_OUT_PIPE,dut.G_HASH_OUT_CAP:
                        hash_io_ticks++;
                    dut.G_SAMPLE_START,dut.G_SAMPLE_OUT_REQ,dut.G_SAMPLE_OUT_CAP:
                        sample_io_ticks++;
                    dut.G_POLY_ZERO,dut.G_POLY_READ,dut.G_POLY_CAPTURE,
                    dut.G_POLY_EXECUTE,dut.G_POLY_WRITE:
                        poly_ticks++;
                    dut.G_TRANS_READ,dut.G_TRANS_INPUT_CAPTURE,dut.G_TRANS_CALCULATE,
                    dut.G_TRANS_WAIT,dut.G_TRANS_WRITE:
                        transform_ticks++;
                    dut.G_CODEC_ENC_IN_REQ,dut.G_CODEC_ENC_IN_CAP,dut.G_CODEC_ENC_START,
                    dut.G_CODEC_ENC_WAIT,dut.G_CODEC_ENC_OUT_REQ,dut.G_CODEC_ENC_OUT_CAP,
                    dut.G_CODEC_DEC_IN_REQ,dut.G_CODEC_DEC_IN_CAP,dut.G_CODEC_DEC_START,
                    dut.G_CODEC_DEC_WAIT,dut.G_CODEC_DEC_OUT_REQ,dut.G_CODEC_DEC_OUT_CAP,
                    dut.G_CODEC_DEC_OUT_CALCULATE,dut.G_CODEC_DEC_OUT_WAIT,
                    dut.G_CODEC_DEC_OUT_WRITE:
                        codec_ticks++;
                    dut.G_MESSAGE_READ,dut.G_MESSAGE_INPUT_CAPTURE,dut.G_MESSAGE_CALCULATE,
                    dut.G_MESSAGE_WAIT,dut.G_MESSAGE_WRITE:
                        message_ticks++;
                    default: other_ticks++;
                endcase
                @(negedge clk); timeout++;
            end
            if (!done || error_code!==expected_error || pass!==(expected_error==0))
                $fatal(1,"op=%0d timeout=%0d error=%h expected=%h",op,timeout,error_code,expected_error);
            if (dut.mu_shift_reg !== 256'd0) $fatal(1,"mu secret copy not cleared on completion");
            $display("SERVICE_OP mode=%0d op=%0d error=%h cycles=%0d",m,op,error_code,cycle_count);
            if(expected_error==0)
                $display("SERVICE_PROFILE mode=%0d op=%0d ntt_busy=%0d mul_busy=%0d sponge_busy=%0d poly_transfer=%0d",
                    m,op,ntt_ticks,mul_ticks,hash_ticks,transfer_ticks);
            if(expected_error==0)
                $display("SERVICE_PROFILE_DETAIL mode=%0d op=%0d hash_io=%0d sample_io=%0d poly=%0d transform=%0d codec=%0d message=%0d other=%0d",
                    m,op,hash_io_ticks,sample_io_ticks,poly_ticks,transform_ticks,
                    codec_ticks,message_ticks,other_ticks);
        end
    endtask
    task automatic upload(input integer obj, input integer which, input integer count);
        integer n;
        begin
            @(negedge clk); load_object=obj; load_length=count; load_mode_1024=mode_1024; load_begin=1;
            @(negedge clk); load_begin=0;
            if (load_error) $fatal(1,"unexpected load error");
            for(n=0;n<count;n++) begin
                if(!load_ready) $fatal(1,"load not ready %0d",n);
                load_valid=1;
                if(obj==0) load_data=(which==0)?ek_a[n]:ek_b[n];
                else load_data=(which==1)?ct_b[n]:ct_a[n];
                if(which==2 && n==0) load_data=ct_a[n]^1;
                @(negedge clk);
            end
            load_valid=0;
            if(!load_done) $fatal(1,"missing load done");
        end
    endtask
    task automatic check_output(input integer obj, input integer which, input integer count);
        integer n;
        logic [7:0] expected;
        begin
            for(n=0;n<count;n++) begin
                @(negedge clk); read_object=obj; read_address=n;
                @(negedge clk);
                expected=(obj==0)?((which==0)?ek_a[n]:ek_b[n]):((which==0)?ct_a[n]:ct_b[n]);
                if(read_data!==expected) $fatal(1,"byte mismatch obj=%0d idx=%0d got=%h exp=%h",obj,n,read_data,expected);
            end
        end
    endtask
    task automatic check_secret(input integer op, input integer which);
        integer n;
        logic [255:0] ss;
        logic [7:0] expected, fp;
        begin
            ss=(op==2)?shared_secret_encaps:shared_secret_decaps;
            if(!secret_valid) $fatal(1,"no secret valid");
            for(n=0;n<32;n++) begin
                expected=(which==0)?ss_a[n]:((which==1)?ss_b[n]:ss_bad[n]);
                fp=(which==0)?fp_a[n]:((which==1)?fp_b[n]:fp_bad[n]);
                if(ss[8*n+:8]!==expected || secret_fingerprint[8*n+:8]!==fp)
                    $fatal(1,"secret/digest mismatch byte=%0d got=%h exp=%h fp=%h expfp=%h",n,ss[8*n+:8],expected,secret_fingerprint[8*n+:8],fp);
            end
        end
    endtask
    initial begin
        repeat(3) @(negedge clk); rst_n=1;
        wait(!busy); @(negedge clk);
        for(m=768;m<=1024;m=m+256) begin
            mode_1024=(m==1024); eklen=mode_1024?1568:1184; ctlen=mode_1024?1568:1088;
            prefix=$sformatf("03_vectors/service/%0d",m);
            $readmemh({prefix,"_a_ek.mem"},ek_a,0,eklen-1);
            $readmemh({prefix,"_b_ek.mem"},ek_b,0,eklen-1);
            $readmemh({prefix,"_a_ct.mem"},ct_a,0,ctlen-1);
            $readmemh({prefix,"_b_ct.mem"},ct_b,0,ctlen-1);
            $readmemh({prefix,"_a_ss.mem"},ss_a); $readmemh({prefix,"_b_ss.mem"},ss_b);
            $readmemh({prefix,"_a_reject.mem"},ss_bad);
            $readmemh({prefix,"_a_fp.mem"},fp_a); $readmemh({prefix,"_b_fp.mem"},fp_b);
            $readmemh({prefix,"_a_reject_fp.mem"},fp_bad);
            run_op(2,'h11); run_op(3,'h12);
            // Encaps DUOC CHAY TRUOC KeyGen: EK do ben ngoai cung cap.
            for(i=0;i<32;i++) message_m[8*i+:8]=i+64+97;
            upload(0,1,eklen); run_op(2,0); check_secret(2,1); check_output(2,1,ctlen);
            if(key_ready) $fatal(1,"Encaps must not generate a private key");
            // KeyGen chi tao khoa, chua Encaps/Decaps.
            for(i=0;i<32;i++) begin seed_d[8*i+:8]=i; seed_z[8*i+:8]=i+32; end
            run_op(1,0); check_output(0,0,eklen);
`ifdef CONTINUOUS_BANKED_BYTE_STREAM_OPT
            for(i=0;i<eklen;i=i+1)
                if (dut.u_byte_store.memory[i] !==
                    dut.u_byte_store.memory[1600+(384*(mode_1024?4:3))+i])
                    $fatal(1,"byte-stream private EK copy mismatch index=%0d ek=%h dk=%h",
                        i,dut.u_byte_store.memory[i],
                        dut.u_byte_store.memory[1600+(384*(mode_1024?4:3))+i]);
`endif
            if(!key_ready || secret_valid || shared_secret_encaps!==0 || shared_secret_decaps!==0)
                $fatal(1,"KeyGen lifecycle");
            @(negedge clk); read_object=1; read_address=0;
            @(negedge clk); if(read_data!==0) $fatal(1,"private key exposed");
            mode_1024=!mode_1024;
            run_op(3,'h12);
            mode_1024=!mode_1024;
            run_op(3,'h13);
            // Decaps nhan CT tu oracle PC, KHONG can Encaps truoc do.
            seed_d=0; seed_z=0; message_m=0;
            upload(2,0,ctlen); run_op(3,0); check_secret(3,0); cycles_valid=cycle_count;
            // Encaps voi EK khac khong duoc pha key slot A.
            for(i=0;i<32;i++) message_m[8*i+:8]=i+64+97;
            upload(0,1,eklen); run_op(2,0); check_secret(2,1);
            upload(2,0,ctlen); run_op(3,0); check_secret(3,0);
            // Ciphertext sai van STATUS OK, khoa dung J(z||c), cung so chu ky.
            upload(2,2,ctlen); run_op(3,0); check_secret(3,2);
            if(cycle_count!=cycles_valid) $fatal(1,"decaps timing differs");
            // Phai reject he so 3329 thay vi ByteDecode roi modulo.
            ek_b[0]=8'h01; ek_b[1]=(ek_b[1]&8'hf0)|8'h0d;
            upload(0,1,eklen); run_op(2,'h22);
            if(secret_valid || secret_fingerprint!==0) $fatal(1,"stale secret on failure");
            @(negedge clk); load_object=0; load_mode_1024=mode_1024; load_length=eklen-1; load_begin=1;
            @(negedge clk); load_begin=0; if(!load_error) $fatal(1,"short EK accepted");
            @(negedge clk); load_length=eklen; load_begin=1;
            @(negedge clk); load_begin=0; load_valid=1; load_data=0;
            repeat(3) @(negedge clk);
            load_valid=0; run_op(2,'h10);
            @(negedge clk); zeroize=1;
            @(negedge clk); zeroize=0; wait(zeroize_done); @(negedge clk);
            if(key_ready || secret_valid || secret_fingerprint!==0 || dut.mu_shift_reg!==0) $fatal(1,"zeroize failed");
            $display("MLKEM_SERVICE_%0d: PASS independent_ops external_EK_CT reject_same_latency private_slot zeroize",m);
        end
        if(mu_enc_writes!=1024 || mu_dec_writes!=1536)
            $fatal(1,"missing mu write coverage enc=%0d dec=%0d",mu_enc_writes,mu_dec_writes);
        if(poly_add_writes==0 || poly_sub_writes==0)
            $fatal(1,"missing registered poly arithmetic coverage add=%0d sub=%0d",
                poly_add_writes,poly_sub_writes);
        $display("MU_STREAM: PASS enc_writes=%0d dec_writes=%0d all_256_positions both_modes secret_clear",mu_enc_writes,mu_dec_writes);
        $display("POLY_PIPELINE: PASS add_writes=%0d sub_writes=%0d operand_and_result_registers",poly_add_writes,poly_sub_writes);
        $display("MLKEM_SERVICE_CORE: ALL TESTS PASS"); $finish;
    end
endmodule
