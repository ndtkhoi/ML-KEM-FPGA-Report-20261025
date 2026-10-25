// Giao thuc ASCII cho 3 phep toan doc lap. Chi mot request tai mot thoi diem.
// !<K/E/D/Z><7/1><0/1><LLLL><payload hex><CRC32 8 hex> LF
// CRC-32/ISO-HDLC tren TAT CA ky tu ASCII tu opcode den het payload.
// source=0: seed tu PC (test), source=1: nguon FPGA (K/E). D/Z dung source=0.
// K: 64 byte d||z (src0), 0 byte (src1).
// E: EK||m (src0), EK (src1). D: ciphertext. Z: 0 byte.
// Chi xuat EK, CT va SHA3-256(K); KHONG xuat DK hay shared secret tho.
// Both the iterative timing build and cycle-opt V2 isolate the wide
// fingerprint buffer from the parser FSM.  Keep the local alias confined to
// this module so the V2 project does not enable unrelated baseline changes.
`ifdef ITERATIVE_BASELINE_TIMING_FIX
`define CHANNEL_KEM_LOCAL_FP_CLEAR
`elsif CONTINUOUS_BANKED_V2_TIMING_FIX
`define CHANNEL_KEM_LOCAL_FP_CLEAR
`endif
// KEY1 variant: local K/E/D self-test plus the unchanged host protocol.
module channel_kem_uart_keydemo #(
    parameter integer RX_TIMEOUT_CYCLES = 100_000_000,
    parameter integer RNG_TIMEOUT_CYCLES = 150_000_000,
    // The video-demo project sets this to 1 so physical SW0 is authoritative.
    parameter integer MODE_FROM_SWITCH = 0
) (
    input logic clk, rst_n,
    input logic rx_valid,
    input logic [7:0] rx_data,
    input logic rx_error,
    output logic tx_valid,
    output logic [7:0] tx_data,
    input logic tx_ready,
    input logic rng_ready, rng_done, rng_alarm, rng_health,
    input logic [255:0] rng_d, rng_z, rng_m,
    output logic rng_generate, rng_zeroize,
    output logic service_busy, key_ready, op_done, op_pass,
    output logic [7:0] last_error,
    output logic [1:0] last_operation,
    output logic last_mode,
    output logic [3:0] stage,
    output logic [31:0] last_cycles,
    input logic board_mode_1024,
    input logic board_start,
    output logic [23:0] display_code,
    output wire channel_clear, channel_key_valid, channel_key_mode, channel_key_encaps,
    output wire [255:0] channel_key
);
    typedef enum logic [5:0] {
        IDLE, RX_OP, RX_MODE, RX_SOURCE, RX_LENGTH, RX_PAYLOAD, RX_CRC, RX_EOL,
        DISCARD, VALIDATE, SEED_READ, SEED_CAP, RNG_READY, RNG_WAIT,
        LOAD_BEGIN, LOAD_READ, LOAD_CAP, LAUNCH_GAP, LAUNCH, WAIT_CORE,
        WIPE_START, WIPE_WAIT, REPORT_BEGIN, SEND, GAP, SCRUB_FRAME,
        DEMO_NEXT, DEMO_CHECK, DECIMAL_INIT, DECIMAL_SHIFT
    } state_t;
    // The binary state bit state[2] was the source of the remaining UART/KEM
    // setup violations.  One-hot encoding turns the wide state comparisons
    // below into local single-bit enables.
    (* syn_encoding = "onehot" *) state_t state;
    wire parser_active;
    logic [7:0] frame_mem [0:1599];
    logic [10:0] frame_index;
    logic [7:0] frame_q;
    logic [1:0] operation;
    logic mode_1024, use_rng, half_byte;
    logic [3:0] high_nibble, header_index;
    logic [12:0] frame_length, receive_count, transfer_length;
    logic [31:0] rx_crc, sent_crc, timeout_count;
    logic [6:0] seed_index;
    logic [255:0] seed_d, seed_z, message_m;
    wire core_start, core_zeroize;
    logic core_load_begin;
    wire core_load_valid, core_load_ready, core_load_done, core_load_error;
    wire core_busy, core_done, core_zeroize_done, core_pass, core_fail;
    wire key_mode, secret_valid;
    wire [7:0] core_error, core_read_data;
    wire [31:0] core_cycles;
    wire [255:0] ss_enc, ss_dec, fingerprint;
    logic [255:0] result_fp;
    logic [1:0] core_read_object;
    logic [11:0] core_read_address;
`ifdef CONTINUOUS_BANKED_V2_TIMING_FIX
    // The report formatter has six idle GAP clocks between transmitted
    // characters.  Registering its public-memory read command therefore adds
    // no UART cycles, while cutting last_error/report decode away from the
    // byte-store M10K address input.
    logic [1:0] core_read_object_q;
    logic [11:0] core_read_address_q;
`endif
    logic [3:0] report_line;
    logic [12:0] char_index;
    logic [2:0] gap_count;
    logic [12:0] prefix_length, value_length, value_index;
    logic [7:0] prefix_byte, value_byte;
    logic [12:0] ek_length, ct_length;
    logic health_at_result;
    logic demo_active;
    logic [255:0] demo_secret;
    logic demo_secret_valid, demo_match_q;
    logic [31:0] decimal_binary;
    logic [39:0] decimal_bcd, decimal_adjusted;
    logic [5:0] decimal_count;
    integer decimal_digit;
    wire report_finished = report_line == (demo_active ? 4'd14 : 4'd11);
    // Fixed 32-cycle double-dabble conversion, outside the measured core time.
    always_comb begin
        decimal_adjusted = decimal_bcd;
        for (decimal_digit=0; decimal_digit<10; decimal_digit=decimal_digit+1)
            if (decimal_bcd[decimal_digit*4+:4] >= 5)
                decimal_adjusted[decimal_digit*4+:4] = decimal_bcd[decimal_digit*4+:4]+4'd3;
    end
    // Compare the actual 256-bit secrets. The reference stays private and is
    // erased after the final report, a failed run, reset or a new host request.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            demo_secret<=0; demo_secret_valid<=0; demo_match_q<=0;
        end else begin
            demo_match_q <= demo_secret_valid && (demo_secret == ss_dec);
            if (state==IDLE || state==WIPE_START ||
                (state==SCRUB_FRAME && (operation==3 || last_error!=0))) begin
                demo_secret<=0; demo_secret_valid<=0;
            end else if (demo_active && state==WAIT_CORE && core_done &&
                         operation==2 && core_pass && secret_valid) begin
                demo_secret<=ss_enc; demo_secret_valid<=1;
            end
        end
    end
    // Timeout accounting does not need the same-cycle combinational RX route.
    // A local registered activity pulse cuts the top-level UART arbiter out of
    // the 32-bit synchronous-clear path without changing the byte parser.
    logic rx_activity_q;
    // result_fp is a 256-bit report buffer.  Keeping it in the main parser
    // process made the outer timeout comparison part of every result_fp input
    // mux (the measured path was timeout_count[12] -> result_fp[*]).  Generate
    // a local erase token and update the buffer in its own small process so a
    // receive timeout can only steer the parser state, never the 256-bit data.
`ifdef CHANNEL_KEM_LOCAL_FP_CLEAR
    (* maxfan = 32, preserve, dont_merge *) logic result_fp_clear_q;
`endif
    // Pipeline metadata, byte index, data selection and end-of-line feedback.
    // GAP=5 drains the pipeline, including the synchronous public RAM read.
    logic [12:0] prefix_q, value_length_q, payload_end_q, line_end_q;
    logic end_of_line_q;
    logic [7:0] prefix_byte_q, value_byte_q;
    logic [7:0] tx_data_next;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            prefix_q<=0;value_length_q<=0;payload_end_q<=0;line_end_q<=0;
            value_index<=0;end_of_line_q<=0;prefix_byte_q<=0;value_byte_q<=0;
            tx_data<=8'hff;
`ifdef CONTINUOUS_BANKED_V2_TIMING_FIX
            core_read_object_q<=2'd0;core_read_address_q<=12'd0;
`endif
        end else begin
            prefix_q<=prefix_length;value_length_q<=value_length;
            payload_end_q<=prefix_q+value_length_q;
            line_end_q<=payload_end_q+1'b1;
            value_index<=char_index-prefix_q;
            end_of_line_q<=(char_index==line_end_q);
            prefix_byte_q<=prefix_byte;value_byte_q<=value_byte;
            tx_data<=tx_data_next;
`ifdef CONTINUOUS_BANKED_V2_TIMING_FIX
            core_read_object_q<=core_read_object;
            core_read_address_q<=core_read_address;
`endif
        end
    end

`ifdef CHANNEL_KEM_LOCAL_FP_CLEAR
    always_ff @(posedge clk) begin
        if(!rst_n)
            result_fp_clear_q<=1'b1;
        else
            result_fp_clear_q<=
                ((state==IDLE) && rx_valid && (rx_data=="!") && !core_busy) ||
                ((state==SEND) && tx_ready && end_of_line_q &&
                 report_finished);
    end

    // Reset is intentionally indirect through result_fp_clear_q.  Reset and
    // both erase events last while the report output is unavailable, so the
    // one-clock physical erase latency is not externally observable.
    always_ff @(posedge clk) begin
        if(result_fp_clear_q)
            result_fp<=256'd0;
        else if((state==WAIT_CORE) && core_done)
            result_fp<=secret_valid ? fingerprint : 256'd0;
    end
`endif

    function automatic logic is_hex(input logic [7:0] c);
        is_hex=(c>=8'h30 && c<=8'h39)||(c>=8'h41 && c<=8'h46)||(c>=8'h61 && c<=8'h66);
    endfunction
    function automatic logic [3:0] unhex(input logic [7:0] c);
        unhex=(c<=8'h39)?c[3:0]:(c[3:0]+4'd9);
    endfunction
    function automatic logic [7:0] hexchar(input logic [3:0] x);
        hexchar=(x<10)?8'h30+x:8'h41+x-4'd10;
    endfunction
    // The report payload uses a small, fixed vocabulary.  Keep these byte
    // selections explicit instead of using the generic variable part-select
    // in letter(), which synthesized into a deep mux tree on value_index.
    function automatic logic [7:0] mode768_byte(input logic [2:0] idx);
        case (idx)
            3'd0: mode768_byte = "7";
            3'd1: mode768_byte = "6";
            3'd2: mode768_byte = "8";
            default: mode768_byte = 8'h20;
        endcase
    endfunction
    function automatic logic [7:0] mode1024_byte(input logic [2:0] idx);
        case (idx)
            3'd0: mode1024_byte = "1";
            3'd1: mode1024_byte = "0";
            3'd2: mode1024_byte = "2";
            3'd3: mode1024_byte = "4";
            default: mode1024_byte = 8'h20;
        endcase
    endfunction
    function automatic logic [7:0] status_byte(input logic error, input logic [2:0] idx);
        begin
            if (!error) begin
                case (idx)
                    3'd0: status_byte = "O";
                    3'd1: status_byte = "K";
                    default: status_byte = 8'h20;
                endcase
            end else begin
                case (idx)
                    3'd0: status_byte = "E";
                    3'd1: status_byte = "R";
                    3'd2: status_byte = "R";
                    3'd3: status_byte = "O";
                    3'd4: status_byte = "R";
                    default: status_byte = 8'h20;
                endcase
            end
        end
    endfunction
    function automatic logic [7:0] random_source_byte(
        input logic [1:0] op, input logic rng, input logic [3:0] idx);
        begin
            if (op == 0 || op == 3) begin
                case (idx)
                    4'd0: random_source_byte = "N";
                    4'd1: random_source_byte = "O";
                    4'd2: random_source_byte = "N";
                    4'd3: random_source_byte = "E";
                    default: random_source_byte = 8'h20;
                endcase
            end else if (rng) begin
                case (idx)
                    4'd0: random_source_byte = "T";
                    4'd1: random_source_byte = "R";
                    4'd2: random_source_byte = "N";
                    4'd3: random_source_byte = "G";
                    default: random_source_byte = 8'h20;
                endcase
            end else begin
                case (idx)
                    4'd0: random_source_byte = "H";
                    4'd1: random_source_byte = "O";
                    4'd2: random_source_byte = "S";
                    4'd3: random_source_byte = "T";
                    4'd4: random_source_byte = "_";
                    4'd5: random_source_byte = "S";
                    4'd6: random_source_byte = "E";
                    4'd7: random_source_byte = "E";
                    4'd8: random_source_byte = "D";
                    default: random_source_byte = 8'h20;
                endcase
            end
        end
    endfunction
    function automatic logic [7:0] health_byte(input logic health, input logic [2:0] idx);
        begin
            if (health) begin
                case (idx)
                    3'd0: health_byte = "P";
                    3'd1: health_byte = "A";
                    3'd2: health_byte = "S";
                    3'd3: health_byte = "S";
                    default: health_byte = 8'h20;
                endcase
            end else begin
                case (idx)
                    3'd0: health_byte = "F";
                    3'd1: health_byte = "A";
                    3'd2: health_byte = "I";
                    3'd3: health_byte = "L";
                    default: health_byte = 8'h20;
                endcase
            end
        end
    endfunction
    function automatic logic [31:0] crc_byte(input logic [31:0] old, input logic [7:0] b);
        logic [31:0] v; integer n;
        begin v=old^b; for(n=0;n<8;n=n+1) v=v[0]?((v>>1)^32'hedb88320):(v>>1); crc_byte=v; end
    endfunction
    function automatic logic [7:0] letter(input logic [191:0] txt, input integer len, input integer idx);
        letter=(idx>=0 && idx<len)?txt[(len-1-idx)*8+:8]:8'h20;
    endfunction

    assign ek_length=mode_1024?13'd1568:13'd1184;
    assign ct_length=mode_1024?13'd1568:13'd1088;
    assign service_busy=(state!=IDLE)||core_busy;
    assign parser_active = (state == RX_OP)      || (state == RX_MODE) ||
                           (state == RX_SOURCE)  || (state == RX_LENGTH) ||
                           (state == RX_PAYLOAD) || (state == RX_CRC) ||
                           (state == RX_EOL)     || (state == DISCARD);
    // LAUNCH and WIPE_START are already one-clock pulse states.  Decode them
    // directly so the global receive-timeout priority mux is not placed on
    // the start/zeroize control paths.
    assign core_start=(state==LAUNCH);
    assign core_zeroize=(state==WIPE_START);
    assign core_load_valid=(state==LOAD_CAP);
    assign tx_valid=(state==SEND);
    always_ff @(posedge clk) frame_q<=frame_mem[frame_index];

    mlkem_service_core u_core(
        .clk(clk), .rst_n(rst_n), .start(core_start), .zeroize(core_zeroize),
        .operation(operation), .mode_1024(mode_1024),
        .seed_d(seed_d), .seed_z(seed_z), .message_m(message_m),
        .load_begin(core_load_begin), .load_object((operation==2)?2'd0:2'd2),
        .load_mode_1024(mode_1024), .load_length(transfer_length),
        .load_valid(core_load_valid), .load_data(frame_q),
        .load_ready(core_load_ready), .load_done(core_load_done), .load_error(core_load_error),
`ifdef CONTINUOUS_BANKED_V2_TIMING_FIX
        .read_object(core_read_object_q), .read_address(core_read_address_q), .read_data(core_read_data),
`else
        .read_object(core_read_object), .read_address(core_read_address), .read_data(core_read_data),
`endif
        .shared_secret_encaps(ss_enc), .shared_secret_decaps(ss_dec),
        .secret_fingerprint(fingerprint), .secret_valid(secret_valid),
        .key_ready(key_ready), .key_mode_1024(key_mode),
        .busy(core_busy), .done(core_done), .zeroize_done(core_zeroize_done),
        .pass(core_pass), .fail(core_fail), .stage(stage), .cycle_count(core_cycles),
        .error_code(core_error)
    );

    assign channel_clear=core_start || core_zeroize;
    assign channel_key_valid=core_done && secret_valid && core_pass;
    assign channel_key_mode=mode_1024;
    assign channel_key_encaps=(operation==2);
    assign channel_key=(operation==2)?ss_enc:ss_dec;

    // Prefix/payload are pipelined; six GAP clocks allow metadata and RAM to settle.
    always_comb begin
        prefix_length=0; value_length=0; prefix_byte=8'h20; value_byte=8'h2d;
         core_read_object=0; core_read_address=0;
        case(report_line)
            0: begin prefix_length=4; prefix_byte=letter("OP: ",4,char_index); value_length=1;
                case(operation) 1:value_byte="K"; 2:value_byte="E"; 3:value_byte="D"; default:value_byte="Z"; endcase end
            1: begin prefix_length=6; prefix_byte=letter("MODE: ",6,char_index);
                value_length=mode_1024?13'd4:13'd3; 
                value_byte=mode_1024?mode1024_byte(value_index[2:0]):mode768_byte(value_index[2:0]); end
            2: begin prefix_length=8; prefix_byte=letter("STATUS: ",8,char_index);
                 value_length=(last_error==0)?13'd2:13'd5;
                value_byte=status_byte(last_error!=0,value_index[2:0]); end
            3: begin prefix_length=7; prefix_byte=letter("ERROR: ",7,char_index); value_length=2;
                
                value_byte=hexchar((value_index==0)?last_error[7:4]:last_error[3:0]); end
            4: begin prefix_length=12; prefix_byte=letter("CYCLES_HEX: ",12,char_index); value_length=8;
                 value_byte=hexchar(last_cycles>>((7-value_index[2:0])*4)); end
            5: begin prefix_length=11; prefix_byte=letter("KEY_READY: ",11,char_index); value_length=1;
                value_byte=key_ready?"1":"0"; end
            6: begin prefix_length=15; prefix_byte=letter("RANDOM_SOURCE: ",15,char_index);
                
                if(operation==0 || operation==3) begin value_length=4; value_byte=random_source_byte(operation,use_rng,value_index[3:0]); end
                else if(use_rng) begin value_length=4; value_byte=random_source_byte(operation,use_rng,value_index[3:0]); end
                else begin value_length=9; value_byte=random_source_byte(operation,use_rng,value_index[3:0]); end end
            7: begin prefix_length=12; prefix_byte=letter("RNG_HEALTH: ",12,char_index);
                 value_length=4;
                value_byte=health_byte(health_at_result,value_index[2:0]); end
            8: begin prefix_length=9; prefix_byte=letter("SS_SHA3: ",9,char_index);
                
                if(last_error==0 && (operation==2 || operation==3)) begin
                    value_length=64;
                    value_byte=hexchar(result_fp[(value_index[5:1]*8)+(value_index[0]?0:4)+:4]);
                end else begin value_length=1; value_byte="-"; end end
            9: begin prefix_length=8; prefix_byte=letter("EK_HEX: ",8,char_index);
                
                if(!demo_active && last_error==0 && operation==1) begin
                    value_length=ek_length<<1; core_read_object=0; core_read_address=value_index[12:1];
                    value_byte=hexchar(value_index[0]?core_read_data[3:0]:core_read_data[7:4]);
                end else begin value_length=1; value_byte="-"; end end
            10: begin prefix_length=8; prefix_byte=letter("CT_HEX: ",8,char_index);
                
                if(!demo_active && last_error==0 && operation==2) begin
                    value_length=ct_length<<1; core_read_object=2; core_read_address=value_index[12:1];
                    value_byte=hexchar(value_index[0]?core_read_data[3:0]:core_read_data[7:4]);
                end else begin value_length=1; value_byte="-"; end end
            11: begin
                if (!demo_active) begin
                    prefix_length=3; prefix_byte=letter("END",3,char_index); value_length=0;
                end else begin
                    prefix_length=12; prefix_byte=letter("CYCLES_DEC: ",12,char_index); value_length=10;
                    value_byte=hexchar(decimal_bcd[(9-value_index[3:0])*4+:4]);
                end
            end
            12: begin
                prefix_length=15; prefix_byte=letter("CORE_CLOCK_HZ: ",15,char_index);
                value_length=9; value_byte=letter("160000000",9,value_index);
            end
            13: begin
                prefix_length=10; prefix_byte=letter("SELFTEST: ",10,char_index);
                if (last_error!=0 || operation==3) begin
                    value_length=4; value_byte=health_byte(last_error==0,value_index[2:0]);
                end else begin
                    value_length=7; value_byte=letter("RUNNING",7,value_index);
                end
            end
            14: begin prefix_length=3; prefix_byte=letter("END",3,char_index); value_length=0; end
            default: begin end
        endcase
        if(char_index<prefix_q) tx_data_next=prefix_byte_q;
        else if(char_index<payload_end_q) tx_data_next=value_byte_q;
        else if(char_index==payload_end_q) tx_data_next=8'h0d;
        else tx_data_next=8'h0a;
    end

    always_ff @(posedge clk) begin
        if(!rst_n) begin
            state<=SCRUB_FRAME; frame_index<=0; operation<=0; mode_1024<=0; use_rng<=0;
            half_byte<=0; high_nibble<=0; header_index<=0; frame_length<=0;
            receive_count<=0; transfer_length<=0; rx_crc<=32'hffffffff; sent_crc<=0;
            timeout_count<=0; seed_index<=0; seed_d<=0; seed_z<=0; message_m<=0;
            core_load_begin<=0;
            rng_generate<=0; rng_zeroize<=0;
            op_done<=0; op_pass<=0; last_error<=0; last_operation<=0; last_mode<=0;
            last_cycles<=0; display_code<=0;
`ifndef CHANNEL_KEM_LOCAL_FP_CLEAR
            result_fp<=0;
`endif
            report_line<=0; char_index<=0; gap_count<=0;
            health_at_result<=0;
            rx_activity_q<=0;
            demo_active<=0; decimal_binary<=0; decimal_bcd<=0; decimal_count<=0;
        end else begin
            rx_activity_q<=rx_valid;
            core_load_begin<=0;
            rng_generate<=0; rng_zeroize<=0; op_done<=0;
            if(parser_active) begin
                if(rx_activity_q) timeout_count<=0;
                else timeout_count<=timeout_count+1'b1;
            end
            if(parser_active &&
               (rx_error || timeout_count>=RX_TIMEOUT_CYCLES)) begin
                last_error<=8'hf3; state<=REPORT_BEGIN;
            end else case(state)
                IDLE: if(board_start && !core_busy) begin
                    demo_active<=1; mode_1024<=board_mode_1024; operation<=0;
                    last_operation<=0; last_mode<=board_mode_1024;
                    last_error<=0; last_cycles<=0; op_pass<=0; display_code<=0;
                    use_rng<=0; timeout_count<=0; state<=WIPE_START;
                end else if(rx_valid && rx_data=="!" && !core_busy) begin
                    demo_active<=0;
                    operation<=0; mode_1024<=0; use_rng<=0;
                    frame_length<=0; receive_count<=0; rx_crc<=32'hffffffff;
                    sent_crc<=0; timeout_count<=0;
`ifndef CHANNEL_KEM_LOCAL_FP_CLEAR
                    result_fp<=0;
`endif
                    last_error<=0;
                    last_cycles<=0; op_pass<=0; state<=RX_OP;
                end
                RX_OP: if(rx_valid) begin
                    rx_crc<=crc_byte(rx_crc,rx_data);
                    case(rx_data)
                        "K":begin operation<=1; state<=RX_MODE; end
                        "E":begin operation<=2; state<=RX_MODE; end
                        "D":begin operation<=3; state<=RX_MODE; end
                        "Z":begin operation<=0; state<=RX_MODE; end
                        default:begin last_error<=8'hf0; state<=DISCARD; end
                    endcase
                end
                RX_MODE: if(rx_valid) begin
                    rx_crc<=crc_byte(rx_crc,rx_data);
                    if(rx_data=="7" || rx_data=="1") begin
                        mode_1024<=MODE_FROM_SWITCH ? board_mode_1024 : (rx_data=="1");
                        state<=RX_SOURCE;
                    end
                    else begin last_error<=8'hf0; state<=DISCARD; end
                end
                RX_SOURCE: if(rx_valid) begin
                    rx_crc<=crc_byte(rx_crc,rx_data);
                    if(rx_data=="0" || rx_data=="1") begin use_rng<=(rx_data=="1"); header_index<=0; state<=RX_LENGTH; end
                    else begin last_error<=8'hf0; state<=DISCARD; end
                end
                RX_LENGTH: if(rx_valid) begin
                    rx_crc<=crc_byte(rx_crc,rx_data);
                    if(!is_hex(rx_data) || (header_index==0 && unhex(rx_data)>0)) begin
                        last_error<=8'hf2; state<=DISCARD;
                    end else begin
                        frame_length<={frame_length[8:0],unhex(rx_data)};
                        header_index<=header_index+1'b1;
                        if(header_index==3) begin
                            if({frame_length[8:0],unhex(rx_data)}>13'd1600) begin last_error<=8'hf2; state<=DISCARD; end
                            else begin
                                receive_count<=0; half_byte<=0; header_index<=0;
                                state<=({frame_length[8:0],unhex(rx_data)}==0)?RX_CRC:RX_PAYLOAD;
                            end
                        end
                    end
                end
                RX_PAYLOAD: if(rx_valid) begin
                    if(!is_hex(rx_data)) begin last_error<=8'hf0; state<=DISCARD; end
                    else begin
                        rx_crc<=crc_byte(rx_crc,rx_data); half_byte<=!half_byte;
                        if(!half_byte) high_nibble<=unhex(rx_data);
                        else begin
                            frame_mem[receive_count[10:0]]<={high_nibble,unhex(rx_data)};
                            receive_count<=receive_count+1'b1;
                            if(receive_count+1'b1==frame_length) begin header_index<=0; state<=RX_CRC; end
                        end
                    end
                end
                RX_CRC: if(rx_valid) begin
                    if(!is_hex(rx_data)) begin last_error<=8'hf0; state<=DISCARD; end
                    else begin
                        sent_crc<={sent_crc[27:0],unhex(rx_data)}; header_index<=header_index+1'b1;
                        if(header_index==7) state<=RX_EOL;
                    end
                end
                RX_EOL: if(rx_valid) begin
                    if(rx_data==8'h0a) begin
                        if(sent_crc!=(~rx_crc)) begin last_error<=8'hf1; state<=REPORT_BEGIN; end
                        else state<=VALIDATE;
                    end else if(rx_data!=8'h0d) begin last_error<=8'hf0; state<=DISCARD; end
                end
                DISCARD: if(rx_valid && rx_data==8'h0a) state<=REPORT_BEGIN;
                VALIDATE: begin
                    last_operation<=operation; last_mode<=mode_1024;
                    seed_d<=0; seed_z<=0; message_m<=0; seed_index<=0;
                    if((operation==1 && frame_length!=(use_rng?13'd0:13'd64)) ||
                       (operation==2 && frame_length!=(ek_length+(use_rng?13'd0:13'd32))) ||
                       (operation==3 && (frame_length!=ct_length || use_rng)) ||
                       (operation==0 && (frame_length!=0 || use_rng))) begin
                        last_error<=8'hf2; state<=REPORT_BEGIN;
                    end else if(operation==0) begin display_code<=0; state<=WIPE_START; end
                    else if(operation==3) begin transfer_length<=ct_length; state<=LOAD_BEGIN; end
                    else if(use_rng) begin timeout_count<=0; state<=RNG_READY; end
                    else begin frame_index<=(operation==2)?ek_length[10:0]:11'd0; state<=SEED_READ; end
                end
                SEED_READ: state<=SEED_CAP;
                SEED_CAP: begin
                    // Xoa byte seed khoi bo dem UART sau khi da latch.
                    frame_mem[frame_index]<=8'd0;
                    if(operation==2) message_m[8*seed_index[4:0]+:8]<=frame_q;
                    else if(seed_index<32) seed_d[8*seed_index[4:0]+:8]<=frame_q;
                    else seed_z[8*seed_index[4:0]+:8]<=frame_q;
                    if(seed_index==((operation==2)?7'd31:7'd63)) begin
                        transfer_length<=ek_length; state<=(!demo_active && operation==2)?LOAD_BEGIN:LAUNCH;
                    end else begin seed_index<=seed_index+1'b1; frame_index<=frame_index+1'b1; state<=SEED_READ; end
                end
                RNG_READY: begin
                    timeout_count<=timeout_count+1'b1;
                    if(rng_alarm || timeout_count>=RNG_TIMEOUT_CYCLES) begin last_error<=8'he1; state<=demo_active?WIPE_START:REPORT_BEGIN; end
                    else if(rng_ready) begin rng_generate<=1; state<=RNG_WAIT; end
                end
                RNG_WAIT: begin
                    timeout_count<=timeout_count+1'b1;
                    if(rng_alarm || timeout_count>=RNG_TIMEOUT_CYCLES) begin last_error<=8'he1; state<=demo_active?WIPE_START:REPORT_BEGIN; end
                    else if(rng_done) begin
                        seed_d<=rng_d; seed_z<=rng_z; message_m<=rng_m;
                        transfer_length<=ek_length; state<=(!demo_active && operation==2)?LOAD_BEGIN:LAUNCH;
                    end
                end
                LOAD_BEGIN: begin core_load_begin<=1; frame_index<=0; state<=LOAD_READ; end
                LOAD_READ: begin
                    if(core_load_error) begin last_error<=8'hf2; state<=REPORT_BEGIN; end
                    else state<=LOAD_CAP;
                end
                LOAD_CAP: if(core_load_ready) begin
                    if({2'b0,frame_index}+13'd1==transfer_length) state<=LAUNCH_GAP;
                    else begin frame_index<=frame_index+1'b1; state<=LOAD_READ; end
                end
                LAUNCH_GAP: state<=LAUNCH;
                LAUNCH: begin
                    state<=WAIT_CORE;
                    if(demo_active) begin last_operation<=operation; last_mode<=mode_1024; end
                end
                WAIT_CORE: begin
                    // Core da latch seed o canh nhan start.
                    seed_d<=0; seed_z<=0; message_m<=0;
                    if(core_done) begin
                        last_cycles<=core_cycles; last_error<=core_error;
                        // The fingerprint shift register stores digest byte 0
                        // in bits 7:0.  Reorder the first three digest bytes so
                        // HEX5..HEX0 reads exactly like SS_SHA3[0:6].
                        if(secret_valid && core_pass)
                            display_code<={fingerprint[7:0],fingerprint[15:8],fingerprint[23:16]};
`ifndef CHANNEL_KEM_LOCAL_FP_CLEAR
                        result_fp<=secret_valid?fingerprint:256'd0;
`endif
                        if(use_rng && rng_alarm) begin last_error<=8'he1; state<=WIPE_START; end
                        else if(demo_active) begin
                            if(!core_pass || (operation!=1 && !secret_valid)) begin
                                if(core_error==0) last_error<=8'he3;
                                state<=WIPE_START;
                            end else state<=(operation==3)?DEMO_CHECK:DECIMAL_INIT;
                        end else state<=REPORT_BEGIN;
                    end
                end
                DEMO_CHECK: begin
                    if(rng_alarm || !rng_health) begin last_error<=8'he1; state<=WIPE_START; end
                    else if(!demo_match_q) begin last_error<=8'he2; state<=WIPE_START; end
                    else state<=DECIMAL_INIT;
                end
                DECIMAL_INIT: begin
                    decimal_binary<=last_cycles; decimal_bcd<=0; decimal_count<=0;
                    state<=DECIMAL_SHIFT;
                end
                DECIMAL_SHIFT: begin
                    decimal_bcd<={decimal_adjusted[38:0],decimal_binary[31]};
                    decimal_binary<={decimal_binary[30:0],1'b0};
                    if(decimal_count==31) state<=REPORT_BEGIN;
                    else decimal_count<=decimal_count+1'b1;
                end
                WIPE_START: begin rng_zeroize<=1; state<=WIPE_WAIT; end
                WIPE_WAIT: if(core_zeroize_done) begin
                    if(demo_active && operation==0 && last_error==0) begin
                        operation<=1; use_rng<=1; timeout_count<=0; state<=RNG_READY;
                    end else state<=demo_active?DECIMAL_INIT:REPORT_BEGIN;
                end
                REPORT_BEGIN: begin
                    seed_d<=0; seed_z<=0; message_m<=0;
                    health_at_result<=rng_health && !rng_alarm;
                    op_done<=1; op_pass<=(last_error==0);
                    report_line<=0; char_index<=0; gap_count<=5; state<=GAP;
                end
                SEND: if(tx_ready) begin
                    if(end_of_line_q) begin
                        char_index<=0;
                        if(report_finished) begin
`ifndef CHANNEL_KEM_LOCAL_FP_CLEAR
                            result_fp<=0;
`endif
                            rng_zeroize<=1; frame_index<=0; state<=SCRUB_FRAME;
                        end else begin report_line<=report_line+1'b1; gap_count<=5; state<=GAP; end
                    end else begin char_index<=char_index+1'b1; gap_count<=5; state<=GAP; end
                end
                GAP: if(gap_count==0) state<=SEND; else gap_count<=gap_count-1'b1;
                SCRUB_FRAME: begin
                    // Xoa ca frame bi CRC sai/timeout, khong giu lai seed trong RAM UART.
                    frame_mem[frame_index]<=8'd0;
                    if(frame_index==11'd1599) begin
                        frame_index<=0;
                        if(demo_active && last_error==0 && operation!=3) state<=DEMO_NEXT;
                        else begin demo_active<=0; state<=IDLE; end
                    end
                    else frame_index<=frame_index+1'b1;
                end
                DEMO_NEXT: begin
                    last_error<=0; last_cycles<=0; timeout_count<=0;
                    if(rng_alarm || !rng_health) begin last_error<=8'he1; state<=WIPE_START; end
                    else if(operation==1) begin operation<=2; use_rng<=1; state<=RNG_READY; end
                    else begin operation<=3; use_rng<=0; state<=LAUNCH; end
                end
                default:begin last_error<=8'hff; state<=REPORT_BEGIN; end
            endcase
        end
    end
endmodule
`ifdef CHANNEL_KEM_LOCAL_FP_CLEAR
`undef CHANNEL_KEM_LOCAL_FP_CLEAR
`endif
