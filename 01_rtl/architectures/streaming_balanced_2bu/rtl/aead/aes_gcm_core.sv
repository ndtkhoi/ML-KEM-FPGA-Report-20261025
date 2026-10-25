// AES-256-GCM: IV 96 bit, tag 128 bit, AAD <=32 byte, payload <=256 byte.
// Byte 0 cua cac vector nam o MSB. Doc plaintext chi duoc mo SAU khi tag dung.
module aes_gcm_core (
    input logic clk,rst_n,zeroize,start,decrypt,
    input logic [255:0] key,
    input logic [95:0] iv,
    input logic [127:0] tag_in,
    input logic [8:0] data_length,
    input logic [5:0] aad_length,
    input logic load_we,load_aad,
    input logic [7:0] load_address,load_data,
    input logic [7:0] read_address,
    output logic [7:0] read_data,
    output logic [127:0] tag_out,
    output logic busy,done,auth_ok,
    output logic [31:0] cycles
);
    typedef enum logic [4:0] {IDLE,H_START,H_WAIT,M_START,M_WAIT,AAD_INIT,AAD_BUILD,
        MUL_START,MUL_WAIT,DATA_INIT,D_START,D_WAIT,D_BUILD,LENGTH_HASH,TAG_CHECK,WIPE,FINISH,
        AAD_READ,D_READ} state_t;
    state_t state,after_mul;
    (* ramstyle = "M10K" *) logic [7:0] input_mem[0:255],output_mem[0:255],aad_mem[0:31];
    logic [7:0] input_q,aad_q,output_q;
    logic input_we,output_we,read_permitted;
    logic [7:0] input_write_address,output_write_address;
    logic [7:0] input_write_data,output_write_data;
    logic [255:0] key_reg;
    logic [127:0] counter_reg,mask_reg,h_reg,acc,block_reg,stream_reg,tag_reg;
    logic dec_reg,result_valid;
    logic [8:0] length_reg,offset;
    logic [5:0] aad_len;
    logic [4:0] bi;
    logic [8:0] data_pos_q;
    logic data_valid_q;
    logic [7:0] wipe_index;
    // Local reset distribution for the wide GCM state.  In the 160 MHz
    // baseline fit, reset_sync_n -> counter_reg was the next failing family
    // after AES.  Only this boundary flop now loads the global reset route;
    // Quartus can keep its bounded-fanout copies next to the GCM registers.
`ifdef ITERATIVE_BASELINE_TIMING_FIX
    (* maxfan = 32, preserve, dont_merge *) logic gcm_rst_n_q;
    wire gcm_reset_n = gcm_rst_n_q;
`else
    wire gcm_reset_n = rst_n;
`endif
    wire aes_start=(state==H_START || state==M_START || state==D_START);
    wire [127:0] aes_input=(state==H_START)?128'd0:counter_reg;
    wire [127:0] aes_output,mul_output;
    wire aes_done,mul_done;
    wire [8:0] pos=offset+{4'd0,bi};
    wire [7:0] in_byte=data_valid_q?input_q:8'd0;
    wire [7:0] crypt_byte=in_byte^stream_reg[127:120];
    wire internal_clear=zeroize || state==FINISH;

`ifdef ITERATIVE_BASELINE_TIMING_FIX
    always_ff @(posedge clk) begin
        if(!rst_n) gcm_rst_n_q<=1'b0;
        else       gcm_rst_n_q<=1'b1;
    end
`endif

    aes256_block u_aes(.clk(clk),.rst_n(rst_n),.zeroize(internal_clear),.start(aes_start),
        .key(key_reg),.block_in(aes_input),.block_out(aes_output),.busy(),.done(aes_done));
    ghash_mul u_ghash(.clk(clk),.rst_n(rst_n),.zeroize(internal_clear),.start(state==MUL_START),
        .x(acc^block_reg),.h(h_reg),.result(mul_output),.busy(),.done(mul_done));
    // Moi bo dem chi co MOT cong ghi: mux dia chi/data truoc RAM.
    // Nhanh WIPE van xoa du 256 byte; tag sai khong bao gio mo cong doc.
    always_comb begin
        input_we = 1'b0; input_write_address = load_address; input_write_data = load_data;
        output_we = 1'b0; output_write_address = data_pos_q[7:0]; output_write_data = crypt_byte;
        if (!busy && !zeroize && load_we && !load_aad) input_we = 1'b1;
        if (state == D_BUILD && data_valid_q && !zeroize) output_we = 1'b1;
        if (state == WIPE) begin
            input_we = 1'b1; input_write_address = wipe_index; input_write_data = 8'd0;
            output_we = !auth_ok; output_write_address = wipe_index; output_write_data = 8'd0;
        end
    end

    // Cat duong RAM input -> XOR -> RAM output bang cong doc dong bo.
    // Tach du lieu RAM va co cho phep doc, tranh logic reset/clear tren RAM.
    assign read_data = (read_permitted && result_valid && !busy && !start && !zeroize && rst_n)
        ? output_q : 8'd0;
    always_ff @(posedge clk) begin
        input_q <= input_mem[pos[7:0]];
        aad_q <= aad_mem[pos[4:0]];
        output_q <= output_mem[read_address];
        if(!gcm_reset_n || zeroize) begin
            data_pos_q<=0;
            data_valid_q<=0;
        end else if(state==D_READ) begin
            data_pos_q<=pos;
            data_valid_q<=pos<length_reg;
        end
        read_permitted <= result_valid && !busy && !start && !zeroize && rst_n &&
                          {1'b0,read_address}<length_reg;
        if (input_we) input_mem[input_write_address] <= input_write_data;
        if (output_we) output_mem[output_write_address] <= output_write_data;
        if (!busy && !zeroize && load_we && load_aad && load_address < 32)
            aad_mem[load_address[4:0]] <= load_data;
    end
    always_ff @(posedge clk) begin
        if(!gcm_reset_n) begin
            state<=IDLE;after_mul<=IDLE;busy<=0;done<=0;auth_ok<=0;result_valid<=0;
            key_reg<=0;counter_reg<=0;mask_reg<=0;h_reg<=0;acc<=0;block_reg<=0;
            stream_reg<=0;tag_reg<=0;tag_out<=0;dec_reg<=0;length_reg<=0;
            aad_len<=0;offset<=0;bi<=0;wipe_index<=0;cycles<=0;
`ifdef ITERATIVE_BASELINE_TIMING_FIX
            // Preserve the original interface contract at reset release: a
            // one-cycle start pulse is accepted while the local reset token
            // changes to the running state.
            if(rst_n && start) begin
                key_reg<=key;counter_reg<={iv,32'd1};tag_reg<=tag_in;
                dec_reg<=decrypt;length_reg<=data_length;aad_len<=aad_length;
                busy<=1;auth_ok<=0;result_valid<=0;tag_out<=0;cycles<=0;
                acc<=0;offset<=0;bi<=0;wipe_index<=0;
                if(data_length>256 || aad_length>32) state<=WIPE;
                else state<=H_START;
            end
`endif
        end else if(zeroize) begin
            state<=WIPE;busy<=1;done<=0;auth_ok<=0;result_valid<=0;wipe_index<=0;
            key_reg<=0;counter_reg<=0;mask_reg<=0;h_reg<=0;acc<=0;block_reg<=0;
            stream_reg<=0;tag_reg<=0;tag_out<=0;length_reg<=0;cycles<=0;
        end else begin
            done<=0;
            if(busy) cycles<=cycles+1'b1;
            case(state)
                IDLE: if(start) begin
                    key_reg<=key;counter_reg<={iv,32'd1};tag_reg<=tag_in;
                    dec_reg<=decrypt;length_reg<=data_length;aad_len<=aad_length;
                    busy<=1;auth_ok<=0;result_valid<=0;tag_out<=0;cycles<=0;
                    acc<=0;offset<=0;bi<=0;wipe_index<=0;
                    if(data_length>256 || aad_length>32) state<=WIPE; else state<=H_START;
                end
                H_START:state<=H_WAIT;
                H_WAIT:if(aes_done)begin h_reg<=aes_output;state<=M_START;end
                M_START:state<=M_WAIT;
                M_WAIT:if(aes_done)begin mask_reg<=aes_output;offset<=0;state<=AAD_INIT;end
                AAD_INIT:begin
                    bi<=0;block_reg<=0;
                    if(offset>=aad_len)begin offset<=0;state<=DATA_INIT;end else state<=AAD_READ;
                end
                AAD_READ:state<=AAD_BUILD;
                AAD_BUILD:begin
                    block_reg<={block_reg[119:0],((pos<aad_len)?aad_q:8'd0)};
                    if(bi==15)begin offset<=offset+9'd16;after_mul<=AAD_INIT;state<=MUL_START;end
                    else begin bi<=bi+1'b1;state<=AAD_READ;end
                end
                MUL_START:state<=MUL_WAIT;
                MUL_WAIT:if(mul_done)begin acc<=mul_output;state<=after_mul;end
                DATA_INIT:begin
                    if(offset>=length_reg)state<=LENGTH_HASH;
                    else begin counter_reg[31:0]<=counter_reg[31:0]+1'b1;state<=D_START;end
                end
                D_START:state<=D_WAIT;
                D_WAIT:if(aes_done)begin stream_reg<=aes_output;bi<=0;block_reg<=0;state<=D_READ;end
                D_READ:state<=D_BUILD;
                D_BUILD:begin
                    block_reg<={block_reg[119:0],(data_valid_q?(dec_reg?in_byte:crypt_byte):8'd0)};
                    stream_reg<={stream_reg[119:0],8'd0};
                    if(bi==15)begin offset<=offset+9'd16;after_mul<=DATA_INIT;state<=MUL_START;end
                    else begin bi<=bi+1'b1;state<=D_READ;end
                end
                LENGTH_HASH:begin
                    block_reg<={55'd0,aad_len,3'd0,52'd0,length_reg,3'd0};
                    after_mul<=TAG_CHECK;state<=MUL_START;
                end
                TAG_CHECK:begin
                    // So sanh toan bo tag, khong dung tai byte sai dau tien.
                    auth_ok<=!dec_reg || ((acc^mask_reg)==tag_reg);
                    tag_out<=dec_reg?128'd0:(acc^mask_reg);wipe_index<=0;state<=WIPE;
                end
                WIPE:if(wipe_index==255)state<=FINISH;else wipe_index<=wipe_index+1'b1;
                FINISH:begin
                    key_reg<=0;h_reg<=0;mask_reg<=0;stream_reg<=0;acc<=0;block_reg<=0;tag_reg<=0;
                    busy<=0;done<=1;result_valid<=auth_ok;state<=IDLE;
                end
                default:state<=IDLE;
            endcase
        end
    end
endmodule
