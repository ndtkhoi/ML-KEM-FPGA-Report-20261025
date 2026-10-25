// HKDF-HMAC-SHA3-256 (RFC 5869). HMAC block size SHA3-256 = 136 byte.
// Salt = session_id (16 byte). Info = "MLKEM-UART-v1" || mode || epoch_be64.
// 72 byte: K_E2D[32] || K_D2E[32] || IVprefix_E2D[4] || IVprefix_D2E[4].
// Material/digest/IKM dung byte i o [8*i+:8]; session_id/epoch dung MSB truoc.
// hash_only dung cung sponge de bam plaintext cho bao cao, khong xuat plaintext.
module channel_kdf #(
    // Set only when the caller registers BOTH reset and operational clear
    // into zeroize. Standalone users retain direct synchronous reset.
    parameter bit RESET_VIA_ZEROIZE = 1'b0
) (
    input logic clk,rst_n,zeroize,start,hash_only,mode_1024,
    input logic [255:0] ikm,
    input logic [127:0] session_id,
    input logic [63:0] epoch,
    input logic load_we,
    input logic [7:0] load_address,load_data,
    input logic [8:0] hash_length,
    output logic [575:0] material,
    output logic [255:0] digest,
    output logic busy,done
);
    typedef enum logic [3:0] {IDLE,BUILD_PREP,BUILD,START_HASH,WAIT_HASH,READ_REQ,READ_CAP,RESULT,FINISH} state_t;
    state_t state;
    logic only_reg,mode_reg,outer;
    logic [2:0] step;
    logic [8:0] index,input_len;
    logic [255:0] prk,result_reg;
    logic [127:0] sid;
    logic [63:0] epoch_reg;
    logic [255:0] key_shift,body_shift;
    logic [183:0] info_shift;
    logic [7:0] build_byte;
    logic [7:0] build_byte_q;
    wire sponge_done;
    wire [7:0] sponge_out;

    // Pack vectors in the exact byte order consumed by the sponge, with the
    // next byte always at [7:0]. This replaces three variable part-select
    // barrel muxes on the old KDF critical path with fixed wiring + shifts.
    function automatic logic [127:0] pack_sid(input logic [127:0] value);
        integer j;
        begin
            for(j=0;j<16;j=j+1) pack_sid[8*j+:8]=value[127-8*j-:8];
        end
    endfunction
    function automatic logic [183:0] pack_info(
        input logic md,input logic [63:0] ep,input logic [2:0] st);
        logic [103:0] label;
        integer j;
        begin
            label="MLKEM-UART-v1";
            pack_info='0;
            for(j=0;j<13;j=j+1) pack_info[8*j+:8]=label[103-8*j-:8];
            pack_info[8*13+:8]=md?8'd4:8'd3;
            for(j=0;j<8;j=j+1) pack_info[8*(14+j)+:8]=ep[63-8*j-:8];
            pack_info[8*22+:8]={5'd0,st};
        end
    endfunction
    always_comb begin
        if(index<136)
            build_byte=key_shift[7:0]^(outer?8'h5c:8'h36);
        else if(outer || step==0 || ((step>1)&&(index<168)))
            build_byte=body_shift[7:0];
        else
            build_byte=info_shift[7:0];
    end
    keccak_sponge #(.MAX_INPUT_BYTES(256),.MAX_OUTPUT_BYTES(32),.INPUT_ADDR_W(8),.OUTPUT_ADDR_W(5),.PERM_THREE_PHASE_ROUND(1'b1),.REGISTERED_INPUT_WRITE(1'b1),.REGISTERED_INTERNAL_VISIBILITY(1'b1)) u_hash(
        // clear_kdf_q formerly drove 5383 asynchronous reset loads through
        // rst_n && !zeroize (negative recovery at 150 MHz). Keep the global
        // reset separate; the registered operational clear uses synchronous D.
        // In the session, clear_kdf_q already carries reset. Avoid rebuilding
        // rst_n AND !zeroize here: the old shared gate drove 853 loads and
        // was on the measured -0.430 ns setup path. No operational clear
        // stage is added; the registered token directly feeds the child.
        .clk(clk),.rst_n(RESET_VIA_ZEROIZE ? 1'b1 : rst_n),
        .zeroize(zeroize),.start(state==START_HASH),.mode(2'd0),
        .input_length(input_len),.output_length(6'd32),
        .input_we((state==BUILD)||(state==IDLE&&load_we)),
        .input_address((state==BUILD)?index[7:0]:load_address),
        .input_data((state==BUILD)?build_byte_q:load_data),
        .output_address(index[4:0]),.output_data(sponge_out),.busy(),.done(sponge_done),
        .cycle_count(),.debug_state());
    always_ff @(posedge clk) begin
        if((!RESET_VIA_ZEROIZE && !rst_n) || zeroize)begin
            state<=IDLE;busy<=0;done<=0;material<=0;digest<=0;index<=0;
            only_reg<=0;mode_reg<=0;outer<=0;step<=0;input_len<=0;
            build_byte_q<=0;key_shift<=0;body_shift<=0;info_shift<=0;
            prk<=0;result_reg<=0;sid<=0;epoch_reg<=0;
        end else begin
            done<=0;
            case(state)
                IDLE:if(start)begin
                    only_reg<=hash_only;mode_reg<=mode_1024;sid<=session_id;epoch_reg<=epoch;
                    busy<=1;digest<=0;material<=0;outer<=0;step<=0;index<=0;
                    key_shift<={128'd0,pack_sid(session_id)};
                    body_shift<=ikm;
                    info_shift<=pack_info(mode_1024,epoch,3'd0);
                    input_len<=hash_only?hash_length:9'd168;
                    state<=hash_only?START_HASH:BUILD_PREP;
                end
                BUILD_PREP:begin build_byte_q<=build_byte;state<=BUILD;end
                BUILD:begin
                    build_byte_q<=0;
                    if(index<136) key_shift<={8'd0,key_shift[255:8]};
                    else if(outer || step==0 || ((step>1)&&(index<168)))
                        body_shift<={8'd0,body_shift[255:8]};
                    else info_shift<={8'd0,info_shift[183:8]};
                    if(index+1'b1==input_len)begin index<=0;state<=START_HASH;end
                    else begin index<=index+1'b1;state<=BUILD_PREP;end
                end
                START_HASH:state<=WAIT_HASH;
                WAIT_HASH:if(sponge_done)begin index<=0;state<=READ_REQ;end
                READ_REQ:state<=READ_CAP;
                READ_CAP:begin
                    result_reg<={sponge_out,result_reg[255:8]};
                    if(index==31)state<=RESULT;else begin index<=index+1'b1;state<=READ_REQ;end
                end
                RESULT:begin
                    index<=0;
                    if(only_reg)begin digest<=result_reg;state<=FINISH;end
                    else if(!outer)begin
                        outer<=1;input_len<=168;
                        key_shift<=(step==0)?{128'd0,pack_sid(sid)}:prk;
                        body_shift<=result_reg;info_shift<=0;state<=BUILD_PREP;
                    end
                    else begin
                        outer<=0;
                        if(step==0)begin
                            prk<=result_reg;step<=1;input_len<=159;
                            key_shift<=result_reg;body_shift<=0;
                            info_shift<=pack_info(mode_reg,epoch_reg,3'd1);state<=BUILD_PREP;
                        end
                        else begin
                            if(step==1)material[255:0]<=result_reg;
                            if(step==2)material[511:256]<=result_reg;
                            if(step==3)material[575:512]<=result_reg[63:0];
                            if(step==3)state<=FINISH;
                            else begin
                                step<=step+1'b1;input_len<=191;
                                key_shift<=prk;body_shift<=result_reg;
                                info_shift<=pack_info(mode_reg,epoch_reg,step+1'b1);
                                state<=BUILD_PREP;
                            end
                        end
                    end
                end
                FINISH:begin
                    busy<=0;done<=1;state<=IDLE;prk<=0;result_reg<=0;
                    key_shift<=0;body_shift<=0;info_shift<=0;
                end
                default:state<=IDLE;
            endcase
        end
    end
endmodule
