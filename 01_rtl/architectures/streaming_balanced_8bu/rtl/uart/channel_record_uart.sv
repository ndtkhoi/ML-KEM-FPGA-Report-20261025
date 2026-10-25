// Khung $<S/P/U><7/1>0<LLLL><payload hex><CRC32> LF.
// S: session_id 16 byte. P: plaintext <=256 byte. U: seq_be64 || ciphertext || tag16.
// Giai ma chi bao LEN va SHA3(plaintext), KHONG tra plaintext qua UART.
module channel_record_uart #(
    parameter integer RX_TIMEOUT_CYCLES=100_000_000
) (
    input logic clk,rst_n,rx_valid,rx_error,
    input logic [7:0] rx_data,
    output logic tx_valid,
    output logic [7:0] tx_data,
    input logic tx_ready,kem_clear,kem_valid,kem_mode,kem_encaps,
    input logic [255:0] kem_secret,
    output logic service_busy,active,op_done,op_pass,
    output logic [7:0] last_error,
    output logic [1:0] last_op,
    output logic last_mode,
    output logic [8:0] result_length,
    output logic [31:0] tx_count,rx_count,auth_fail_count,replay_count
);
    // Giai ma ky tu truoc FSM; tach RX -> hex decode -> so sanh do dai.
    logic rx_valid_q,rx_error_q,rx_hex_q;
    logic [7:0] rx_data_q,tx_data_next;
    logic [3:0] rx_nibble_q;
    always_ff @(posedge clk) begin
        if(!rst_n)begin rx_valid_q<=0;rx_error_q<=0;rx_hex_q<=0;rx_data_q<=0;rx_nibble_q<=0;tx_data<=8'hff;end
        else begin
            rx_valid_q<=rx_valid;rx_error_q<=rx_error;
            if(rx_valid)begin rx_data_q<=rx_data;rx_hex_q<=is_hex(rx_data);rx_nibble_q<=unhex(rx_data);end
            tx_data<=tx_data_next;
        end
    end

    typedef enum logic [4:0] {IDLE,RX_OP,RX_MODE,RX_SOURCE,RX_LEN,RX_PAYLOAD,RX_CRC,RX_EOL,
        DISCARD,VALIDATE,LOAD_REQ,LOAD_CAP,LAUNCH,WAIT_CORE,REPORT,SEND,GAP,SCRUB} state_t;
    state_t state;
    logic [7:0] frame[0:279],frame_q;
    logic [8:0] index,received,frame_length,record_length;
    logic [3:0] digits,high_nibble;
    logic half_byte;
    logic [1:0] op;
    logic mode;
    logic [31:0] crc,sent_crc,timeout_count;
    logic [127:0] sid_in,tag_in;
    logic [63:0] seq_in;
    wire core_done,core_busy;
    wire [7:0] core_error,core_read;
`ifdef ITERATIVE_BASELINE_TIMING_FIX
    // The baseline fit's final 6 ps violation crossed the GCM visibility
    // controls, synchronous output RAM and the report-byte mux in one cycle.
    // UART characters are already separated by a drain gap, so this local
    // report register cuts that physical path without changing crypto cycles.
    logic [7:0] core_read_q;
`endif
    wire [63:0] epoch,result_seq;
    wire [127:0] sid,tag;
    wire [255:0] phash;
    wire [31:0] cycles;
    logic [4:0] line_index;
`ifdef MLKEM_STREAMING_BALANCED_8BU
    // Decode the report line during the UART gap.  SEND then uses local
    // one-hot selects instead of putting the line counter, an 18-way decode
    // and the report byte mux in the same 160 MHz path.
    (* maxfan = 32, preserve, dont_merge *) logic [17:0] line_select_q;
`endif
    logic [9:0] char_index,prefix_len,value_len,value_index;
    logic [7:0] prefix_byte,value_byte;
    logic [31:0] report_number;
`ifdef MLKEM_STREAMING_BALANCED_8BU
    // Pre-encode the SHA3 digest once per clock.  The old report path placed
    // 64 hex encoders in front of the UART character register and made the
    // worst path a wide variable part-select.  This registered ASCII view
    // leaves only the byte selector on the SEND path and does not alter the
    // protocol or cryptographic operation latency.
    (* preserve, dont_merge *) logic [511:0] phash_ascii_q;
    integer phash_ascii_i;
`endif
    wire [15:0] reported_length = (last_error==0)
        ? {7'd0,result_length} : 16'd0;
    wire [255:0] sid_hex_ascii, tag_hex_ascii;
    wire [127:0] epoch_hex_ascii, sequence_hex_ascii;
    wire [31:0] length_hex_ascii;
    wire [511:0] phash_hex_ascii;
    wire [63:0] report_hex_ascii;
    // Pipeline metadata, byte index, data selection and end-of-line feedback.
    // GAP=5 drains the pipeline, including the synchronous public RAM read.
    logic [9:0] prefix_q, value_length_q, payload_end_q, line_end_q;
    logic end_of_line_q;
    logic [7:0] prefix_byte_q, value_byte_q;
`ifdef ITERATIVE_BASELINE_TIMING_FIX
    localparam logic [2:0] REPORT_GAP = 3'd6;
`else
    localparam logic [2:0] REPORT_GAP = 3'd5;
`endif

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            prefix_q<=0;value_length_q<=0;payload_end_q<=0;line_end_q<=0;
            value_index<=0;end_of_line_q<=0;prefix_byte_q<=0;value_byte_q<=0;
`ifdef MLKEM_STREAMING_BALANCED_8BU
            line_select_q<=18'd1;
`endif

        end else begin
`ifdef MLKEM_STREAMING_BALANCED_8BU
            line_select_q<=(line_index<5'd18)?(18'd1<<line_index):18'd0;
`endif
            prefix_q<=prefix_len;value_length_q<=value_len;
            payload_end_q<=prefix_q+value_length_q;
            line_end_q<=payload_end_q+1'b1;
            value_index<=char_index-prefix_q;
            end_of_line_q<=(char_index==line_end_q);
            prefix_byte_q<=prefix_byte;value_byte_q<=value_byte;

        end
    end
`ifdef ITERATIVE_BASELINE_TIMING_FIX
    always_ff @(posedge clk) core_read_q<=core_read;
`endif
    logic [2:0] gap;
    wire payload_byte=(op==1)||(op==2 && index>=8 && index<record_length+9'd8);
    wire [8:0] load_addr=(op==2)?index-9'd8:index;
    function automatic logic is_hex(input logic [7:0] c);
        is_hex=(c>="0"&&c<="9")||(c>="A"&&c<="F")||(c>="a"&&c<="f");
    endfunction
    function automatic logic [3:0] unhex(input logic [7:0] c);
        unhex=(c<="9")?c[3:0]:c[3:0]+4'd9;
    endfunction
    function automatic logic [7:0] hexchar(input logic [3:0] n);
        hexchar=(n<10)?8'h30+n:8'h41+n-4'd10;
    endfunction
`ifdef MLKEM_STREAMING_BALANCED_8BU
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            phash_ascii_q <= 512'd0;
        end else begin
            for (phash_ascii_i=0; phash_ascii_i<64;
                 phash_ascii_i=phash_ascii_i+1) begin
                phash_ascii_q[8*phash_ascii_i +: 8] <=
                    hexchar(phash[8*(phash_ascii_i/2) +
                        ((phash_ascii_i%2)==0 ? 4 : 0) +: 4]);
            end
        end
    end
`endif

    // Pre-encode every fixed-width hexadecimal digit.  The previous
    // vector >> variable_shift expression built a wide barrel shifter and
    // then placed the hex encoder after its 32:1 mux.  With these constant
    // slices value_index only selects one already encoded byte.
    genvar hex128_i, hex64_i, hex32_i, hex16_i, hash_hex_i;
    generate
        for (hex128_i=0; hex128_i<32; hex128_i=hex128_i+1) begin : g_hex128
            assign sid_hex_ascii[8*hex128_i +: 8] =
                hexchar(sid[4*(31-hex128_i) +: 4]);
            assign tag_hex_ascii[8*hex128_i +: 8] =
                hexchar(tag[4*(31-hex128_i) +: 4]);
        end
        for (hex64_i=0; hex64_i<16; hex64_i=hex64_i+1) begin : g_hex64
            assign epoch_hex_ascii[8*hex64_i +: 8] =
                hexchar(epoch[4*(15-hex64_i) +: 4]);
            assign sequence_hex_ascii[8*hex64_i +: 8] =
                hexchar(result_seq[4*(15-hex64_i) +: 4]);
        end
        for (hex32_i=0; hex32_i<8; hex32_i=hex32_i+1) begin : g_hex32
            assign report_hex_ascii[8*hex32_i +: 8] =
                hexchar(report_number[4*(7-hex32_i) +: 4]);
        end
        for (hex16_i=0; hex16_i<4; hex16_i=hex16_i+1) begin : g_hex16
            assign length_hex_ascii[8*hex16_i +: 8] =
                hexchar(reported_length[4*(3-hex16_i) +: 4]);
        end
        for (hash_hex_i=0; hash_hex_i<64; hash_hex_i=hash_hex_i+1) begin : g_hash_hex
`ifdef MLKEM_STREAMING_BALANCED_8BU
            assign phash_hex_ascii[8*hash_hex_i +: 8] =
                phash_ascii_q[8*hash_hex_i +: 8];
`else
            assign phash_hex_ascii[8*hash_hex_i +: 8] =
                hexchar(phash[8*(hash_hex_i/2) +
                    ((hash_hex_i%2)==0 ? 4 : 0) +: 4]);
`endif
        end
    endgenerate
    function automatic logic [31:0] crc_byte(input logic [31:0] old,input logic [7:0] b);
        logic [31:0] v;integer k;
        begin v=old^b;for(k=0;k<8;k=k+1)v=v[0]?((v>>1)^32'hedb88320):(v>>1);crc_byte=v;end
    endfunction
    function automatic logic [7:0] letter(input logic [191:0] s,input integer len,input integer i);
        letter=(i>=0&&i<len)?s[(len-1-i)*8+:8]:8'h20;
    endfunction
    // Chi dung valid DA DANG KY: tranh vong to hop busy <-> demux UART o top.
    assign service_busy=(state!=IDLE)||core_busy||rx_valid_q;
    assign tx_valid=(state==SEND);
    always_ff @(posedge clk) frame_q<=frame[index];
    channel_session u_session(.clk(clk),.rst_n(rst_n),.kem_clear(kem_clear),.kem_valid(kem_valid),
        .kem_mode(kem_mode),.kem_encaps(kem_encaps),.kem_secret(kem_secret),
        .start(state==LAUNCH),.request_mode(mode),.op(op),.session_id_in(sid_in),.tag_in(tag_in),
        .sequence_in(seq_in),.data_length(record_length),
        .load_we(state==LOAD_CAP&&payload_byte),.load_address(load_addr[7:0]),.load_data(frame_q),
        .read_address(value_index[8:1]),.read_data(core_read),.error_code(core_error),
        .active(active),.busy(core_busy),.done(core_done),.epoch(epoch),.result_sequence(result_seq),
        .session_id(sid),.tag_out(tag),.plaintext_hash(phash),.result_length(result_length),
        .tx_count(tx_count),.rx_count(rx_count),.auth_fail_count(auth_fail_count),.replay_count(replay_count),.cycles(cycles));
    always_comb begin
        prefix_len=0;value_len=0;prefix_byte=32;value_byte="-";report_number=0;
`ifdef MLKEM_STREAMING_BALANCED_8BU
        case(1'b1)
            line_select_q[0]:begin prefix_len=4;prefix_byte=letter("OP: ",4,char_index);value_len=1;value_byte=(op==0)?"S":((op==1)?"P":"U");end
            line_select_q[1]:begin prefix_len=6;prefix_byte=letter("MODE: ",6,char_index);value_len=mode?10'd4:10'd3;
                value_byte=mode?letter("1024",4,value_index):letter("768",3,value_index);end
            line_select_q[2]:begin prefix_len=8;prefix_byte=letter("STATUS: ",8,char_index);value_len=(last_error==0)?10'd2:10'd5;
                value_byte=(last_error==0)?letter("OK",2,value_index):letter("ERROR",5,value_index);end
            line_select_q[3]:begin prefix_len=7;prefix_byte=letter("ERROR: ",7,char_index);value_len=2;
                value_byte=hexchar(value_index[0]?last_error[3:0]:last_error[7:4]);end
            line_select_q[4]:begin prefix_len=16;prefix_byte=letter("SESSION_ACTIVE: ",16,char_index);value_len=1;value_byte=active?"1":"0";end
            line_select_q[5]:begin prefix_len=12;prefix_byte=letter("SESSION_ID: ",12,char_index);value_len=32;
                value_byte=sid_hex_ascii[8*value_index[4:0]+:8];end
            line_select_q[6],line_select_q[7]:begin prefix_len=line_select_q[6]?10'd7:10'd5;prefix_byte=line_select_q[6]?letter("EPOCH: ",7,char_index):letter("SEQ: ",5,char_index);
                value_len=16;value_byte=line_select_q[6]
                    ? epoch_hex_ascii[8*value_index[3:0]+:8]
                    : sequence_hex_ascii[8*value_index[3:0]+:8];end
            line_select_q[8]:begin prefix_len=5;prefix_byte=letter("LEN: ",5,char_index);value_len=4;
                value_byte=length_hex_ascii[8*value_index[1:0]+:8];end
            line_select_q[9]:begin prefix_len=10;prefix_byte=letter("DATA_HEX: ",10,char_index);
                if(last_error==0 && op==1 && result_length!=0)begin
                    value_len={result_length,1'b0};
`ifdef ITERATIVE_BASELINE_TIMING_FIX
                    value_byte=hexchar(value_index[0]?core_read_q[3:0]:core_read_q[7:4]);
`else
                    value_byte=hexchar(value_index[0]?core_read[3:0]:core_read[7:4]);
`endif
                end
                else begin value_len=1;value_byte="-";end end
            line_select_q[10]:begin prefix_len=5;prefix_byte=letter("TAG: ",5,char_index);
                if(last_error==0&&op==1)begin value_len=32;value_byte=tag_hex_ascii[8*value_index[4:0]+:8];end else begin value_len=1;value_byte="-";end end
            line_select_q[11]:begin prefix_len=16;prefix_byte=letter("PLAINTEXT_SHA3: ",16,char_index);
                if(last_error==0&&op==2)begin value_len=64;value_byte=phash_hex_ascii[8*value_index[5:0]+:8];end
                else begin value_len=1;value_byte="-";end end
            line_select_q[12],line_select_q[13],line_select_q[14],line_select_q[15],line_select_q[16]:begin
                if(line_select_q[12])begin prefix_len=10;prefix_byte=letter("TX_COUNT: ",10,char_index);report_number=tx_count;end
                else if(line_select_q[13])begin prefix_len=10;prefix_byte=letter("RX_COUNT: ",10,char_index);report_number=rx_count;end
                else if(line_select_q[14])begin prefix_len=12;prefix_byte=letter("AUTH_FAILS: ",12,char_index);report_number=auth_fail_count;end
                else if(line_select_q[15])begin prefix_len=9;prefix_byte=letter("REPLAYS: ",9,char_index);report_number=replay_count;end
                else begin prefix_len=12;prefix_byte=letter("CYCLES_HEX: ",12,char_index);report_number=cycles;end
                value_len=8;value_byte=report_hex_ascii[8*value_index[2:0]+:8];
            end
            line_select_q[17]:begin prefix_len=3;prefix_byte=letter("END",3,char_index);value_len=0;end
            default:begin end
        endcase
`else
        case(line_index)
            0:begin prefix_len=4;prefix_byte=letter("OP: ",4,char_index);value_len=1;value_byte=(op==0)?"S":((op==1)?"P":"U");end
            1:begin prefix_len=6;prefix_byte=letter("MODE: ",6,char_index);value_len=mode?10'd4:10'd3;
                value_byte=mode?letter("1024",4,value_index):letter("768",3,value_index);end
            2:begin prefix_len=8;prefix_byte=letter("STATUS: ",8,char_index);value_len=(last_error==0)?10'd2:10'd5;
                value_byte=(last_error==0)?letter("OK",2,value_index):letter("ERROR",5,value_index);end
            3:begin prefix_len=7;prefix_byte=letter("ERROR: ",7,char_index);value_len=2;
                value_byte=hexchar(value_index[0]?last_error[3:0]:last_error[7:4]);end
            4:begin prefix_len=16;prefix_byte=letter("SESSION_ACTIVE: ",16,char_index);value_len=1;value_byte=active?"1":"0";end
            5:begin prefix_len=12;prefix_byte=letter("SESSION_ID: ",12,char_index);value_len=32;
                value_byte=sid_hex_ascii[8*value_index[4:0]+:8];end
            6,7:begin prefix_len=(line_index==6)?10'd7:10'd5;prefix_byte=(line_index==6)?letter("EPOCH: ",7,char_index):letter("SEQ: ",5,char_index);
                value_len=16;value_byte=(line_index==6)
                    ? epoch_hex_ascii[8*value_index[3:0]+:8]
                    : sequence_hex_ascii[8*value_index[3:0]+:8];end
            8:begin prefix_len=5;prefix_byte=letter("LEN: ",5,char_index);value_len=4;
                value_byte=length_hex_ascii[8*value_index[1:0]+:8];end
            9:begin prefix_len=10;prefix_byte=letter("DATA_HEX: ",10,char_index);
                if(last_error==0 && op==1 && result_length!=0)begin
                    value_len={result_length,1'b0};
`ifdef ITERATIVE_BASELINE_TIMING_FIX
                    value_byte=hexchar(value_index[0]?core_read_q[3:0]:core_read_q[7:4]);
`else
                    value_byte=hexchar(value_index[0]?core_read[3:0]:core_read[7:4]);
`endif
                end
                else begin value_len=1;value_byte="-";end end
            10:begin prefix_len=5;prefix_byte=letter("TAG: ",5,char_index);
                if(last_error==0&&op==1)begin value_len=32;value_byte=tag_hex_ascii[8*value_index[4:0]+:8];end else begin value_len=1;value_byte="-";end end
            11:begin prefix_len=16;prefix_byte=letter("PLAINTEXT_SHA3: ",16,char_index);
                if(last_error==0&&op==2)begin value_len=64;value_byte=phash_hex_ascii[8*value_index[5:0]+:8];end
                else begin value_len=1;value_byte="-";end end
            12,13,14,15,16:begin
                case(line_index)
                    12:begin prefix_len=10;prefix_byte=letter("TX_COUNT: ",10,char_index);report_number=tx_count;end
                    13:begin prefix_len=10;prefix_byte=letter("RX_COUNT: ",10,char_index);report_number=rx_count;end
                    14:begin prefix_len=12;prefix_byte=letter("AUTH_FAILS: ",12,char_index);report_number=auth_fail_count;end
                    15:begin prefix_len=9;prefix_byte=letter("REPLAYS: ",9,char_index);report_number=replay_count;end
                    default:begin prefix_len=12;prefix_byte=letter("CYCLES_HEX: ",12,char_index);report_number=cycles;end
                endcase
                value_len=8;value_byte=report_hex_ascii[8*value_index[2:0]+:8];
            end
            17:begin prefix_len=3;prefix_byte=letter("END",3,char_index);value_len=0;end
            default:begin end
        endcase
`endif
        if(char_index<prefix_q)tx_data_next=prefix_byte_q;
        else if(char_index<payload_end_q)tx_data_next=value_byte_q;
        else tx_data_next=(char_index==payload_end_q)?8'h0d:8'h0a;
    end
    always_ff @(posedge clk)begin
        if(!rst_n)begin
            state<=SCRUB;index<=0;received<=0;frame_length<=0;record_length<=0;digits<=0;
            high_nibble<=0;half_byte<=0;op<=0;mode<=0;crc<=32'hffffffff;sent_crc<=0;timeout_count<=0;
            sid_in<=0;tag_in<=0;seq_in<=0;line_index<=0;char_index<=0;gap<=0;
            op_done<=0;op_pass<=0;last_error<=0;last_op<=0;last_mode<=0;
        end else begin
            op_done<=0;
            if(state>=RX_OP&&state<=DISCARD)timeout_count<=rx_valid_q?32'd0:timeout_count+1'b1;
            if(state>=RX_OP&&state<=DISCARD&&(rx_error_q||timeout_count>=RX_TIMEOUT_CYCLES))begin last_error<=8'hf3;state<=REPORT;end
            else case(state)
                IDLE:if(rx_valid_q&&rx_data_q=="$"&&!core_busy)begin
                    crc<=32'hffffffff;sent_crc<=0;timeout_count<=0;last_error<=0;op_pass<=0;
                    frame_length<=0;received<=0;op<=0;mode<=0;state<=RX_OP;
                end
                RX_OP:if(rx_valid_q)begin
                    crc<=crc_byte(crc,rx_data_q);
                    case(rx_data_q)"S":begin op<=0;state<=RX_MODE;end "P":begin op<=1;state<=RX_MODE;end
                        "U":begin op<=2;state<=RX_MODE;end default:begin last_error<=8'hf0;state<=DISCARD;end endcase
                end
                RX_MODE:if(rx_valid_q)begin
                    crc<=crc_byte(crc,rx_data_q);
                    if(rx_data_q=="7"||rx_data_q=="1")begin mode<=(rx_data_q=="1");state<=RX_SOURCE;end
                    else begin last_error<=8'hf0;state<=DISCARD;end
                end
                RX_SOURCE:if(rx_valid_q)begin
                    crc<=crc_byte(crc,rx_data_q);digits<=0;
                    if(rx_data_q=="0")state<=RX_LEN;else begin last_error<=8'hf0;state<=DISCARD;end
                end
                RX_LEN:if(rx_valid_q)begin
                    crc<=crc_byte(crc,rx_data_q);
                    if(!rx_hex_q||(digits==0&&rx_data_q!="0")||(digits==1&&rx_nibble_q>1))begin last_error<=8'hf2;state<=DISCARD;end
                    else begin
                        frame_length<={frame_length[4:0],rx_nibble_q};digits<=digits+1'b1;
                        if(digits==3)begin
                            digits<=0;half_byte<=0;received<=0;
                            if({frame_length[4:0],rx_nibble_q}>280)begin last_error<=8'hf2;state<=DISCARD;end
                            else state<=({frame_length[4:0],rx_nibble_q}==0)?RX_CRC:RX_PAYLOAD;
                        end
                    end
                end
                RX_PAYLOAD:if(rx_valid_q)begin
                    if(!rx_hex_q)begin last_error<=8'hf0;state<=DISCARD;end
                    else begin
                        crc<=crc_byte(crc,rx_data_q);half_byte<=!half_byte;
                        if(!half_byte)high_nibble<=rx_nibble_q;
                        else begin frame[received]<={high_nibble,rx_nibble_q};received<=received+1'b1;
                            if(received+1'b1==frame_length)begin digits<=0;state<=RX_CRC;end end
                    end
                end
                RX_CRC:if(rx_valid_q)begin
                    if(!rx_hex_q)begin last_error<=8'hf0;state<=DISCARD;end
                    else begin sent_crc<={sent_crc[27:0],rx_nibble_q};digits<=digits+1'b1;if(digits==7)state<=RX_EOL;end
                end
                RX_EOL:if(rx_valid_q)begin
                    if(rx_data_q==10)begin if(sent_crc!=~crc)begin last_error<=8'hf1;state<=REPORT;end else state<=VALIDATE;end
                    else if(rx_data_q!=13)begin last_error<=8'hf0;state<=DISCARD;end
                end
                DISCARD:if(rx_valid_q&&rx_data_q==10)state<=REPORT;
                VALIDATE:begin
                    last_op<=op;last_mode<=mode;sid_in<=0;tag_in<=0;seq_in<=0;index<=0;
                    record_length<=(op==2)?frame_length-9'd24:((op==1)?frame_length:9'd0);
                    if((op==0&&frame_length!=16)||(op==1&&frame_length>256)||(op==2&&frame_length<24))begin last_error<=8'hf2;state<=REPORT;end
                    else state<=(frame_length==0)?LAUNCH:LOAD_REQ;
                end
                LOAD_REQ:state<=LOAD_CAP;
                LOAD_CAP:begin
                    if(op==0)sid_in<={sid_in[119:0],frame_q};
                    if(op==2&&index<8)seq_in<={seq_in[55:0],frame_q};
                    if(op==2&&index>=record_length+9'd8)tag_in<={tag_in[119:0],frame_q};
                    if(index+1'b1==frame_length)state<=LAUNCH;else begin index<=index+1'b1;state<=LOAD_REQ;end
                end
                LAUNCH:state<=WAIT_CORE;
                WAIT_CORE:if(core_done)begin last_error<=core_error;state<=REPORT;end
                REPORT:begin op_done<=1;op_pass<=(last_error==0);line_index<=0;char_index<=0;gap<=REPORT_GAP;state<=GAP;end
                SEND:if(tx_ready)begin
                    if(end_of_line_q)begin
                        char_index<=0;
                        if(line_index==17)begin index<=0;state<=SCRUB;end
                        else begin line_index<=line_index+1'b1;gap<=REPORT_GAP;state<=GAP;end
                    end else begin char_index<=char_index+1'b1;gap<=REPORT_GAP;state<=GAP;end
                end
                GAP:if(gap==0)state<=SEND;else gap<=gap-1'b1;
                SCRUB:begin frame[index]<=0;if(index==279)begin index<=0;state<=IDLE;end else index<=index+1'b1;end
                default:state<=IDLE;
            endcase
        end
    end
endmodule
