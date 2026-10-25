// ML-KEM-768/1024: KeyGen, Encaps va Decaps duoc goi doc lap.
// Tach tu datapath da kiem thu cua mlkem_full_core; khong sua ban demo cu.
// operation: 1=KeyGen, 2=Encaps, 3=Decaps. Khong tu chay buoc tiep theo.
// Mot key slot noi bo, chi KeyGen/zeroize thay doi khoa bi mat.
// Nap theo luong byte EK (object=0) hoac CT (object=2); cam doc/ghi DK.
// Decaps luon tra khoa (ke ca implicit rejection), khong xuat co hop le CT.
//
// Moi start chi goi MOT thuat toan; implicit rejection la noi bo Decaps.
//
// Kien truc xu ly tuan tu, tai su dung mot sponge, mot NTT/INTT va mot
// MultiplyNTTs de phu hop tai nguyen Cyclone V. Dau vao d, z va m la 32-byte
// vector; bit [8*i +: 8] chua byte thu i.
module mlkem_service_core (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         start,
    input  logic         zeroize,
    input  logic         mode_1024,
    input  logic [1:0]   operation,
    input  logic         load_begin,
    input  logic [1:0]   load_object,
    input  logic         load_mode_1024,
    input  logic [12:0]  load_length,
    input  logic         load_valid,
    input  logic [7:0]   load_data,
    output logic         load_ready,
    output logic         load_done,
    output logic         load_error,
    output logic         key_ready,
    output logic         key_mode_1024,
    output logic [255:0] secret_fingerprint,
    output logic         secret_valid,
    input  logic [255:0] seed_d,
    input  logic [255:0] seed_z,
    input  logic [255:0] message_m,

    input  logic [1:0]   read_object,
    input  logic [11:0]  read_address,
    output logic [7:0]   read_data,

    output logic [255:0] shared_secret_encaps,
    output logic [255:0] shared_secret_decaps,
    output logic         busy,
    output logic         done,
    output logic         zeroize_done,
    output logic         pass,
    output logic         fail,
    output logic [3:0]   stage,
    output logic [31:0]  cycle_count,
    output logic [7:0]   error_code
);

    localparam logic [12:0] EK_BASE  = 13'd0;
    localparam logic [12:0] DK_BASE  = 13'd1600;
    localparam logic [12:0] CT_BASE  = 13'd4800;
    localparam logic [12:0] CTP_BASE = 13'd6400;

    // Predecoded codec addresses for the two supported parameter sets.
    // Avoid variable products on the address control path.
    function automatic logic [12:0] u_codec_address(
        input logic prime, input logic mode1024, input logic [1:0] poly_index);
        case ({prime,mode1024,poly_index})
            4'd0: u_codec_address = 13'd4800;
            4'd1: u_codec_address = 13'd5120;
            4'd2: u_codec_address = 13'd5440;
            4'd3: u_codec_address = 13'd5760;
            4'd4: u_codec_address = 13'd4800;
            4'd5: u_codec_address = 13'd5152;
            4'd6: u_codec_address = 13'd5504;
            4'd7: u_codec_address = 13'd5856;
            4'd8: u_codec_address = 13'd6400;
            4'd9: u_codec_address = 13'd6720;
            4'd10: u_codec_address = 13'd7040;
            4'd11: u_codec_address = 13'd7360;
            4'd12: u_codec_address = 13'd6400;
            4'd13: u_codec_address = 13'd6752;
            4'd14: u_codec_address = 13'd7104;
            4'd15: u_codec_address = 13'd7456;
            default: u_codec_address = CT_BASE;
        endcase
    endfunction

    localparam logic [4:0] SLOT_S    = 5'd0;
    localparam logic [4:0] SLOT_T    = 5'd4;
    localparam logic [4:0] SLOT_Y    = 5'd8;
    localparam logic [4:0] SLOT_U    = 5'd12;
    localparam logic [4:0] SLOT_TEMP = 5'd16;
    localparam logic [4:0] SLOT_ACC  = 5'd17;
    localparam logic [4:0] SLOT_PROD = 5'd18;
    localparam logic [4:0] SLOT_V    = 5'd19;
    localparam logic [4:0] SLOT_E    = 5'd20;
    localparam logic [4:0] SLOT_MU   = 5'd21;
    localparam logic [4:0] SLOT_W    = 5'd22;
    localparam logic [4:0] SLOT_PACK = 5'd23;

    localparam logic [3:0] HASH_D_K       = 4'd0;
    localparam logic [3:0] HASH_SIGMA_N   = 4'd1;
    localparam logic [3:0] HASH_RHO_I_J   = 4'd2;
    localparam logic [3:0] HASH_EK        = 4'd3;
    localparam logic [3:0] HASH_M_EKH     = 4'd4;
    localparam logic [3:0] HASH_Z_CT      = 4'd5;

    localparam logic [3:0] DEST_RHO_SIGMA = 4'd0;
    localparam logic [3:0] DEST_SAMPLER   = 4'd1;
    localparam logic [3:0] DEST_EK_HASH   = 4'd2;
    localparam logic [3:0] DEST_ENCAP_K_R = 4'd3;
    localparam logic [3:0] DEST_DECAP_K_R = 4'd4;
    localparam logic [3:0] DEST_FALLBACK  = 4'd5;

    typedef enum logic [7:0] {
        S_IDLE,
        S_DISPATCH,
        P_RESTORE_READ, P_RESTORE_WRITE,
        P_CHECK_READ, P_CHECK_CAP,
        P_RHO_READ, P_RHO_CAP,
        P_Z_READ, P_Z_CAP,
        P_T_BEGIN, P_T_DONE,
        P_S_BEGIN, P_S_DONE,
        P_HASH_BEGIN, P_HASH_DONE,
        P_HASH_CHECK_READ, P_HASH_CHECK_CAP, P_HASH_CHECK_DONE,
        S_FINGERPRINT,

        G_HASH_LOAD_READ,
        G_HASH_LOAD_CAPTURE,
        G_HASH_LOAD_WRITE,
        G_HASH_START,
        G_HASH_WAIT,
        G_HASH_OUT_REQ,
        G_HASH_OUT_PIPE,
        G_HASH_OUT_CAP,
        G_SAMPLE_START,
        G_SAMPLE_WAIT,
        G_SAMPLE_OUT_REQ,
        G_SAMPLE_OUT_CAP,
        G_NTT_IN_REQ,
        G_NTT_IN_CAP,
        G_NTT_START,
        G_NTT_WAIT,
        G_NTT_OUT_REQ,
        G_NTT_OUT_CAP,
        G_MUL_IN_REQ,
        G_MUL_IN_CAP,
        G_MUL_START,
        G_MUL_WAIT,
        G_MUL_OUT_REQ,
        G_MUL_OUT_CAP,
        G_POLY_ZERO,
        G_POLY_READ,
        G_POLY_CAPTURE,
        G_POLY_EXECUTE,
        G_POLY_WRITE,
        G_TRANS_READ,
        G_TRANS_INPUT_CAPTURE,
        G_TRANS_CALCULATE,
        G_TRANS_WAIT,
        G_TRANS_WRITE,
        G_CODEC_ENC_IN_REQ,
        G_CODEC_ENC_IN_CAP,
        G_CODEC_ENC_START,
        G_CODEC_ENC_WAIT,
        G_CODEC_ENC_OUT_REQ,
        G_CODEC_ENC_OUT_CAP,
        G_CODEC_DEC_IN_REQ,
        G_CODEC_DEC_IN_CAP,
        G_CODEC_DEC_START,
        G_CODEC_DEC_WAIT,
        G_CODEC_DEC_OUT_REQ,
        G_CODEC_DEC_OUT_CAP,
        G_CODEC_DEC_OUT_CALCULATE,
        G_CODEC_DEC_OUT_WAIT,
        G_CODEC_DEC_OUT_WRITE,
        G_MESSAGE_READ,
        G_MESSAGE_INPUT_CAPTURE,
        G_MESSAGE_CALCULATE,
        G_MESSAGE_WAIT,
        G_MESSAGE_WRITE,

        KG_HASH_G,
        KG_G_DONE,
        KG_S_HASH_DONE,
        KG_S_SAMPLE_DONE,
        KG_S_NTT_DONE,
        KG_ROW_BEGIN,
        KG_MATRIX_HASH_DONE,
        KG_MATRIX_SAMPLE_DONE,
        KG_MATRIX_MUL_DONE,
        KG_MATRIX_ADD_DONE,
        KG_E_HASH_DONE,
        KG_E_SAMPLE_DONE,
        KG_E_NTT_DONE,
        KG_T_ADD_DONE,
        KG_PACK_T_BEGIN,
        KG_PACK_T_DONE,
        KG_RHO_COPY,
        KG_PACK_S_BEGIN,
        KG_PACK_S_DONE,
        KG_COPY_EK_READ,
        KG_COPY_EK_WRITE,
        KG_HASH_EK_DONE,
        KG_COPY_HASH,
        KG_COPY_Z,

        ENC_G_BEGIN,
        ENC_G_DONE,
        ENC_Y_HASH_DONE,
        ENC_Y_SAMPLE_DONE,
        ENC_Y_NTT_DONE,
        ENC_U_BEGIN,
        ENC_U_ZERO_DONE,
        ENC_U_MATRIX_HASH_DONE,
        ENC_U_MATRIX_SAMPLE_DONE,
        ENC_U_MATRIX_MUL_DONE,
        ENC_U_MATRIX_ADD_DONE,
        ENC_U_INTT_DONE,
        ENC_E1_HASH_DONE,
        ENC_E1_SAMPLE_DONE,
        ENC_U_E1_ADD_DONE,
        ENC_U_COMPRESS_DONE,
        ENC_U_PACK_DONE,
        ENC_V_BEGIN,
        ENC_V_ZERO_DONE,
        ENC_V_MUL_DONE,
        ENC_V_ADD_DONE,
        ENC_V_INTT_DONE,
        ENC_E2_HASH_DONE,
        ENC_E2_SAMPLE_DONE,
        ENC_V_E2_ADD_DONE,
        ENC_MU_DONE,
        ENC_V_MU_ADD_DONE,
        ENC_V_COMPRESS_DONE,
        ENC_V_PACK_DONE,

        DEC_U_BEGIN,
        DEC_U_DECODE_DONE,
        DEC_U_NTT_DONE,
        DEC_V_DECODE_DONE,
        DEC_ACC_BEGIN,
        DEC_MUL_DONE,
        DEC_ADD_DONE,
        DEC_INTT_DONE,
        DEC_W_DONE,
        DEC_MESSAGE_DONE,
        DEC_G_DONE,
        DEC_J_DONE,
        DEC_COMPARE_READ,
        DEC_COMPARE_WRITE,
        DEC_SELECT_SECRET,
        DEC_SELECT_PREP,
        S_ZEROIZE,
        S_FINISH
    } state_t;

    state_t state;
    state_t return_state;
    logic [1:0] operation_reg;
    logic [255:0] d_latched, z_latched, m_latched;
    logic pk_complete, ct_complete, pk_mode, ct_mode;
    logic load_active, load_mode_reg;
    logic [1:0] load_object_reg;
    logic [12:0] load_count, load_limit;
    logic read_permit;
    logic [1:0] packed_phase;
    logic [7:0] packed_byte0, packed_byte1;
    logic [7:0] private_hash_diff;
    localparam logic [3:0] HASH_SECRET = 4'd6;
    localparam logic [3:0] DEST_FINGERPRINT = 4'd6;

    logic mode_reg;
    logic [2:0] k_reg;
    logic [3:0] du_reg;
    logic [3:0] dv_reg;
    logic [12:0] ek_length;
    logic [12:0] dk_length;
    logic [12:0] ct_length;

    logic [255:0] rho_reg;
    logic [255:0] sigma_reg;
    logic [255:0] ek_hash_reg;
    logic [255:0] randomness_reg;
    logic [255:0] message_prime_reg;
    logic [255:0] key_candidate_reg;
    logic [255:0] fallback_key_reg;

    logic [2:0] outer_index;
    logic [2:0] inner_index;
    logic [7:0] nonce_reg;
    logic [12:0] op_index;
    // Register loop terminal decisions one state before they are consumed.
    // This keeps the wide counter comparators out of the 139-state FSM's
    // next-state and counter-D muxes at high clock rates.
    logic        op_last_q;
    // The 32-byte private-key tail readers no longer share the wide global
    // operation counter. This removes their state decode from op_index's
    // high-fanout D/enable network and makes both captures simple shifts.
    logic [4:0] key_byte_index;
    logic [7:0] coefficient_index;
    logic       coefficient_last_q;
    logic [4:0] poly_src_a_slot;
    logic [4:0] poly_src_b_slot;
    logic [4:0] poly_dest_slot;
    logic       poly_subtract;
    logic       ntt_inverse_reg;

    logic [3:0] hash_source_reg;
    logic [3:0] hash_dest_reg;
    logic [1:0] hash_mode_reg;
    logic [11:0] hash_input_length;
    logic [10:0] hash_output_length;
    logic hash_use_prime;
    logic matrix_transpose;
    logic [7:0] hash_source_byte;
    logic [7:0] hash_input_q, hash_output_q;
    logic [7:0] hash_d_q, hash_sigma_q, hash_rho_q, hash_m_q, hash_prime_q;
    logic [7:0] hash_ek_q, hash_z_q, hash_encaps_q, hash_decaps_q;
    // Pipeline both sides of the modulo arithmetic. The operand registers cut
    // the synchronous M10K read delay; the result registers cut the RAM-write
    // path. G_POLY_WRITE therefore contains only a short result selection.
    logic [11:0] poly_operand_a, poly_operand_b;
    logic [11:0] poly_add_q, poly_sub_q;
    logic ciphertext_matches;

    logic       sampler_cbd_reg;

    logic [3:0] transform_d;
    logic       transform_compress;
    logic [3:0] codec_d_reg;
    logic [12:0] codec_byte_base;
    logic [8:0] codec_byte_count;
    logic       codec_decode_decompress;

    logic       re_encrypt;
    logic [7:0] cipher_diff;
    logic [7:0] message_byte_accum;
    logic [2:0] message_bit_index;
    // Stream the message LSB first into mu. A fixed bit tap avoids a
    // coefficient_index -> 256:1 mux -> polynomial RAM timing path.
    logic [255:0] mu_shift_reg;
    logic       internal_error;

    // Keep the wide public-secret registers out of the main FSM's combined
    // error/finish clear cone.  The former merged synchronous-clear network
    // could trace through NTT status and error_code to all 256 destination FFs.
    // secret_valid is withdrawn on the command clock; physical erasure follows
    // through this local registered token one clock later.
    (* maxfan = 32, preserve, dont_merge *) logic secret_outputs_clear_q;

    always_ff @(posedge clk) begin
        if (!rst_n)
            secret_outputs_clear_q <= 1'b1;
        else
            secret_outputs_clear_q <=
                ((state == S_IDLE) && (zeroize || load_begin || start)) ||
                ((state == ENC_V_PACK_DONE) && internal_error) ||
                ((state == DEC_SELECT_SECRET) &&
                 (internal_error || (error_code != 8'd0)));
    end

    always_ff @(posedge clk) begin
        if (!rst_n || secret_outputs_clear_q) begin
            shared_secret_encaps <= 256'd0;
            shared_secret_decaps <= 256'd0;
            secret_fingerprint  <= 256'd0;
        end else begin
            if (state == G_HASH_OUT_CAP) begin
                if (hash_dest_reg == DEST_FINGERPRINT)
                    secret_fingerprint <= {hash_output_q,
                                           secret_fingerprint[255:8]};
                else if ((hash_dest_reg == DEST_ENCAP_K_R) &&
                         (op_index < 13'd32))
                    shared_secret_encaps <= {hash_output_q,
                                             shared_secret_encaps[255:8]};
            end

            if ((state == DEC_SELECT_SECRET) && !internal_error &&
                (error_code == 8'd0))
                shared_secret_decaps <= ciphertext_matches
                    ? key_candidate_reg : fallback_key_reg;
        end
    end

    logic        poly_we_a;
    logic [12:0] poly_addr_a;
    logic [11:0] poly_data_a;
    logic [11:0] poly_q_a;
    logic        poly_we_b;
    logic [12:0] poly_addr_b;
    logic [11:0] poly_data_b;
    logic [11:0] poly_q_b;

    logic        byte_we_a;
    logic [12:0] byte_addr_a;
    logic [7:0]  byte_data_a;
    logic [7:0]  byte_q_a;
    logic        byte_we_b;
    logic [12:0] byte_addr_b;
    logic [7:0]  byte_data_b;
    logic [7:0]  byte_q_b;

    logic sponge_start;
    logic sponge_input_we;
    logic [10:0] sponge_input_address;
    logic [7:0] sponge_input_data;
    logic [9:0] sponge_output_address;
    logic [7:0] sponge_output_data;
    logic sponge_busy;
    logic sponge_done;
    logic [31:0] sponge_cycles;
    logic [3:0] sponge_debug;

    logic sampler_start;
    logic sampler_load_we;
    logic [9:0] sampler_load_address;
    logic [7:0] sampler_load_data;
    logic [7:0] sampler_read_address;
    logic [11:0] sampler_read_data;
    logic sampler_busy;
    logic sampler_done;
    logic sampler_error;
    logic [31:0] sampler_cycles;

    logic codec_start;
    logic codec_encode;
    logic codec_load_coefficient_we;
    logic [7:0] codec_load_coefficient_address;
    logic [11:0] codec_load_coefficient_data;
    logic codec_load_byte_we;
    logic [8:0] codec_load_byte_address;
    logic [7:0] codec_load_byte_data;
    logic [7:0] codec_read_coefficient_address;
    logic [11:0] codec_read_coefficient_data;
    logic [8:0] codec_read_byte_address;
    logic [7:0] codec_read_byte_data;
    logic codec_busy;
    logic codec_done;
    logic codec_invalid_d;
    logic [31:0] codec_cycles;

    logic ntt_start;
    logic ntt_load_we;
    logic [7:0] ntt_load_address;
    logic [11:0] ntt_load_data;
    logic [7:0] ntt_read_address;
    logic [11:0] ntt_read_data;
    logic ntt_busy;
    logic ntt_done;
    logic [31:0] ntt_cycles;
    logic [7:0] ntt_debug_length;
    logic [7:0] ntt_debug_j;
    logic [6:0] ntt_debug_zeta;

    logic mul_start;
    logic mul_load_a_we;
    logic mul_load_b_we;
    logic [7:0] mul_load_address;
    logic [11:0] mul_load_a_data;
    logic [11:0] mul_load_b_data;
    logic [7:0] mul_read_address;
    logic [11:0] mul_read_data;
    logic mul_busy;
    logic mul_done;
    logic [31:0] mul_cycles;
    logic [6:0] mul_debug_pair;

    logic [11:0] add_result;
    logic [11:0] sub_result;
    logic [11:0] transform_output;
    logic transform_done;
    logic [11:0] transform_input_reg;
    logic [11:0] transform_result_reg;
    logic transform_valid;
    // Keep the external wipe/reset decode off the DSP clock-enable network.
    // Both clears are deliberately registered locally: S_ZEROIZE lasts long
    // enough to scrub both RAMs, so the one-cycle primitive-clear latency is
    // hidden and no transform/hash request can overlap it.
    (* maxfan = 32, preserve, dont_merge *) logic transform_rst_n_q;
    (* maxfan = 64, preserve, dont_merge *) logic sponge_clear_q;
    logic [12:0] selected_read_base;
    logic [7:0] current_cipher_difference;
    logic       p_check_invalid;
    logic [4:0] hash_capture_byte_index;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            transform_rst_n_q <= 1'b0;
            sponge_clear_q    <= 1'b1;
        end else begin
            transform_rst_n_q <= !(zeroize || (state == S_ZEROIZE));
            sponge_clear_q    <= zeroize || (state == S_ZEROIZE);
        end
    end

    assign selected_read_base = (read_object == 2'd0) ? EK_BASE :
                                (read_object == 2'd1) ? DK_BASE :
                                (read_object == 2'd2) ? CT_BASE : CTP_BASE;
    assign read_data = read_permit ? byte_q_b : 8'd0;
    assign p_check_invalid =
        ((packed_phase == 2'd1) && ({byte_q_a[3:0], packed_byte0} >= 12'd3329)) ||
        ((packed_phase == 2'd2) && ({byte_q_a, packed_byte1[7:4]} >= 12'd3329));
    assign load_ready = (state == S_IDLE) && load_active && !start && !zeroize;
    // read_data dong bo mot chu ky; khong xuat RAM bi mat/du lieu dang tinh.
    always_ff @(posedge clk) begin
        if (!rst_n) read_permit <= 1'b0;
        else read_permit <= (state == S_IDLE) && !start && !zeroize && !load_begin &&
            (((read_object == 2'd0) && pk_complete &&
               (read_address < (pk_mode ? 13'd1568 : 13'd1184))) ||
             ((read_object == 2'd2) && ct_complete &&
               (read_address < (ct_mode ? 13'd1568 : 13'd1088))));
    end
    assign current_cipher_difference = byte_q_a ^ byte_q_b;
    always_comb begin
        hash_capture_byte_index = op_index[4:0];
`ifdef CONTINUOUS_BANKED_BYTE_STREAM_OPT
        if (state == G_HASH_LOAD_WRITE)
            // Explicit five-bit destination provides modulo-32 wrap at the
            // 32-byte source-bank boundary (for example m || H(ek)).
            hash_capture_byte_index = op_index[4:0] + 5'd1;
`endif
    end
    // Local pipeline copies are valid for one transfer and are then erased.
    // Select bytes from each 256-bit bank during the existing RAM-read cycle;
    // the following cycle selects the source bank. No extra hash-load clocks.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            {hash_d_q,hash_sigma_q,hash_rho_q,hash_m_q,hash_prime_q,
             hash_ek_q,hash_z_q,hash_encaps_q,hash_decaps_q} <= 0;
        end else begin
            {hash_d_q,hash_sigma_q,hash_rho_q,hash_m_q,hash_prime_q,
             hash_ek_q,hash_z_q,hash_encaps_q,hash_decaps_q} <= 0;
            if ((state==G_HASH_LOAD_READ
`ifdef CONTINUOUS_BANKED_BYTE_STREAM_OPT
                 || (state==G_HASH_LOAD_WRITE && !op_last_q)
`endif
                ) && !zeroize) begin
                // V2 primes byte i+1 while byte i is committed to the sponge.
                // The byte still crosses this local register boundary before
                // reaching the sponge input RAM, preserving the V1 timing cut.
`ifdef CONTINUOUS_BANKED_BYTE_STREAM_OPT
                hash_d_q <= d_latched[8*hash_capture_byte_index+:8];
                hash_sigma_q <= sigma_reg[8*hash_capture_byte_index+:8];
                hash_rho_q <= rho_reg[8*hash_capture_byte_index+:8];
                hash_m_q <= m_latched[8*hash_capture_byte_index+:8];
                hash_prime_q <= message_prime_reg[8*hash_capture_byte_index+:8];
                hash_ek_q <= ek_hash_reg[8*hash_capture_byte_index+:8];
                hash_z_q <= z_latched[8*hash_capture_byte_index+:8];
                hash_encaps_q <= shared_secret_encaps[8*hash_capture_byte_index+:8];
                hash_decaps_q <= shared_secret_decaps[8*hash_capture_byte_index+:8];
`else
                hash_d_q <= d_latched[8*op_index[4:0]+:8];
                hash_sigma_q <= sigma_reg[8*op_index[4:0]+:8];
                hash_rho_q <= rho_reg[8*op_index[4:0]+:8];
                hash_m_q <= m_latched[8*op_index[4:0]+:8];
                hash_prime_q <= message_prime_reg[8*op_index[4:0]+:8];
                hash_ek_q <= ek_hash_reg[8*op_index[4:0]+:8];
                hash_z_q <= z_latched[8*op_index[4:0]+:8];
                hash_encaps_q <= shared_secret_encaps[8*op_index[4:0]+:8];
                hash_decaps_q <= shared_secret_decaps[8*op_index[4:0]+:8];
`endif
            end else if (state==P_HASH_CHECK_READ && !zeroize)
                hash_ek_q <= ek_hash_reg[8*op_index[4:0]+:8];
        end
    end
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            hash_input_q <= 0;
            poly_operand_a <= 0; poly_operand_b <= 0;
            poly_add_q <= 0; poly_sub_q <= 0; ciphertext_matches <= 0;
        end else begin
            hash_input_q <= (state==G_HASH_LOAD_CAPTURE) ? hash_source_byte : 8'd0;
`ifndef ITERATIVE_BASELINE_TIMING_FIX
`ifdef CONTINUOUS_BANKED_FAST_FRONTEND
            hash_output_q <= (state==G_HASH_OUT_PIPE || state==G_HASH_OUT_CAP)
                ? sponge_output_data : 8'd0;
`else
            hash_output_q <= (state==G_HASH_OUT_PIPE) ? sponge_output_data : 8'd0;
`endif
`endif
            poly_operand_a <= (state==G_POLY_CAPTURE) ? poly_q_a : 12'd0;
            poly_operand_b <= (state==G_POLY_CAPTURE) ? poly_q_b : 12'd0;
            poly_add_q <= (state==G_POLY_EXECUTE) ? add_result : 12'd0;
            poly_sub_q <= (state==G_POLY_EXECUTE) ? sub_result : 12'd0;
            ciphertext_matches <= (state==DEC_SELECT_PREP) && (cipher_diff==8'd0);
        end
    end
    // This is a transient pipeline byte and is overwritten before every use.
    // Keeping it inside the reset-guarded process inferred a reset-controlled
    // clock-enable even though the reset branch did not assign hash_output_q;
    // that produced a measured reset_sync_n -> hash_output_q setup violation.
`ifdef ITERATIVE_BASELINE_TIMING_FIX
    always_ff @(posedge clk) begin
`ifdef CONTINUOUS_BANKED_FAST_FRONTEND
        hash_output_q <= (state==G_HASH_OUT_PIPE || state==G_HASH_OUT_CAP)
            ? sponge_output_data : 8'd0;
`else
        hash_output_q <= (state==G_HASH_OUT_PIPE) ? sponge_output_data : 8'd0;
`endif
    end
`endif
    poly_ram_dp #(.DATA_WIDTH(12), .ADDR_WIDTH(13), .DEPTH(8192)) u_poly_store (
        .clk(clk),
        .we_a(poly_we_a), .addr_a(poly_addr_a), .data_a(poly_data_a), .q_a(poly_q_a),
        .we_b(poly_we_b), .addr_b(poly_addr_b), .data_b(poly_data_b), .q_b(poly_q_b)
    );

    poly_ram_dp #(.DATA_WIDTH(8), .ADDR_WIDTH(13), .DEPTH(8192)) u_byte_store (
        .clk(clk),
        .we_a(byte_we_a), .addr_a(byte_addr_a), .data_a(byte_data_a), .q_a(byte_q_a),
        .we_b(byte_we_b), .addr_b(byte_addr_b), .data_b(byte_data_b), .q_b(byte_q_b)
    );

    keccak_sponge u_sponge (
        .clk(clk), .rst_n(rst_n), .zeroize(sponge_clear_q), .start(sponge_start),
        .mode(hash_mode_reg), .input_length(hash_input_length),
        .output_length(hash_output_length),
        .input_we(sponge_input_we), .input_address(sponge_input_address),
        .input_data(sponge_input_data), .output_address(sponge_output_address),
        .output_data(sponge_output_data), .busy(sponge_busy), .done(sponge_done),
        .cycle_count(sponge_cycles), .debug_state(sponge_debug)
    );

    mlkem_sampler u_sampler (
        .clk(clk), .rst_n(rst_n), .start(sampler_start),
        .sample_cbd(sampler_cbd_reg), .load_byte_we(sampler_load_we),
        .load_byte_address(sampler_load_address), .load_byte_data(sampler_load_data),
        .read_coefficient_address(sampler_read_address),
        .read_coefficient_data(sampler_read_data), .busy(sampler_busy),
        .done(sampler_done), .sample_error(sampler_error),
        .cycle_count(sampler_cycles)
    );

    byte_codec_core u_byte_codec (
        .clk(clk), .rst_n(rst_n), .start(codec_start), .encode(codec_encode),
        .d(codec_d_reg), .load_coefficient_we(codec_load_coefficient_we),
        .load_coefficient_address(codec_load_coefficient_address),
        .load_coefficient_data(codec_load_coefficient_data),
        .load_byte_we(codec_load_byte_we), .load_byte_address(codec_load_byte_address),
        .load_byte_data(codec_load_byte_data),
        .read_coefficient_address(codec_read_coefficient_address),
        .read_coefficient_data(codec_read_coefficient_data),
        .read_byte_address(codec_read_byte_address),
        .read_byte_data(codec_read_byte_data), .busy(codec_busy), .done(codec_done),
        .invalid_d(codec_invalid_d), .cycle_count(codec_cycles)
    );

`ifdef MLKEM_STREAMING_BALANCED_4BU
    ntt_core_stream4 u_ntt (
`else
    ntt_core u_ntt (
`endif
        .clk(clk), .rst_n(rst_n), .start(ntt_start), .inverse(ntt_inverse_reg),
        .load_we(ntt_load_we), .load_address(ntt_load_address),
        .load_data(ntt_load_data), .read_address(ntt_read_address),
        .read_data(ntt_read_data), .busy(ntt_busy), .done(ntt_done),
        .cycle_count(ntt_cycles), .debug_length(ntt_debug_length),
        .debug_j(ntt_debug_j), .debug_zeta_index(ntt_debug_zeta)
    );

    multiply_ntts_core u_multiply (
        .clk(clk), .rst_n(rst_n), .start(mul_start),
        .load_a_we(mul_load_a_we), .load_b_we(mul_load_b_we),
        .load_address(mul_load_address), .load_a_data(mul_load_a_data),
        .load_b_data(mul_load_b_data), .read_address(mul_read_address),
        .read_data(mul_read_data), .busy(mul_busy), .done(mul_done),
        .cycle_count(mul_cycles), .debug_pair_index(mul_debug_pair)
    );

    mod_add u_add (.a(poly_operand_a), .b(poly_operand_b), .r(add_result));
    mod_sub u_sub (.a(poly_operand_a), .b(poly_operand_b), .r(sub_result));

    compress_seq u_transform (
        .clk(clk), .rst_n(transform_rst_n_q),
        .start(state==G_TRANS_CALCULATE || state==G_CODEC_DEC_OUT_CALCULATE || state==G_MESSAGE_CALCULATE),
        .compress((state==G_MESSAGE_CALCULATE) || (state==G_TRANS_CALCULATE && transform_compress)),
        .d(transform_d), .value(transform_input_reg),
        .result(transform_output), .valid_d(transform_valid), .busy(), .done(transform_done)
    );

    // Keep the polynomial RAM-A address out of the monolithic service-output
    // decoder.  Most states use the same source-slot address, while only the
    // three continuous front-end capture states prefetch i+1 and zeroization
    // uses a linear scrub address.  A dedicated positive decode prevents
    // unrelated one-hot state bits (for example G_NTT_OUT_CAP) from entering
    // the M10K address cone.
    always_comb begin : p_poly_port_a_address
        poly_addr_a = {poly_src_a_slot, coefficient_index};
`ifdef CONTINUOUS_BANKED_FAST_FRONTEND
        if ((state == G_NTT_IN_CAP) ||
            (state == G_MUL_IN_CAP) ||
            (state == G_CODEC_ENC_IN_CAP))
            poly_addr_a = {poly_src_a_slot, coefficient_index + 8'd1};
`endif
        if (state == S_ZEROIZE)
            poly_addr_a = {op_index[11:0], 1'b0};
    end

    always_comb begin
        hash_source_byte = 8'd0;
        case (hash_source_reg)
            HASH_SECRET: hash_source_byte = (operation_reg == 2'd2) ?
                hash_encaps_q : hash_decaps_q;
            HASH_D_K: begin
                if (op_index < 13'd32)
                    hash_source_byte = hash_d_q;
                else
                    hash_source_byte = {5'd0, k_reg};
            end
            HASH_SIGMA_N: begin
                if (op_index < 13'd32)
                    hash_source_byte = hash_sigma_q;
                else
                    hash_source_byte = nonce_reg;
            end
            HASH_RHO_I_J: begin
                if (op_index < 13'd32)
                    hash_source_byte = hash_rho_q;
                else if (op_index == 13'd32)
                    hash_source_byte = matrix_transpose
                        ? {5'd0, outer_index} : {5'd0, inner_index};
                else
                    hash_source_byte = matrix_transpose
                        ? {5'd0, inner_index} : {5'd0, outer_index};
            end
            HASH_EK: hash_source_byte = byte_q_a;
            HASH_M_EKH: begin
                if (op_index < 13'd32)
                    hash_source_byte = hash_use_prime
                        ? hash_prime_q : hash_m_q;
                else
                    hash_source_byte =
                        hash_ek_q;
            end
            HASH_Z_CT: begin
                if (op_index < 13'd32)
                    hash_source_byte = hash_z_q;
                else
                    hash_source_byte = byte_q_a;
            end
            default: hash_source_byte = 8'd0;
        endcase
    end

    always_comb begin
        poly_we_a   = 1'b0;
        poly_data_a = 12'd0;
        poly_we_b   = 1'b0;
        poly_addr_b = 13'd0;
        poly_data_b = 12'd0;

        byte_we_a   = 1'b0;
        byte_addr_a = 13'd0;
        byte_data_a = 8'd0;
        byte_we_b   = 1'b0;
        byte_addr_b = selected_read_base + read_address;
        byte_data_b = 8'd0;

        sponge_start          = 1'b0;
        sponge_input_we       = 1'b0;
        sponge_input_address  = op_index[10:0];
        sponge_input_data     = hash_input_q;
        sponge_output_address = op_index[9:0];

        sampler_start        = 1'b0;
        sampler_load_we      = 1'b0;
        sampler_load_address = op_index[9:0];
        sampler_load_data    = hash_output_q;
        sampler_read_address = coefficient_index;

        codec_start                    = 1'b0;
        codec_encode                   = 1'b0;
        codec_load_coefficient_we      = 1'b0;
        codec_load_coefficient_address = coefficient_index;
        codec_load_coefficient_data    = poly_q_a;
        codec_load_byte_we             = 1'b0;
        codec_load_byte_address        = op_index[8:0];
        codec_load_byte_data           = byte_q_a;
        codec_read_coefficient_address = coefficient_index;
        codec_read_byte_address        = op_index[8:0];

        ntt_start        = 1'b0;
        ntt_load_we      = 1'b0;
        ntt_load_address = coefficient_index;
        ntt_load_data    = poly_q_a;
        ntt_read_address = coefficient_index;

        mul_start        = 1'b0;
        mul_load_a_we    = 1'b0;
        mul_load_b_we    = 1'b0;
        mul_load_address = coefficient_index;
        mul_load_a_data  = poly_q_a;
        mul_load_b_data  = poly_q_b;
        mul_read_address = coefficient_index;

        case (state)
            S_IDLE: begin
                if (load_valid && load_ready) begin
                    byte_we_a = 1'b1;
                    byte_addr_a = ((load_object_reg == 2'd0) ? EK_BASE : CT_BASE) + load_count;
                    byte_data_a = load_data;
                end
            end
            P_RESTORE_READ: begin
                byte_addr_a = DK_BASE + 13'd384 * k_reg + op_index;
            end
            P_RESTORE_WRITE: begin
`ifdef CONTINUOUS_BANKED_BYTE_STREAM_OPT
                byte_addr_a = DK_BASE + 13'd384 * k_reg + op_index + 13'd1;
`else
                byte_addr_a = DK_BASE + 13'd384 * k_reg + op_index;
`endif
                byte_we_b = 1'b1;
                byte_addr_b = EK_BASE + op_index;
                byte_data_b = byte_q_a;
            end
            P_CHECK_READ: byte_addr_a = EK_BASE + op_index;
            P_CHECK_CAP: begin
`ifdef CONTINUOUS_BANKED_BYTE_STREAM_OPT
                byte_addr_a = EK_BASE + op_index + 13'd1;
`else
                byte_addr_a = EK_BASE + op_index;
`endif
            end
            P_RHO_READ, P_RHO_CAP: byte_addr_a = EK_BASE + 13'd384 * k_reg + key_byte_index;
            P_Z_READ, P_Z_CAP: byte_addr_a = DK_BASE + dk_length - 13'd32 + key_byte_index;
            P_HASH_CHECK_READ, P_HASH_CHECK_CAP:
                byte_addr_a = DK_BASE + 13'd768 * k_reg + 13'd32 + op_index;
            G_HASH_LOAD_READ: begin
                if (hash_source_reg == HASH_EK)
                    byte_addr_a = EK_BASE + op_index;
                else if ((hash_source_reg == HASH_Z_CT) && (op_index >= 13'd32))
                    byte_addr_a = CT_BASE + op_index - 13'd32;
            end
            G_HASH_LOAD_WRITE: begin
                sponge_input_we = 1'b1;
`ifdef CONTINUOUS_BANKED_BYTE_STREAM_OPT
                if (hash_source_reg == HASH_EK)
                    byte_addr_a = EK_BASE + op_index + 13'd1;
                else if ((hash_source_reg == HASH_Z_CT) &&
`ifdef CONTINUOUS_BANKED_V2_TIMING_FIX
                         (op_index >= 13'd31))
                    // The previous equivalent form compared (op_index + 1)
                    // with 32, placing an adder before the compare and RAM
                    // address mux.  Fold the constants so the compare is
                    // driven directly by the registered counter.
                    byte_addr_a = (CT_BASE - 13'd31) + op_index;
`else
                         ((op_index + 13'd1) >= 13'd32))
                    byte_addr_a = CT_BASE + op_index + 13'd1 - 13'd32;
`endif
`endif
            end
            G_HASH_START: sponge_start = 1'b1;
            G_HASH_OUT_REQ: sponge_output_address = op_index[9:0];
`ifdef CONTINUOUS_BANKED_FAST_FRONTEND
            // Prime the second RAM byte while byte zero enters hash_output_q.
            G_HASH_OUT_PIPE: sponge_output_address = op_index[9:0] + 10'd1;
`endif
            G_HASH_OUT_CAP: begin
`ifdef CONTINUOUS_BANKED_FAST_FRONTEND
                // hash_output_q contains byte i while the sponge RAM prefetches
                // byte i+2; sponge_output_data is captured as byte i+1 below.
                sponge_output_address = op_index[9:0] + 10'd2;
`else
                sponge_output_address = op_index[9:0];
`endif
                if (hash_dest_reg == DEST_SAMPLER)
                    sampler_load_we = 1'b1;
            end

            G_SAMPLE_START: sampler_start = 1'b1;
            G_SAMPLE_OUT_REQ: sampler_read_address = coefficient_index;
            G_SAMPLE_OUT_CAP: begin
`ifdef CONTINUOUS_BANKED_FAST_FRONTEND
                sampler_read_address = coefficient_index + 8'd1;
`else
                sampler_read_address = coefficient_index;
`endif
                poly_we_b   = 1'b1;
                poly_addr_b = {poly_dest_slot, coefficient_index};
                poly_data_b = sampler_read_data;
            end

            G_NTT_IN_CAP: begin
                ntt_load_we     = 1'b1;
                ntt_load_data   = poly_q_a;
            end
            G_NTT_START: ntt_start = 1'b1;
            G_NTT_OUT_REQ: begin
`ifdef MLKEM_STREAMING_BALANCED_4BU
                // ntt_core_stream4 has a registered output-bank mux.  Index 0
                // was prefetched while G_NTT_WAIT observed done; request index
                // 1 here so the following capture loop remains II=1.
                ntt_read_address = coefficient_index + 8'd1;
`else
                ntt_read_address = coefficient_index;
`endif
            end
            G_NTT_OUT_CAP: begin
`ifdef MLKEM_STREAMING_BALANCED_4BU
                // Two addresses lead the committed coefficient: one for the
                // M10K output register and one for the new bank-mux register.
                ntt_read_address = coefficient_index + 8'd2;
`elsif CONTINUOUS_BANKED_FAST_FRONTEND
                ntt_read_address = coefficient_index + 8'd1;
`else
                ntt_read_address = coefficient_index;
`endif
                poly_we_b   = 1'b1;
                poly_addr_b = {poly_dest_slot, coefficient_index};
                poly_data_b = ntt_read_data;
            end

            G_MUL_IN_REQ: begin
                poly_addr_b = {poly_src_b_slot, coefficient_index};
            end
            G_MUL_IN_CAP: begin
`ifdef CONTINUOUS_BANKED_FAST_FRONTEND
                poly_addr_b      = {poly_src_b_slot, coefficient_index + 8'd1};
`else
                poly_addr_b      = {poly_src_b_slot, coefficient_index};
`endif
                mul_load_a_we    = 1'b1;
                mul_load_b_we    = 1'b1;
                mul_load_a_data  = poly_q_a;
                mul_load_b_data  = poly_q_b;
            end
            G_MUL_START: mul_start = 1'b1;
            G_MUL_OUT_REQ: mul_read_address = coefficient_index;
            G_MUL_OUT_CAP: begin
`ifdef CONTINUOUS_BANKED_FAST_FRONTEND
                mul_read_address = coefficient_index + 8'd1;
`else
                mul_read_address = coefficient_index;
`endif
                poly_we_b   = 1'b1;
                poly_addr_b = {poly_dest_slot, coefficient_index};
                poly_data_b = mul_read_data;
            end

            G_POLY_ZERO: begin
                poly_we_b   = 1'b1;
                poly_addr_b = {poly_dest_slot, coefficient_index};
                poly_data_b = 12'd0;
            end
            G_POLY_READ: begin
                poly_addr_b = {poly_src_b_slot, coefficient_index};
            end
`ifdef CONTINUOUS_BANKED_CYCLE_OPT
            // The synchronous RAM result is first isolated in
            // poly_operand_{a,b}.  Write the following modular result
            // directly in EXECUTE, eliminating a redundant result-register
            // and WRITE state without creating a RAM-output-to-RAM-input
            // combinational path.
            G_POLY_EXECUTE: begin
                poly_we_b   = 1'b1;
                poly_addr_b = {poly_dest_slot, coefficient_index};
                poly_data_b = poly_subtract ? sub_result : add_result;
            end
`else
            G_POLY_WRITE: begin
                poly_we_b   = 1'b1;
                poly_addr_b = {poly_dest_slot, coefficient_index};
                poly_data_b = poly_subtract ? poly_sub_q : poly_add_q;
            end
`endif

            G_TRANS_WRITE: begin
                poly_we_b   = 1'b1;
                poly_addr_b = {poly_dest_slot, coefficient_index};
                poly_data_b = transform_result_reg;
            end

            G_CODEC_ENC_IN_CAP: begin
                codec_load_coefficient_we   = 1'b1;
                codec_load_coefficient_data = poly_q_a;
            end
            G_CODEC_ENC_START: begin
                codec_start  = 1'b1;
                codec_encode = 1'b1;
            end
            G_CODEC_ENC_OUT_REQ: codec_read_byte_address = op_index[8:0];
            G_CODEC_ENC_OUT_CAP: begin
`ifdef CONTINUOUS_BANKED_FAST_FRONTEND
                codec_read_byte_address = op_index[8:0] + 9'd1;
`else
                codec_read_byte_address = op_index[8:0];
`endif
                byte_we_b   = 1'b1;
                byte_addr_b = codec_byte_base + op_index;
                byte_data_b = codec_read_byte_data;
            end

            G_CODEC_DEC_IN_REQ: byte_addr_a = codec_byte_base + op_index;
            G_CODEC_DEC_IN_CAP: begin
`ifdef CONTINUOUS_BANKED_FAST_FRONTEND
                byte_addr_a = codec_byte_base + op_index + 13'd1;
`else
                byte_addr_a = codec_byte_base + op_index;
`endif
                codec_load_byte_we   = 1'b1;
                codec_load_byte_data = byte_q_a;
            end
            G_CODEC_DEC_START: begin
                codec_start  = 1'b1;
                codec_encode = 1'b0;
            end
            G_CODEC_DEC_OUT_REQ: codec_read_coefficient_address = coefficient_index;
            G_CODEC_DEC_OUT_CAP: begin
                codec_read_coefficient_address = coefficient_index;
            end
            G_CODEC_DEC_OUT_WRITE: begin
                poly_we_b   = 1'b1;
                poly_addr_b = {poly_dest_slot, coefficient_index};
                poly_data_b = transform_result_reg;
            end

            KG_RHO_COPY: begin
                byte_we_b   = 1'b1;
                byte_addr_b = EK_BASE + (13'd384 * k_reg) + key_byte_index;
                // rho_reg is assembled with byte zero in [7:0].  Streaming the
                // low byte removes the 32:1 variable part-select mux in front
                // of the byte-store M10K input.
                byte_data_b = rho_reg[7:0];
            end
            KG_COPY_EK_READ: byte_addr_a = EK_BASE + op_index;
            KG_COPY_EK_WRITE: begin
`ifdef CONTINUOUS_BANKED_BYTE_STREAM_OPT
                byte_addr_a = EK_BASE + op_index + 13'd1;
`else
                byte_addr_a = EK_BASE + op_index;
`endif
                byte_we_b   = 1'b1;
                byte_addr_b = DK_BASE + (13'd384 * k_reg) + op_index;
                byte_data_b = byte_q_a;
            end
            KG_COPY_HASH: begin
                byte_we_b   = 1'b1;
                byte_addr_b = DK_BASE + (13'd768 * k_reg) + 13'd32 + key_byte_index;
                byte_data_b = ek_hash_reg[7:0];
            end
            KG_COPY_Z: begin
                byte_we_b   = 1'b1;
                byte_addr_b = DK_BASE + (13'd768 * k_reg) + 13'd64 + key_byte_index;
                byte_data_b = z_latched[7:0];
            end

            ENC_MU_DONE: begin
                poly_we_b   = 1'b1;
                poly_addr_b = {SLOT_MU, coefficient_index};
                poly_data_b = mu_shift_reg[0] ? 12'd1665 : 12'd0;
            end

            DEC_COMPARE_READ: begin
                byte_addr_a = CT_BASE + op_index;
                byte_addr_b = CTP_BASE + op_index;
            end
            DEC_COMPARE_WRITE: begin
`ifdef CONTINUOUS_BANKED_BYTE_STREAM_OPT
                byte_addr_a = CT_BASE + op_index + 13'd1;
                byte_addr_b = CTP_BASE + op_index + 13'd1;
`else
                byte_addr_a = CT_BASE + op_index;
                byte_addr_b = CTP_BASE + op_index;
`endif
            end
            S_ZEROIZE: begin
                // Xoa hai dia chi moi chu ky tren ca RAM byte va RAM da thuc.
                byte_we_a   = 1'b1;
                byte_addr_a = {op_index[11:0], 1'b0};
                byte_data_a = 8'd0;
                byte_we_b   = 1'b1;
                byte_addr_b = {op_index[11:0], 1'b0} + 13'd1;
                byte_data_b = 8'd0;

                poly_we_a   = 1'b1;
                poly_data_a = 12'd0;
                poly_we_b   = 1'b1;
                poly_addr_b = {op_index[11:0], 1'b0} + 13'd1;
                poly_data_b = 12'd0;
            end
            default: begin
            end
        endcase
    end

    // No extra FSM cycles: preload before the first mu write, then shift
    // on each of the existing 256 writes. Clear this extra secret copy
    // on reset, idle, zeroization and completion as well as by shifting.
    always_ff @(posedge clk) begin
        if (!rst_n) mu_shift_reg <= 256'd0;
        else if (state == S_IDLE || state == S_ZEROIZE || state == S_FINISH)
            mu_shift_reg <= 256'd0;
        else if (state == ENC_V_E2_ADD_DONE)
            mu_shift_reg <= re_encrypt ? message_prime_reg : m_latched;
        else if (state == ENC_MU_DONE)
            mu_shift_reg <= {1'b0, mu_shift_reg[255:1]};
    end

    // The operation counter is shared by several byte-stream micro-engines.
    // Keep it out of the large algorithm FSM so Quartus can infer one compact
    // increment/clear datapath instead of a mux fed by dozens of caller states.
    // Each READ/REQ state registers its terminal comparison for the following
    // CAP/WRITE state; this removes the comparator from the next-state path.
    always_ff @(posedge clk) begin : p_op_terminal
        if (!rst_n || (state == S_IDLE) || (state == S_FINISH)) begin
            op_last_q <= 1'b0;
        end else begin
            case (state)
                P_RESTORE_READ:
                    op_last_q <= ((op_index + 13'd1) == ek_length);
                P_CHECK_READ:
                    op_last_q <= ((op_index + 13'd1) == (13'd384 * k_reg));
                P_HASH_CHECK_READ:
                    op_last_q <= (op_index == 13'd31);
                G_HASH_LOAD_READ:
                    op_last_q <= ((op_index + 13'd1) >= hash_input_length);
                G_HASH_OUT_REQ:
                    op_last_q <= ((op_index + 13'd1) >= hash_output_length);
                G_CODEC_ENC_OUT_REQ,
                G_CODEC_DEC_IN_REQ:
                    op_last_q <= ((op_index + 13'd1) >= codec_byte_count);
                KG_COPY_EK_READ:
                    op_last_q <= ((op_index + 13'd1) >= ek_length);
                DEC_COMPARE_READ:
                    op_last_q <= ((op_index + 13'd1) >= ct_length);

                // V2 keeps the RAM pipeline primed.  While the current byte is
                // consumed, predict whether byte i+1 will be the final byte.
`ifdef CONTINUOUS_BANKED_BYTE_STREAM_OPT
                P_RESTORE_WRITE,
                KG_COPY_EK_WRITE:
                    op_last_q <= ((op_index + 13'd2) >= ek_length);
                P_CHECK_CAP:
                    op_last_q <= ((op_index + 13'd2) >= (13'd384 * k_reg));
                G_HASH_LOAD_WRITE:
                    op_last_q <= ((op_index + 13'd2) >= hash_input_length);
                DEC_COMPARE_WRITE:
                    op_last_q <= ((op_index + 13'd2) >= ct_length);
                P_HASH_CHECK_CAP:
                    op_last_q <= 1'b0;
`else
                // These states consume the decision registered above.
                P_RESTORE_WRITE,
                P_CHECK_CAP,
                P_HASH_CHECK_CAP,
                G_HASH_LOAD_WRITE,
                KG_COPY_EK_WRITE,
                DEC_COMPARE_WRITE:
                    op_last_q <= 1'b0;
`endif
`ifdef CONTINUOUS_BANKED_FAST_FRONTEND
                G_HASH_OUT_CAP,
                G_CODEC_ENC_OUT_CAP,
                G_CODEC_DEC_IN_CAP:
                    // Predict whether the next streamed item is the last one.
                    op_last_q <= ((op_index + 13'd2) >=
                        ((state == G_HASH_OUT_CAP) ? hash_output_length :
                         (state == G_CODEC_ENC_OUT_CAP ||
                          state == G_CODEC_DEC_IN_CAP) ?
                            {4'd0,codec_byte_count} : 13'd0));
`else
                G_HASH_OUT_CAP,
                G_CODEC_ENC_OUT_CAP,
                G_CODEC_DEC_IN_CAP:
                    op_last_q <= 1'b0;
`endif

                // Zeroization is a one-state loop, so predict its final count.
                S_ZEROIZE: begin
                    if (op_last_q)
                        op_last_q <= 1'b0;
                    else
                        op_last_q <= (op_index == 13'd4094);
                end
                default: begin
                end
            endcase
        end
    end

    always_ff @(posedge clk) begin : p_op_counter
        if (!rst_n || (state == S_IDLE) || (state == S_FINISH)) begin
            op_index <= 13'd0;
        end else begin
            case (state)
                P_RESTORE_WRITE,
                P_HASH_CHECK_CAP,
                G_HASH_LOAD_WRITE,
                G_HASH_OUT_CAP,
                G_CODEC_ENC_OUT_CAP,
                G_CODEC_DEC_IN_CAP,
                KG_COPY_EK_WRITE,
                DEC_COMPARE_WRITE,
                S_ZEROIZE: begin
                    if (op_last_q)
                        op_index <= 13'd0;
                    else
                        op_index <= op_index + 13'd1;
                end
                P_CHECK_CAP: begin
                    if (!p_check_invalid) begin
                        if (op_last_q)
                            op_index <= 13'd0;
                        else
                            op_index <= op_index + 13'd1;
                    end
                end
                // Preserve the old explicit boundary clears between the input
                // and output halves of these micro-engines.
                G_HASH_WAIT: begin
                    if (sponge_done)
                        op_index <= 13'd0;
                end
                G_CODEC_ENC_WAIT: begin
                    if (codec_done)
                        op_index <= 13'd0;
                end
                default: begin
                end
            endcase
        end
    end

    // Polynomial loops use the same scheme. READ/REQ computes the registered
    // terminal flag; CAP/WRITE consumes it. The two single-state loops predict
    // index 255 while processing index 254, preserving the original cycle count.
    always_ff @(posedge clk) begin : p_coefficient_terminal
        if (!rst_n || (state == S_IDLE) || (state == S_FINISH)) begin
            coefficient_last_q <= 1'b0;
        end else begin
            case (state)
                G_SAMPLE_OUT_REQ,
                G_NTT_IN_REQ,
                G_NTT_OUT_REQ,
                G_MUL_IN_REQ,
                G_MUL_OUT_REQ,
                G_POLY_READ,
                G_TRANS_READ,
                G_CODEC_ENC_IN_REQ,
                G_CODEC_DEC_OUT_REQ,
                G_MESSAGE_READ:
                    coefficient_last_q <= (coefficient_index == 8'd255);

`ifdef CONTINUOUS_BANKED_FAST_FRONTEND
                G_SAMPLE_OUT_CAP,
                G_NTT_IN_CAP,
                G_NTT_OUT_CAP,
                G_MUL_IN_CAP,
                G_MUL_OUT_CAP,
                G_CODEC_ENC_IN_CAP:
                    // Current data is committed while the next RAM address is
                    // already presented.  Raise terminal one item in advance.
                    coefficient_last_q <= (coefficient_index == 8'd254);
`else
                G_SAMPLE_OUT_CAP,
                G_NTT_IN_CAP,
                G_NTT_OUT_CAP,
                G_MUL_IN_CAP,
                G_MUL_OUT_CAP,
                G_CODEC_ENC_IN_CAP,
`endif
`ifdef CONTINUOUS_BANKED_CYCLE_OPT
                G_POLY_EXECUTE,
`else
                G_POLY_WRITE,
`endif
                G_TRANS_WRITE,
                G_CODEC_DEC_OUT_WRITE,
                G_MESSAGE_WRITE:
                    coefficient_last_q <= 1'b0;

                G_POLY_ZERO,
                ENC_MU_DONE: begin
                    if (coefficient_last_q)
                        coefficient_last_q <= 1'b0;
                    else
                        coefficient_last_q <= (coefficient_index == 8'd254);
                end
                default: begin
                end
            endcase
        end
    end

    always_ff @(posedge clk) begin : p_coefficient_counter
        if (!rst_n || (state == S_IDLE) || (state == S_FINISH)) begin
            coefficient_index <= 8'd0;
        end else begin
            case (state)
                G_SAMPLE_OUT_CAP,
                G_NTT_IN_CAP,
                G_NTT_OUT_CAP,
                G_MUL_IN_CAP,
                G_MUL_OUT_CAP,
                G_POLY_ZERO,
`ifdef CONTINUOUS_BANKED_CYCLE_OPT
                G_POLY_EXECUTE,
`else
                G_POLY_WRITE,
`endif
                G_TRANS_WRITE,
                G_CODEC_ENC_IN_CAP,
                G_CODEC_DEC_OUT_WRITE,
                G_MESSAGE_WRITE,
                ENC_MU_DONE: begin
                    if (coefficient_last_q)
                        coefficient_index <= 8'd0;
                    else
                        coefficient_index <= coefficient_index + 8'd1;
                end
                G_SAMPLE_WAIT: begin
                    if (sampler_done)
                        coefficient_index <= 8'd0;
                end
                G_NTT_WAIT: begin
                    if (ntt_done)
                        coefficient_index <= 8'd0;
                end
                G_MUL_WAIT: begin
                    if (mul_done)
                        coefficient_index <= 8'd0;
                end
                G_CODEC_DEC_WAIT: begin
                    if (codec_done)
                        coefficient_index <= 8'd0;
                end
                default: begin
                end
            endcase
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state                 <= S_ZEROIZE;
            return_state          <= S_IDLE;
            operation_reg <= 2'd0;
            d_latched <= 0; z_latched <= 0; m_latched <= 0;
            pk_complete <= 0; ct_complete <= 0; pk_mode <= 0; ct_mode <= 0;
            load_active <= 0; load_count <= 0; load_limit <= 0;
            load_object_reg <= 0; load_mode_reg <= 0;
            load_done <= 0; load_error <= 0;
            key_ready <= 0; key_mode_1024 <= 0;
            secret_valid <= 0;
            packed_phase <= 0; packed_byte0 <= 0; packed_byte1 <= 0;
            private_hash_diff <= 0;
            mode_reg              <= 1'b0;
            k_reg                 <= 3'd3;
            du_reg                <= 4'd10;
            dv_reg                <= 4'd4;
            ek_length             <= 13'd1184;
            dk_length             <= 13'd2400;
            ct_length             <= 13'd1088;
            rho_reg               <= 256'd0;
            sigma_reg             <= 256'd0;
            ek_hash_reg           <= 256'd0;
            randomness_reg        <= 256'd0;
            message_prime_reg     <= 256'd0;
            key_candidate_reg     <= 256'd0;
            fallback_key_reg      <= 256'd0;
            outer_index           <= 3'd0;
            inner_index           <= 3'd0;
            nonce_reg             <= 8'd0;
            key_byte_index        <= 5'd0;
            poly_src_a_slot       <= 5'd0;
            poly_src_b_slot       <= 5'd0;
            poly_dest_slot        <= 5'd0;
            poly_subtract         <= 1'b0;
            ntt_inverse_reg       <= 1'b0;
            hash_source_reg       <= HASH_D_K;
            hash_dest_reg         <= DEST_RHO_SIGMA;
            hash_mode_reg         <= 2'd0;
            hash_input_length     <= 12'd0;
            hash_output_length    <= 11'd0;
            hash_use_prime        <= 1'b0;
            matrix_transpose      <= 1'b0;
            sampler_cbd_reg       <= 1'b0;
            transform_d           <= 4'd1;
            transform_compress    <= 1'b1;
            transform_input_reg   <= 12'd0;
            transform_result_reg  <= 12'd0;
            codec_d_reg           <= 4'd1;
            codec_byte_base       <= 13'd0;
            codec_byte_count      <= 9'd0;
            codec_decode_decompress <= 1'b0;
            re_encrypt            <= 1'b0;
            cipher_diff           <= 8'd0;
            message_byte_accum    <= 8'd0;
            message_bit_index     <= 3'd0;
            internal_error        <= 1'b0;
            busy                  <= 1'b1;
            done                  <= 1'b0;
            zeroize_done          <= 1'b0;
            pass                  <= 1'b0;
            fail                  <= 1'b0;
            stage                 <= 4'd0;
            cycle_count           <= 32'd0;
            error_code            <= 8'd0;
        end else begin
            done         <= 1'b0;
            zeroize_done <= 1'b0;
            load_done <= 1'b0;
            load_error <= 1'b0;
            if (busy)
                cycle_count <= cycle_count + 32'd1;

            case (state)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (zeroize) begin
                        key_ready <= 0; pk_complete <= 0; ct_complete <= 0;
                        load_active <= 0; load_count <= 0;
                        d_latched <= 0; z_latched <= 0; m_latched <= 0;
                        secret_valid <= 0;
                        // Xoa ngay cac thanh ghi nhay cam, sau do quet hai RAM.
                        rho_reg               <= 256'd0;
                        sigma_reg             <= 256'd0;
                        ek_hash_reg           <= 256'd0;
                        randomness_reg        <= 256'd0;
                        message_prime_reg     <= 256'd0;
                        key_candidate_reg     <= 256'd0;
                        fallback_key_reg      <= 256'd0;
                        cipher_diff           <= 8'd0;
                        message_byte_accum    <= 8'd0;
                        key_byte_index        <= 5'd0;
                        busy                  <= 1'b1;
                        stage                 <= 4'd6;
                        state                 <= S_ZEROIZE;
                    end else if (load_begin) begin
                        load_count <= 0;
                        load_object_reg <= load_object;
                        load_mode_reg <= load_mode_1024;
                        load_limit <= load_length;
                        secret_valid <= 0;
                        if (load_object == 0) pk_complete <= 0;
                        if (load_object == 2) ct_complete <= 0;
                        if (((load_object == 0) &&
                             (load_length == (load_mode_1024 ? 13'd1568 : 13'd1184))) ||
                            ((load_object == 2) &&
                             (load_length == (load_mode_1024 ? 13'd1568 : 13'd1088))))
                            load_active <= 1;
                        else begin load_active <= 0; load_error <= 1; end
                    end else if (load_valid && load_ready) begin
                        load_count <= load_count + 1'b1;
                        if (load_count + 13'd1 == load_limit) begin
                            load_active <= 0;
                            load_done <= 1;
                            if (load_object_reg == 0) begin
                                pk_complete <= 1; pk_mode <= load_mode_reg;
                            end else begin
                                ct_complete <= 1; ct_mode <= load_mode_reg;
                            end
                        end
                    end else if (start) begin
                        operation_reg <= operation;
                        d_latched <= seed_d; z_latched <= seed_z; m_latched <= message_m;
                        secret_valid <= 0;
                        re_encrypt <= 0; outer_index <= 0; inner_index <= 0;
                        key_byte_index <= 0;
                        packed_phase <= 0; private_hash_diff <= 0;
                        mode_reg <= mode_1024;
                        k_reg    <= mode_1024 ? 3'd4 : 3'd3;
                        du_reg   <= mode_1024 ? 4'd11 : 4'd10;
                        dv_reg   <= mode_1024 ? 4'd5 : 4'd4;
                        ek_length <= mode_1024 ? 13'd1568 : 13'd1184;
                        dk_length <= mode_1024 ? 13'd3168 : 13'd2400;
                        ct_length <= mode_1024 ? 13'd1568 : 13'd1088;
                        internal_error <= 1'b0;
                        pass <= 1'b0;
                        fail <= 1'b0;
                        error_code <= 8'd0;
                        cycle_count <= 32'd0;
                        busy  <= 1'b1;
                        stage <= {2'd0, operation};
                        state <= S_DISPATCH;
                    end
                end

                S_DISPATCH: begin
                    if (load_active) begin error_code <= 8'h10; state <= S_FINISH; end
                    else case (operation_reg)
                        2'd1: begin
                            key_ready <= 0; pk_complete <= 0; ct_complete <= 0;
                            state <= KG_HASH_G;
                        end
                        2'd2: begin
                            if (!pk_complete || pk_mode != mode_reg) begin
                                error_code <= 8'h11; state <= S_FINISH;
                            end else begin ct_complete <= 0; state <= P_CHECK_READ; end
                        end
                        2'd3: begin
                            if (!key_ready || key_mode_1024 != mode_reg) begin
                                error_code <= 8'h12; state <= S_FINISH;
                            end else if (!ct_complete || ct_mode != mode_reg) begin
                                error_code <= 8'h13; state <= S_FINISH;
                            end else begin
                                pk_complete <= 0;
                                state <= P_RESTORE_READ;
                            end
                        end
                        default: begin error_code <= 8'h14; state <= S_FINISH; end
                    endcase
                end
                // Decaps phuc hoi EK cua key slot, khong dung EK ngoai cua Encaps.
                P_RESTORE_READ: state <= P_RESTORE_WRITE;
                P_RESTORE_WRITE: begin
                    if (op_last_q) begin
                        packed_phase <= 0;
                        pk_complete <= 1; pk_mode <= mode_reg;
                        state <= P_CHECK_READ;
                    end else begin
`ifdef CONTINUOUS_BANKED_BYTE_STREAM_OPT
                        state <= P_RESTORE_WRITE;
`else
                        state <= P_RESTORE_READ;
`endif
                    end
                end
                // Modulus check tren byte 12-bit TRUOC ByteDecode (codec co modulo).
                P_CHECK_READ: state <= P_CHECK_CAP;
                P_CHECK_CAP: begin
                    if (p_check_invalid) begin
                        error_code <= 8'h22;
                        pk_complete <= 0;
                        state <= S_FINISH;
                    end else begin
                        if (packed_phase == 0) packed_byte0 <= byte_q_a;
                        if (packed_phase == 1) packed_byte1 <= byte_q_a;
                        packed_phase <= (packed_phase == 2'd2) ? 2'd0 : packed_phase + 2'd1;
                        if (op_last_q) begin
                            key_byte_index <= 0; state <= P_RHO_READ;
                        end else begin
`ifdef CONTINUOUS_BANKED_BYTE_STREAM_OPT
                            state <= P_CHECK_CAP;
`else
                            state <= P_CHECK_READ;
`endif
                        end
                    end
                end
                P_RHO_READ: state <= P_RHO_CAP;
                P_RHO_CAP: begin
                    rho_reg <= {byte_q_a,rho_reg[255:8]};
                    if (key_byte_index == 31) begin
                        key_byte_index <= 0; outer_index <= 0;
                        state <= (operation_reg == 3) ? P_Z_READ : P_T_BEGIN;
                    end else begin key_byte_index <= key_byte_index + 1'b1; state <= P_RHO_READ; end
                end
                P_Z_READ: state <= P_Z_CAP;
                P_Z_CAP: begin
                    z_latched <= {byte_q_a,z_latched[255:8]};
                    if (key_byte_index == 31) begin key_byte_index <= 0; state <= P_T_BEGIN; end
                    else begin key_byte_index <= key_byte_index + 1'b1; state <= P_Z_READ; end
                end
                P_T_BEGIN: begin
                    codec_d_reg <= 12; codec_decode_decompress <= 0;
                    codec_byte_base <= EK_BASE + 13'd384 * outer_index;
                    codec_byte_count <= 384; poly_dest_slot <= SLOT_T + outer_index;
                    return_state <= P_T_DONE; state <= G_CODEC_DEC_IN_REQ;
                end
                P_T_DONE: begin
                    if (outer_index + 1'b1 < k_reg) begin
                        outer_index <= outer_index + 1'b1; state <= P_T_BEGIN;
                    end else begin
                        outer_index <= 0;
                        state <= (operation_reg == 3) ? P_S_BEGIN : P_HASH_BEGIN;
                    end
                end
                P_S_BEGIN: begin
                    codec_d_reg <= 12; codec_decode_decompress <= 0;
                    codec_byte_base <= DK_BASE + 13'd384 * outer_index;
                    codec_byte_count <= 384; poly_dest_slot <= SLOT_S + outer_index;
                    return_state <= P_S_DONE; state <= G_CODEC_DEC_IN_REQ;
                end
                P_S_DONE: begin
                    if (outer_index + 1'b1 < k_reg) begin
                        outer_index <= outer_index + 1'b1; state <= P_S_BEGIN;
                    end else begin outer_index <= 0; state <= P_HASH_BEGIN; end
                end
                P_HASH_BEGIN: begin
                    hash_source_reg <= HASH_EK; hash_dest_reg <= DEST_EK_HASH;
                    hash_mode_reg <= 0; hash_input_length <= ek_length[11:0];
                    hash_output_length <= 32;
                    return_state <= P_HASH_DONE; state <= G_HASH_LOAD_READ;
                end
                P_HASH_DONE: begin
                    private_hash_diff <= 0;
                    state <= (operation_reg == 3) ? P_HASH_CHECK_READ : ENC_G_BEGIN;
                end
                P_HASH_CHECK_READ: state <= P_HASH_CHECK_CAP;
                P_HASH_CHECK_CAP: begin
                    private_hash_diff <= private_hash_diff | (byte_q_a ^ hash_ek_q);
                    if (op_last_q) begin
                        outer_index <= 0;
                        state <= P_HASH_CHECK_DONE;
                    end else begin state <= P_HASH_CHECK_READ; end
                end
                S_FINGERPRINT: begin
                    hash_source_reg <= HASH_SECRET; hash_dest_reg <= DEST_FINGERPRINT;
                    hash_mode_reg <= 0; hash_input_length <= 32; hash_output_length <= 32;
                    return_state <= S_FINISH; state <= G_HASH_LOAD_READ;
                end

                // -------- Generic hash operation --------
                P_HASH_CHECK_DONE: begin
                    if (private_hash_diff != 0) begin
                        error_code <= 8'h23; key_ready <= 0; state <= S_FINISH;
                    end else state <= DEC_U_BEGIN;
                end
                G_HASH_LOAD_READ: state <= G_HASH_LOAD_CAPTURE;
                G_HASH_LOAD_CAPTURE: state <= G_HASH_LOAD_WRITE;
                G_HASH_LOAD_WRITE: begin
                    if (op_last_q) begin
                        state <= G_HASH_START;
                    end else begin
`ifdef CONTINUOUS_BANKED_BYTE_STREAM_OPT
                        state <= G_HASH_LOAD_CAPTURE;
`else
                        state <= G_HASH_LOAD_READ;
`endif
                    end
                end
                G_HASH_START: state <= G_HASH_WAIT;
                G_HASH_WAIT: begin
                    if (sponge_done) begin
                        state <= G_HASH_OUT_REQ;
                    end
                end
                G_HASH_OUT_REQ: state <= G_HASH_OUT_PIPE;
                G_HASH_OUT_PIPE: state <= G_HASH_OUT_CAP;
                G_HASH_OUT_CAP: begin
                    case (hash_dest_reg)
                        // Fixed byte shifts replace variable byte write decoders.
                        // After 32 bytes, byte zero is again in bits [7:0].
                        DEST_FINGERPRINT: begin
                            // Public fingerprint shift is isolated in the
                            // dedicated output register block above.
                        end
                        DEST_RHO_SIGMA: begin
                            if (op_index < 13'd32)
                                rho_reg <= {hash_output_q,rho_reg[255:8]};
                            else
                                sigma_reg <= {hash_output_q,sigma_reg[255:8]};
                        end
                        DEST_EK_HASH:
                            ek_hash_reg <= {hash_output_q,ek_hash_reg[255:8]};
                        DEST_ENCAP_K_R: begin
                            if (op_index >= 13'd32)
                                randomness_reg <= {hash_output_q,randomness_reg[255:8]};
                        end
                        DEST_DECAP_K_R: begin
                            if (op_index < 13'd32)
                                key_candidate_reg <= {hash_output_q,key_candidate_reg[255:8]};
                            else
                                randomness_reg <= {hash_output_q,randomness_reg[255:8]};
                        end
                        DEST_FALLBACK:
                            fallback_key_reg <= {hash_output_q,fallback_key_reg[255:8]};
                        default: begin
                        end
                    endcase

                    if (op_last_q) begin
                        state <= return_state;
                    end else begin
`ifdef CONTINUOUS_BANKED_FAST_FRONTEND
                        state <= G_HASH_OUT_CAP;
`else
                        state <= G_HASH_OUT_REQ;
`endif
                    end
                end

                // -------- Generic sampler operation --------
                G_SAMPLE_START: state <= G_SAMPLE_WAIT;
                G_SAMPLE_WAIT: begin
                    if (sampler_done) begin
                        if (sampler_error)
                            internal_error <= 1'b1;
                        state <= G_SAMPLE_OUT_REQ;
                    end
                end
                G_SAMPLE_OUT_REQ: state <= G_SAMPLE_OUT_CAP;
                G_SAMPLE_OUT_CAP: begin
                    if (coefficient_last_q) begin
                        state <= return_state;
                    end else begin
`ifdef CONTINUOUS_BANKED_FAST_FRONTEND
                        state <= G_SAMPLE_OUT_CAP;
`else
                        state <= G_SAMPLE_OUT_REQ;
`endif
                    end
                end

                // -------- Generic NTT/INTT operation --------
                G_NTT_IN_REQ: state <= G_NTT_IN_CAP;
                G_NTT_IN_CAP: begin
                    if (coefficient_last_q) begin
                        state <= G_NTT_START;
                    end else begin
`ifdef CONTINUOUS_BANKED_FAST_FRONTEND
                        state <= G_NTT_IN_CAP;
`else
                        state <= G_NTT_IN_REQ;
`endif
                    end
                end
                G_NTT_START: state <= G_NTT_WAIT;
                G_NTT_WAIT: begin
                    if (ntt_done) begin
                        state <= G_NTT_OUT_REQ;
                    end
                end
                G_NTT_OUT_REQ: state <= G_NTT_OUT_CAP;
                G_NTT_OUT_CAP: begin
                    if (coefficient_last_q) begin
                        state <= return_state;
                    end else begin
`ifdef CONTINUOUS_BANKED_FAST_FRONTEND
                        state <= G_NTT_OUT_CAP;
`else
                        state <= G_NTT_OUT_REQ;
`endif
                    end
                end

                // -------- Generic MultiplyNTTs operation --------
                G_MUL_IN_REQ: state <= G_MUL_IN_CAP;
                G_MUL_IN_CAP: begin
                    if (coefficient_last_q) begin
                        state <= G_MUL_START;
                    end else begin
`ifdef CONTINUOUS_BANKED_FAST_FRONTEND
                        state <= G_MUL_IN_CAP;
`else
                        state <= G_MUL_IN_REQ;
`endif
                    end
                end
                G_MUL_START: state <= G_MUL_WAIT;
                G_MUL_WAIT: begin
                    if (mul_done) begin
                        state <= G_MUL_OUT_REQ;
                    end
                end
                G_MUL_OUT_REQ: state <= G_MUL_OUT_CAP;
                G_MUL_OUT_CAP: begin
                    if (coefficient_last_q) begin
                        state <= return_state;
                    end else begin
`ifdef CONTINUOUS_BANKED_FAST_FRONTEND
                        state <= G_MUL_OUT_CAP;
`else
                        state <= G_MUL_OUT_REQ;
`endif
                    end
                end

                // -------- Generic polynomial operations --------
                G_POLY_ZERO: begin
                    if (coefficient_last_q) begin
                        state <= return_state;
                    end
                end
                G_POLY_READ: state <= G_POLY_CAPTURE;
                G_POLY_CAPTURE: state <= G_POLY_EXECUTE;
`ifdef CONTINUOUS_BANKED_CYCLE_OPT
                G_POLY_EXECUTE: begin
                    if (coefficient_last_q) begin
                        state <= return_state;
                    end else begin
                        state <= G_POLY_READ;
                    end
                end
`else
                G_POLY_EXECUTE: state <= G_POLY_WRITE;
                G_POLY_WRITE: begin
                    if (coefficient_last_q) begin
                        state <= return_state;
                    end else begin
                        state <= G_POLY_READ;
                    end
                end
`endif
                G_TRANS_READ: state <= G_TRANS_INPUT_CAPTURE;
                G_TRANS_INPUT_CAPTURE: begin
                    transform_input_reg <= poly_q_a;
                    state <= G_TRANS_CALCULATE;
                end
                G_TRANS_CALCULATE: state <= G_TRANS_WAIT;
                G_TRANS_WAIT: if(transform_done) begin
                    transform_result_reg <= transform_output;
                    state <= G_TRANS_WRITE;
                end
                G_TRANS_WRITE: begin
                    if (!transform_valid)
                        internal_error <= 1'b1;
                    if (coefficient_last_q) begin
                        state <= return_state;
                    end else begin
                        state <= G_TRANS_READ;
                    end
                end

                // -------- Generic ByteEncode --------
                G_CODEC_ENC_IN_REQ: state <= G_CODEC_ENC_IN_CAP;
                G_CODEC_ENC_IN_CAP: begin
                    if (coefficient_last_q) begin
                        state <= G_CODEC_ENC_START;
                    end else begin
`ifdef CONTINUOUS_BANKED_FAST_FRONTEND
                        state <= G_CODEC_ENC_IN_CAP;
`else
                        state <= G_CODEC_ENC_IN_REQ;
`endif
                    end
                end
                G_CODEC_ENC_START: state <= G_CODEC_ENC_WAIT;
                G_CODEC_ENC_WAIT: begin
                    if (codec_done) begin
                        if (codec_invalid_d)
                            internal_error <= 1'b1;
                        state <= G_CODEC_ENC_OUT_REQ;
                    end
                end
                G_CODEC_ENC_OUT_REQ: state <= G_CODEC_ENC_OUT_CAP;
                G_CODEC_ENC_OUT_CAP: begin
                    if (op_last_q) begin
                        state <= return_state;
                    end else begin
`ifdef CONTINUOUS_BANKED_FAST_FRONTEND
                        state <= G_CODEC_ENC_OUT_CAP;
`else
                        state <= G_CODEC_ENC_OUT_REQ;
`endif
                    end
                end

                // -------- Generic ByteDecode --------
                G_CODEC_DEC_IN_REQ: state <= G_CODEC_DEC_IN_CAP;
                G_CODEC_DEC_IN_CAP: begin
                    if (op_last_q) begin
                        state <= G_CODEC_DEC_START;
                    end else begin
`ifdef CONTINUOUS_BANKED_FAST_FRONTEND
                        state <= G_CODEC_DEC_IN_CAP;
`else
                        state <= G_CODEC_DEC_IN_REQ;
`endif
                    end
                end
                G_CODEC_DEC_START: state <= G_CODEC_DEC_WAIT;
                G_CODEC_DEC_WAIT: begin
                    if (codec_done) begin
                        if (codec_invalid_d)
                            internal_error <= 1'b1;
                        state <= G_CODEC_DEC_OUT_REQ;
                    end
                end
                G_CODEC_DEC_OUT_REQ: state <= G_CODEC_DEC_OUT_CAP;
                G_CODEC_DEC_OUT_CAP: begin
                    transform_input_reg <= codec_read_coefficient_data;
                    if (codec_decode_decompress)
                        state <= G_CODEC_DEC_OUT_CALCULATE;
                    else begin
                        transform_result_reg <= codec_read_coefficient_data;
                        state <= G_CODEC_DEC_OUT_WRITE;
                    end
                end
                G_CODEC_DEC_OUT_CALCULATE: state <= G_CODEC_DEC_OUT_WAIT;
                G_CODEC_DEC_OUT_WAIT: if(transform_done) begin
                    transform_result_reg <= transform_output;
                    state <= G_CODEC_DEC_OUT_WRITE;
                end
                G_CODEC_DEC_OUT_WRITE: begin
                    if (coefficient_last_q) begin
                        state <= return_state;
                    end else begin
                        state <= G_CODEC_DEC_OUT_REQ;
                    end
                end

                // -------- Decode message from polynomial W --------
                G_MESSAGE_READ: state <= G_MESSAGE_INPUT_CAPTURE;
                G_MESSAGE_INPUT_CAPTURE: begin
                    transform_input_reg <= poly_q_a;
                    state <= G_MESSAGE_CALCULATE;
                end
                G_MESSAGE_CALCULATE: state <= G_MESSAGE_WAIT;
                G_MESSAGE_WAIT: if(transform_done) begin
                    transform_result_reg <= transform_output;
                    state <= G_MESSAGE_WRITE;
                end
                G_MESSAGE_WRITE: begin
                    if (transform_result_reg[0])
                        message_byte_accum[message_bit_index] <= 1'b1;
                    else
                        message_byte_accum[message_bit_index] <= 1'b0;

                    if (message_bit_index == 3'd7) begin
                        message_prime_reg[8 * coefficient_index[7:3] +: 8] <=
                            {transform_result_reg[0], message_byte_accum[6:0]};
                        message_byte_accum <= 8'd0;
                        message_bit_index  <= 3'd0;
                    end else begin
                        message_bit_index <= message_bit_index + 3'd1;
                    end

                    if (coefficient_last_q) begin
                        state <= return_state;
                    end else begin
                        state <= G_MESSAGE_READ;
                    end
                end

                // ==================== KEY GENERATION ====================
                KG_HASH_G: begin
                    hash_source_reg    <= HASH_D_K;
                    hash_dest_reg      <= DEST_RHO_SIGMA;
                    hash_mode_reg      <= 2'd1;
                    hash_input_length  <= 12'd33;
                    hash_output_length <= 11'd64;
                    return_state       <= KG_G_DONE;
                    state              <= G_HASH_LOAD_READ;
                end
                KG_G_DONE: begin
                    outer_index <= 3'd0;
                    nonce_reg   <= 8'd0;
                    hash_source_reg    <= HASH_SIGMA_N;
                    hash_dest_reg      <= DEST_SAMPLER;
                    hash_mode_reg      <= 2'd3;
                    hash_input_length  <= 12'd33;
                    hash_output_length <= 11'd128;
                    return_state       <= KG_S_HASH_DONE;
                    state              <= G_HASH_LOAD_READ;
                end
                KG_S_HASH_DONE: begin
                    sampler_cbd_reg     <= 1'b1;
                    poly_dest_slot      <= SLOT_TEMP;
                    return_state        <= KG_S_SAMPLE_DONE;
                    state               <= G_SAMPLE_START;
                end
                KG_S_SAMPLE_DONE: begin
                    poly_src_a_slot <= SLOT_TEMP;
                    poly_dest_slot  <= SLOT_S + outer_index;
                    ntt_inverse_reg <= 1'b0;
                    return_state <= KG_S_NTT_DONE;
                    state <= G_NTT_IN_REQ;
                end
                KG_S_NTT_DONE: begin
                    if ((outer_index + 3'd1) < k_reg) begin
                        outer_index <= outer_index + 3'd1;
                        nonce_reg   <= nonce_reg + 8'd1;
                        hash_source_reg    <= HASH_SIGMA_N;
                        hash_dest_reg      <= DEST_SAMPLER;
                        hash_mode_reg      <= 2'd3;
                        hash_input_length  <= 12'd33;
                        hash_output_length <= 11'd128;
                        return_state       <= KG_S_HASH_DONE;
                        state              <= G_HASH_LOAD_READ;
                    end else begin
                        outer_index <= 3'd0;
                        inner_index <= 3'd0;
                        poly_dest_slot <= SLOT_ACC;
                        return_state <= KG_ROW_BEGIN;
                        state <= G_POLY_ZERO;
                    end
                end
                KG_ROW_BEGIN: begin
                    matrix_transpose  <= 1'b0;
                    hash_source_reg    <= HASH_RHO_I_J;
                    hash_dest_reg      <= DEST_SAMPLER;
                    hash_mode_reg      <= 2'd2;
                    hash_input_length  <= 12'd34;
                    hash_output_length <= 11'd840;
                    return_state       <= KG_MATRIX_HASH_DONE;
                    state              <= G_HASH_LOAD_READ;
                end
                KG_MATRIX_HASH_DONE: begin
                    sampler_cbd_reg <= 1'b0;
                    poly_dest_slot  <= SLOT_TEMP;
                    return_state    <= KG_MATRIX_SAMPLE_DONE;
                    state           <= G_SAMPLE_START;
                end
                KG_MATRIX_SAMPLE_DONE: begin
                    poly_src_a_slot <= SLOT_TEMP;
                    poly_src_b_slot <= SLOT_S + inner_index;
                    poly_dest_slot  <= SLOT_PROD;
                    return_state <= KG_MATRIX_MUL_DONE;
                    state <= G_MUL_IN_REQ;
                end
                KG_MATRIX_MUL_DONE: begin
                    poly_src_a_slot <= SLOT_ACC;
                    poly_src_b_slot <= SLOT_PROD;
                    poly_dest_slot  <= SLOT_ACC;
                    poly_subtract   <= 1'b0;
                    return_state <= KG_MATRIX_ADD_DONE;
                    state <= G_POLY_READ;
                end
                KG_MATRIX_ADD_DONE: begin
                    if ((inner_index + 3'd1) < k_reg) begin
                        inner_index <= inner_index + 3'd1;
                        state <= KG_ROW_BEGIN;
                    end else begin
                        nonce_reg <= {5'd0, k_reg} + {5'd0, outer_index};
                        hash_source_reg    <= HASH_SIGMA_N;
                        hash_dest_reg      <= DEST_SAMPLER;
                        hash_mode_reg      <= 2'd3;
                        hash_input_length  <= 12'd33;
                        hash_output_length <= 11'd128;
                        return_state       <= KG_E_HASH_DONE;
                        state              <= G_HASH_LOAD_READ;
                    end
                end
                KG_E_HASH_DONE: begin
                    sampler_cbd_reg <= 1'b1;
                    poly_dest_slot  <= SLOT_E;
                    return_state    <= KG_E_SAMPLE_DONE;
                    state           <= G_SAMPLE_START;
                end
                KG_E_SAMPLE_DONE: begin
                    poly_src_a_slot <= SLOT_E;
                    poly_dest_slot  <= SLOT_E;
                    ntt_inverse_reg <= 1'b0;
                    return_state <= KG_E_NTT_DONE;
                    state <= G_NTT_IN_REQ;
                end
                KG_E_NTT_DONE: begin
                    poly_src_a_slot <= SLOT_ACC;
                    poly_src_b_slot <= SLOT_E;
                    poly_dest_slot  <= SLOT_T + outer_index;
                    poly_subtract   <= 1'b0;
                    return_state <= KG_T_ADD_DONE;
                    state <= G_POLY_READ;
                end
                KG_T_ADD_DONE: begin
                    if ((outer_index + 3'd1) < k_reg) begin
                        outer_index <= outer_index + 3'd1;
                        inner_index <= 3'd0;
                        poly_dest_slot <= SLOT_ACC;
                        return_state <= KG_ROW_BEGIN;
                        state <= G_POLY_ZERO;
                    end else begin
                        outer_index <= 3'd0;
                        state <= KG_PACK_T_BEGIN;
                    end
                end
                KG_PACK_T_BEGIN: begin
                    poly_src_a_slot <= SLOT_T + outer_index;
                    codec_d_reg     <= 4'd12;
                    codec_byte_base <= EK_BASE + 13'd384 * outer_index;
                    codec_byte_count <= 9'd384;
                    return_state <= KG_PACK_T_DONE;
                    state <= G_CODEC_ENC_IN_REQ;
                end
                KG_PACK_T_DONE: begin
                    if ((outer_index + 3'd1) < k_reg) begin
                        outer_index <= outer_index + 3'd1;
                        state <= KG_PACK_T_BEGIN;
                    end else begin
                        key_byte_index <= 5'd0;
                        state <= KG_RHO_COPY;
                    end
                end
                KG_RHO_COPY: begin
                    // Destructive stream is safe here: rho has already served
                    // every matrix/XOF operation and is reloaded from EK before
                    // a later encapsulation or decapsulation operation.
                    rho_reg <= {8'd0,rho_reg[255:8]};
                    if (key_byte_index == 5'd31) begin
                        outer_index <= 3'd0;
                        key_byte_index <= 5'd0;
                        state <= KG_PACK_S_BEGIN;
                    end else
                        key_byte_index <= key_byte_index + 5'd1;
                end
                KG_PACK_S_BEGIN: begin
                    poly_src_a_slot <= SLOT_S + outer_index;
                    codec_d_reg     <= 4'd12;
                    codec_byte_base <= DK_BASE + 13'd384 * outer_index;
                    codec_byte_count <= 9'd384;
                    return_state <= KG_PACK_S_DONE;
                    state <= G_CODEC_ENC_IN_REQ;
                end
                KG_PACK_S_DONE: begin
                    if ((outer_index + 3'd1) < k_reg) begin
                        outer_index <= outer_index + 3'd1;
                        state <= KG_PACK_S_BEGIN;
                    end else begin
                        state <= KG_COPY_EK_READ;
                    end
                end
                KG_COPY_EK_READ: state <= KG_COPY_EK_WRITE;
                KG_COPY_EK_WRITE: begin
                    if (op_last_q) begin
                        hash_source_reg    <= HASH_EK;
                        hash_dest_reg      <= DEST_EK_HASH;
                        hash_mode_reg      <= 2'd0;
                        hash_input_length  <= ek_length[11:0];
                        hash_output_length <= 11'd32;
                        return_state       <= KG_HASH_EK_DONE;
                        state              <= G_HASH_LOAD_READ;
                    end else begin
`ifdef CONTINUOUS_BANKED_BYTE_STREAM_OPT
                        state <= KG_COPY_EK_WRITE;
`else
                        state <= KG_COPY_EK_READ;
`endif
                    end
                end
                KG_HASH_EK_DONE: begin
                    key_byte_index <= 5'd0;
                    state <= KG_COPY_HASH;
                end
                KG_COPY_HASH: begin
                    // The hash and z halves use separate states so neither the
                    // phase counter nor a variable byte selector reaches the
                    // synchronous RAM data input.
                    ek_hash_reg <= {8'd0,ek_hash_reg[255:8]};
                    if (key_byte_index == 5'd31) begin
                        key_byte_index <= 5'd0;
                        state <= KG_COPY_Z;
                    end else
                        key_byte_index <= key_byte_index + 5'd1;
                end
                KG_COPY_Z: begin
                    z_latched <= {8'd0,z_latched[255:8]};
                    if (key_byte_index == 5'd31) begin
                        key_byte_index <= 5'd0;
                        key_ready <= !internal_error;
                        key_mode_1024 <= mode_reg;
                        pk_complete <= !internal_error; pk_mode <= mode_reg;
                        state <= S_FINISH;
                    end else
                        key_byte_index <= key_byte_index + 5'd1;
                end

                // ==================== ENCAPS / RE-ENCRYPT ====================
                ENC_G_BEGIN: begin
                    re_encrypt <= 1'b0;
                    hash_use_prime <= 1'b0;
                    hash_source_reg    <= HASH_M_EKH;
                    hash_dest_reg      <= DEST_ENCAP_K_R;
                    hash_mode_reg      <= 2'd1;
                    hash_input_length  <= 12'd64;
                    hash_output_length <= 11'd64;
                    return_state       <= ENC_G_DONE;
                    state              <= G_HASH_LOAD_READ;
                end
                ENC_G_DONE: begin
                    outer_index <= 3'd0;
                    nonce_reg   <= 8'd0;
                    hash_source_reg    <= HASH_SIGMA_N;
                    hash_dest_reg      <= DEST_SAMPLER;
                    hash_mode_reg      <= 2'd3;
                    hash_input_length  <= 12'd33;
                    hash_output_length <= 11'd128;
                    return_state       <= ENC_Y_HASH_DONE;
                    state              <= G_HASH_LOAD_READ;
                    // PRF source trong giai do encrypt la randomness, doi tam sigma.
                    sigma_reg <= randomness_reg;
                end
                ENC_Y_HASH_DONE: begin
                    sampler_cbd_reg <= 1'b1;
                    poly_dest_slot  <= SLOT_TEMP;
                    return_state    <= ENC_Y_SAMPLE_DONE;
                    state           <= G_SAMPLE_START;
                end
                ENC_Y_SAMPLE_DONE: begin
                    poly_src_a_slot <= SLOT_TEMP;
                    poly_dest_slot  <= SLOT_Y + outer_index;
                    ntt_inverse_reg <= 1'b0;
                    return_state <= ENC_Y_NTT_DONE;
                    state <= G_NTT_IN_REQ;
                end
                ENC_Y_NTT_DONE: begin
                    if ((outer_index + 3'd1) < k_reg) begin
                        outer_index <= outer_index + 3'd1;
                        nonce_reg   <= nonce_reg + 8'd1;
                        hash_source_reg    <= HASH_SIGMA_N;
                        hash_dest_reg      <= DEST_SAMPLER;
                        hash_mode_reg      <= 2'd3;
                        hash_input_length  <= 12'd33;
                        hash_output_length <= 11'd128;
                        return_state       <= ENC_Y_HASH_DONE;
                        state              <= G_HASH_LOAD_READ;
                    end else begin
                        outer_index <= 3'd0;
                        state <= ENC_U_BEGIN;
                    end
                end
                ENC_U_BEGIN: begin
                    inner_index <= 3'd0;
                    poly_dest_slot <= SLOT_ACC;
                    return_state <= ENC_U_ZERO_DONE;
                    state <= G_POLY_ZERO;
                end
                ENC_U_ZERO_DONE: begin
                    matrix_transpose  <= 1'b1;
                    hash_source_reg    <= HASH_RHO_I_J;
                    hash_dest_reg      <= DEST_SAMPLER;
                    hash_mode_reg      <= 2'd2;
                    hash_input_length  <= 12'd34;
                    hash_output_length <= 11'd840;
                    return_state       <= ENC_U_MATRIX_HASH_DONE;
                    state              <= G_HASH_LOAD_READ;
                end
                ENC_U_MATRIX_ADD_DONE: begin
                    if ((inner_index + 3'd1) < k_reg) begin
                        inner_index <= inner_index + 3'd1;
                        hash_source_reg    <= HASH_RHO_I_J;
                        hash_dest_reg      <= DEST_SAMPLER;
                        hash_mode_reg      <= 2'd2;
                        hash_input_length  <= 12'd34;
                        hash_output_length <= 11'd840;
                        return_state       <= ENC_U_MATRIX_HASH_DONE;
                        state              <= G_HASH_LOAD_READ;
                    end else begin
                        poly_src_a_slot <= SLOT_ACC;
                        poly_dest_slot  <= SLOT_U + outer_index;
                        ntt_inverse_reg <= 1'b1;
                        return_state <= ENC_U_INTT_DONE;
                        state <= G_NTT_IN_REQ;
                    end
                end
                ENC_U_MATRIX_HASH_DONE: begin
                    sampler_cbd_reg <= 1'b0;
                    poly_dest_slot  <= SLOT_TEMP;
                    return_state <= ENC_U_MATRIX_SAMPLE_DONE;
                    state <= G_SAMPLE_START;
                end
                ENC_U_MATRIX_SAMPLE_DONE: begin
                    // A^T[col,row] = A[row,col], SampleNTT(rho || col || row).
                    poly_src_a_slot <= SLOT_TEMP;
                    poly_src_b_slot <= SLOT_Y + inner_index;
                    poly_dest_slot  <= SLOT_PROD;
                    return_state <= ENC_U_MATRIX_MUL_DONE;
                    state <= G_MUL_IN_REQ;
                end
                ENC_U_MATRIX_MUL_DONE: begin
                    poly_src_a_slot <= SLOT_ACC;
                    poly_src_b_slot <= SLOT_PROD;
                    poly_dest_slot  <= SLOT_ACC;
                    poly_subtract   <= 1'b0;
                    return_state <= ENC_U_MATRIX_ADD_DONE;
                    state <= G_POLY_READ;
                end
                ENC_U_INTT_DONE: begin
                    nonce_reg <= {5'd0, k_reg} + {5'd0, outer_index};
                    hash_source_reg    <= HASH_SIGMA_N;
                    hash_dest_reg      <= DEST_SAMPLER;
                    hash_mode_reg      <= 2'd3;
                    hash_input_length  <= 12'd33;
                    hash_output_length <= 11'd128;
                    return_state       <= ENC_E1_HASH_DONE;
                    state              <= G_HASH_LOAD_READ;
                end
                ENC_E1_HASH_DONE: begin
                    sampler_cbd_reg <= 1'b1;
                    poly_dest_slot  <= SLOT_E;
                    return_state <= ENC_E1_SAMPLE_DONE;
                    state <= G_SAMPLE_START;
                end
                ENC_E1_SAMPLE_DONE: begin
                    poly_src_a_slot <= SLOT_U + outer_index;
                    poly_src_b_slot <= SLOT_E;
                    poly_dest_slot  <= SLOT_U + outer_index;
                    poly_subtract   <= 1'b0;
                    return_state <= ENC_U_E1_ADD_DONE;
                    state <= G_POLY_READ;
                end
                ENC_U_E1_ADD_DONE: begin
                    poly_src_a_slot   <= SLOT_U + outer_index;
                    poly_dest_slot    <= SLOT_PACK;
                    transform_d       <= du_reg;
                    transform_compress <= 1'b1;
                    return_state <= ENC_U_COMPRESS_DONE;
                    state <= G_TRANS_READ;
                end
                ENC_U_COMPRESS_DONE: begin
                    poly_src_a_slot <= SLOT_PACK;
                    codec_d_reg     <= du_reg;
                    codec_byte_base <= u_codec_address(re_encrypt,mode_reg,outer_index[1:0]);
                    codec_byte_count <= 9'd32 * du_reg;
                    return_state <= ENC_U_PACK_DONE;
                    state <= G_CODEC_ENC_IN_REQ;
                end
                ENC_U_PACK_DONE: begin
                    if ((outer_index + 3'd1) < k_reg) begin
                        outer_index <= outer_index + 3'd1;
                        state <= ENC_U_BEGIN;
                    end else begin
                        state <= ENC_V_BEGIN;
                    end
                end
                ENC_V_BEGIN: begin
                    inner_index <= 3'd0;
                    poly_dest_slot <= SLOT_ACC;
                    return_state <= ENC_V_ZERO_DONE;
                    state <= G_POLY_ZERO;
                end
                ENC_V_ZERO_DONE: begin
                    poly_src_a_slot <= SLOT_T;
                    poly_src_b_slot <= SLOT_Y;
                    poly_dest_slot  <= SLOT_PROD;
                    return_state <= ENC_V_MUL_DONE;
                    state <= G_MUL_IN_REQ;
                end
                ENC_V_ADD_DONE: begin
                    if ((inner_index + 3'd1) < k_reg) begin
                        inner_index <= inner_index + 3'd1;
                        poly_src_a_slot <= SLOT_T + inner_index + 3'd1;
                        poly_src_b_slot <= SLOT_Y + inner_index + 3'd1;
                        poly_dest_slot  <= SLOT_PROD;
                        return_state <= ENC_V_MUL_DONE;
                        state <= G_MUL_IN_REQ;
                    end else begin
                        poly_src_a_slot <= SLOT_ACC;
                        poly_dest_slot  <= SLOT_V;
                        ntt_inverse_reg <= 1'b1;
                        return_state <= ENC_V_INTT_DONE;
                        state <= G_NTT_IN_REQ;
                    end
                end
                ENC_V_MUL_DONE: begin
                    poly_src_a_slot <= SLOT_ACC;
                    poly_src_b_slot <= SLOT_PROD;
                    poly_dest_slot  <= SLOT_ACC;
                    poly_subtract   <= 1'b0;
                    return_state <= ENC_V_ADD_DONE;
                    state <= G_POLY_READ;
                end
                ENC_V_INTT_DONE: begin
                    nonce_reg <= {4'd0, k_reg, 1'b0};
                    hash_source_reg    <= HASH_SIGMA_N;
                    hash_dest_reg      <= DEST_SAMPLER;
                    hash_mode_reg      <= 2'd3;
                    hash_input_length  <= 12'd33;
                    hash_output_length <= 11'd128;
                    return_state       <= ENC_E2_HASH_DONE;
                    state              <= G_HASH_LOAD_READ;
                end
                ENC_E2_HASH_DONE: begin
                    sampler_cbd_reg <= 1'b1;
                    poly_dest_slot  <= SLOT_E;
                    return_state <= ENC_E2_SAMPLE_DONE;
                    state <= G_SAMPLE_START;
                end
                ENC_E2_SAMPLE_DONE: begin
                    poly_src_a_slot <= SLOT_V;
                    poly_src_b_slot <= SLOT_E;
                    poly_dest_slot  <= SLOT_V;
                    poly_subtract   <= 1'b0;
                    return_state <= ENC_V_E2_ADD_DONE;
                    state <= G_POLY_READ;
                end
                ENC_V_E2_ADD_DONE: begin
                    return_state <= ENC_V_MU_ADD_DONE;
                    state <= ENC_MU_DONE;
                end
                ENC_MU_DONE: begin
                    if (coefficient_last_q) begin
                        poly_src_a_slot <= SLOT_V;
                        poly_src_b_slot <= SLOT_MU;
                        poly_dest_slot  <= SLOT_V;
                        poly_subtract   <= 1'b0;
                        return_state <= ENC_V_MU_ADD_DONE;
                        state <= G_POLY_READ;
                    end
                end
                ENC_V_MU_ADD_DONE: begin
                    poly_src_a_slot    <= SLOT_V;
                    poly_dest_slot     <= SLOT_PACK;
                    transform_d        <= dv_reg;
                    transform_compress <= 1'b1;
                    return_state <= ENC_V_COMPRESS_DONE;
                    state <= G_TRANS_READ;
                end
                ENC_V_COMPRESS_DONE: begin
                    poly_src_a_slot <= SLOT_PACK;
                    codec_d_reg     <= dv_reg;
                    codec_byte_base <= re_encrypt ?
                        (mode_reg ? 13'd7808 : 13'd7360) :
                        (mode_reg ? 13'd6208 : 13'd5760);
                    codec_byte_count <= 9'd32 * dv_reg;
                    return_state <= ENC_V_PACK_DONE;
                    state <= G_CODEC_ENC_IN_REQ;
                end
                ENC_V_PACK_DONE: begin
                    if (re_encrypt) begin
                        cipher_diff <= 8'd0;
                        state <= DEC_COMPARE_READ;
                    end else if (internal_error) begin
                        ct_complete          <= 1'b0;
                        state                <= S_FINISH;
                    end else begin
                        ct_complete <= 1'b1; ct_mode <= mode_reg;
                        state <= S_FINGERPRINT;
                    end
                end

                // ==================== DECAPSULATION ====================
                DEC_U_BEGIN: begin
                    codec_d_reg       <= du_reg;
                    codec_byte_base   <= u_codec_address(1'b0,mode_reg,outer_index[1:0]);
                    codec_byte_count  <= 9'd32 * du_reg;
                    codec_decode_decompress <= 1'b1;
                    transform_d       <= du_reg;
                    poly_dest_slot    <= SLOT_U + outer_index;
                    return_state      <= DEC_U_DECODE_DONE;
                    state             <= G_CODEC_DEC_IN_REQ;
                end
                DEC_U_DECODE_DONE: begin
                    poly_src_a_slot <= SLOT_U + outer_index;
                    poly_dest_slot  <= SLOT_U + outer_index;
                    ntt_inverse_reg <= 1'b0;
                    return_state <= DEC_U_NTT_DONE;
                    state <= G_NTT_IN_REQ;
                end
                DEC_U_NTT_DONE: begin
                    if ((outer_index + 3'd1) < k_reg) begin
                        outer_index <= outer_index + 3'd1;
                        state <= DEC_U_BEGIN;
                    end else begin
                        codec_d_reg       <= dv_reg;
                        codec_byte_base   <= mode_reg ? 13'd6208 : 13'd5760;
                        codec_byte_count  <= 9'd32 * dv_reg;
                        codec_decode_decompress <= 1'b1;
                        transform_d       <= dv_reg;
                        poly_dest_slot    <= SLOT_V;
                        return_state      <= DEC_V_DECODE_DONE;
                        state             <= G_CODEC_DEC_IN_REQ;
                    end
                end
                DEC_V_DECODE_DONE: begin
                    inner_index <= 3'd0;
                    poly_dest_slot <= SLOT_ACC;
                    return_state <= DEC_ACC_BEGIN;
                    state <= G_POLY_ZERO;
                end
                DEC_ACC_BEGIN: begin
                    poly_src_a_slot <= SLOT_S + inner_index;
                    poly_src_b_slot <= SLOT_U + inner_index;
                    poly_dest_slot  <= SLOT_PROD;
                    return_state <= DEC_MUL_DONE;
                    state <= G_MUL_IN_REQ;
                end
                DEC_MUL_DONE: begin
                    poly_src_a_slot <= SLOT_ACC;
                    poly_src_b_slot <= SLOT_PROD;
                    poly_dest_slot  <= SLOT_ACC;
                    poly_subtract   <= 1'b0;
                    return_state <= DEC_ADD_DONE;
                    state <= G_POLY_READ;
                end
                DEC_ADD_DONE: begin
                    if ((inner_index + 3'd1) < k_reg) begin
                        inner_index <= inner_index + 3'd1;
                        state <= DEC_ACC_BEGIN;
                    end else begin
                        poly_src_a_slot <= SLOT_ACC;
                        poly_dest_slot  <= SLOT_TEMP;
                        ntt_inverse_reg <= 1'b1;
                        return_state <= DEC_INTT_DONE;
                        state <= G_NTT_IN_REQ;
                    end
                end
                DEC_INTT_DONE: begin
                    poly_src_a_slot <= SLOT_V;
                    poly_src_b_slot <= SLOT_TEMP;
                    poly_dest_slot  <= SLOT_W;
                    poly_subtract   <= 1'b1;
                    return_state <= DEC_W_DONE;
                    state <= G_POLY_READ;
                end
                DEC_W_DONE: begin
                    transform_d       <= 4'd1;
                    transform_compress <= 1'b1;
                    poly_src_a_slot   <= SLOT_W;
                    message_byte_accum <= 8'd0;
                    message_bit_index  <= 3'd0;
                    return_state <= DEC_MESSAGE_DONE;
                    state <= G_MESSAGE_READ;
                end
                DEC_MESSAGE_DONE: begin
                    hash_use_prime       <= 1'b1;
                    hash_source_reg      <= HASH_M_EKH;
                    hash_dest_reg        <= DEST_DECAP_K_R;
                    hash_mode_reg        <= 2'd1;
                    hash_input_length    <= 12'd64;
                    hash_output_length   <= 11'd64;
                    return_state         <= DEC_G_DONE;
                    state                <= G_HASH_LOAD_READ;
                end
                DEC_G_DONE: begin
                    hash_source_reg      <= HASH_Z_CT;
                    hash_dest_reg        <= DEST_FALLBACK;
                    hash_mode_reg        <= 2'd3;
                    hash_input_length    <= 12'd32 + ct_length[11:0];
                    hash_output_length   <= 11'd32;
                    return_state         <= DEC_J_DONE;
                    state                <= G_HASH_LOAD_READ;
                end
                DEC_J_DONE: begin
                    // Re-encrypt bang m' va r' de kiem tra ciphertext.
                    stage <= 4'd3;
                    re_encrypt <= 1'b1;
                    sigma_reg <= randomness_reg;
                    outer_index <= 3'd0;
                    nonce_reg <= 8'd0;
                    hash_source_reg    <= HASH_SIGMA_N;
                    hash_dest_reg      <= DEST_SAMPLER;
                    hash_mode_reg      <= 2'd3;
                    hash_input_length  <= 12'd33;
                    hash_output_length <= 11'd128;
                    return_state       <= ENC_Y_HASH_DONE;
                    state              <= G_HASH_LOAD_READ;
                end

                DEC_COMPARE_READ: state <= DEC_COMPARE_WRITE;
                DEC_COMPARE_WRITE: begin
                    cipher_diff <= cipher_diff | current_cipher_difference;
                    if (op_last_q) begin
                        state <= DEC_SELECT_PREP;
                    end else begin
`ifdef CONTINUOUS_BANKED_BYTE_STREAM_OPT
                        state <= DEC_COMPARE_WRITE;
`else
                        state <= DEC_COMPARE_READ;
`endif
                    end
                end
                DEC_SELECT_PREP: state <= DEC_SELECT_SECRET;
                DEC_SELECT_SECRET: begin
                    // Cung duong dieu khien/so chu ky cho ciphertext dung va bi sua.
                    if (internal_error || (error_code != 0)) begin
                        state                <= S_FINISH;
                    end else begin
                        state                <= S_FINGERPRINT;
                    end
                end
                S_ZEROIZE: begin
                    if (op_last_q) begin
                        busy                  <= 1'b0;
                        stage                 <= 4'd0;
                        cycle_count           <= 32'd0;
                        pass                  <= 1'b0;
                        fail                  <= 1'b0;
                        error_code            <= 8'd0;
                        zeroize_done          <= 1'b1;
                        state                 <= S_IDLE;
                    end
                end

                S_FINISH: begin
                    busy <= 0; done <= 1;
                    pass <= !internal_error && (error_code == 0);
                    fail <= internal_error || (error_code != 0);
                    if (internal_error && error_code == 0) error_code <= 8'h30;
                    secret_valid <= !internal_error && (error_code == 0) && (operation_reg != 1);
                    d_latched <= 0; z_latched <= 0; m_latched <= 0;
                    key_byte_index <= 0;
                    sigma_reg <= 0; randomness_reg <= 0; message_prime_reg <= 0;
                    key_candidate_reg <= 0; fallback_key_reg <= 0;
                    stage <= 5; state <= S_IDLE;
                end

                default: begin
                    busy <= 1'b0;
                    fail <= 1'b1;
                    error_code <= 8'hff;
                    state <= S_IDLE;
                end
            endcase
        end
    end

endmodule
