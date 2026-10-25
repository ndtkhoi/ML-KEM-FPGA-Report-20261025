// AES-256 encrypt-only. GCM can ca ma hoa va giai ma bang phep AES encrypt.
// Byte 0 o MSB; 14 round. Key schedule duoc sinh on-the-fly theo tung cap
// round key, khong luu mang 60 word. SubBytes, MixColumns va AddRoundKey van
// tach chu ky de dong timing tren Cyclone V.
module aes256_block (
    input logic clk, rst_n, zeroize, start,
    input logic [255:0] key,
    input logic [127:0] block_in,
    output logic [127:0] block_out,
    output logic busy, done
);
    localparam logic [2047:0] SBOX = 2048'h637c777bf26b6fc53001672bfed7ab76ca82c97dfa5947f0add4a2af9ca472c0b7fd9326363ff7cc34a5e5f171d8311504c723c31896059a071280e2eb27b27509832c1a1b6e5aa0523bd6b329e32f8453d100ed20fcb15b6acbbe394a4c58cfd0efaafb434d338545f9027f503c9fa851a3408f929d38f5bcb6da2110fff3d2cd0c13ec5f974417c4a77e3d645d197360814fdc222a908846eeb814de5e0bdbe0323a0a4906245cc2d3ac629195e479e7c8376d8dd54ea96c56f4ea657aae08ba78252e1ca6b4c6e8dd741f4bbd8b8a703eb5664803f60e613557b986c11d9ee1f8981169d98e949b1e87e9ce5528df8ca1890dbfe6426841992d0fb054bb16;
    function automatic logic [7:0] sb(input logic [7:0] x);
        sb=SBOX[2047-8*x-:8];
    endfunction
    function automatic logic [7:0] xt(input logic [7:0] x);
        xt={x[6:0],1'b0}^({8{x[7]}} & 8'h1b);
    endfunction
    function automatic logic [31:0] subword(input logic [31:0] x);
        subword={sb(x[31:24]),sb(x[23:16]),sb(x[15:8]),sb(x[7:0])};
    endfunction
    function automatic logic [127:0] subshift(input logic [127:0] x);
        integer i,j;
        begin
            for(i=0;i<16;i=i+1) begin
                j=4*((i/4+i%4)%4)+i%4;
                subshift[127-8*i-:8]=sb(x[127-8*j-:8]);
            end
        end
    endfunction
    function automatic logic [127:0] mix(input logic [127:0] x);
        integer c; logic [7:0] a,b,d,e,t;
        begin
            for(c=0;c<4;c=c+1) begin
                a=x[127-32*c-:8]; b=x[119-32*c-:8];
                d=x[111-32*c-:8]; e=x[103-32*c-:8]; t=a^b^d^e;
                mix[127-32*c-:8]=a^t^xt(a^b);
                mix[119-32*c-:8]=b^t^xt(b^d);
                mix[111-32*c-:8]=d^t^xt(d^e);
                mix[103-32*c-:8]=e^t^xt(e^a);
            end
        end
    endfunction
    function automatic logic [127:0] xor_chain(
        input logic [127:0] base,input logic [31:0] seed);
        logic [31:0] w0,w1,w2,w3;
        begin
            w0=base[127:96]^seed;
            w1=base[95:64]^w0;
            w2=base[63:32]^w1;
            w3=base[31:0]^w2;
            xor_chain={w0,w1,w2,w3};
        end
    endfunction
    typedef enum logic [3:0] {IDLE,INIT,SUB,MIX,ADD,
        KS_SUB_EVEN,KS_XOR_EVEN,KS_SUB_ODD,KS_XOR_ODD} state_t;
    state_t state;
    logic [127:0] data_reg,key_even,key_odd,next_even;
    logic [31:0] schedule_temp;
    logic [3:0] round_index;
    logic [7:0] rcon;
    // Buffer the chip-wide synchronous reset at the AES boundary.  The
    // post-fit critical path in the iterative project was reset_sync_n ->
    // schedule_temp: 84% of its 6.091 ns was routing, not AES logic.  Keeping
    // one reset sink here lets Quartus place/duplicate a local clear beside
    // the round/key-schedule registers.  AES cannot receive aes_start until
    // the following GCM state, so the one-cycle reset-release latency is free.
`ifdef ITERATIVE_BASELINE_TIMING_FIX
    (* maxfan = 32, preserve, dont_merge *) logic aes_rst_n_q;
    wire aes_reset_n = aes_rst_n_q;
`else
    wire aes_reset_n = rst_n;
`endif
    wire [127:0] active_round_key=round_index[0]?key_odd:key_even;

`ifdef ITERATIVE_BASELINE_TIMING_FIX
    always_ff @(posedge clk) begin
        if(!rst_n) aes_rst_n_q<=1'b0;
        else       aes_rst_n_q<=1'b1;
    end
`endif

    // rst_n is synchronized to clk by the channel top.  Use the local copy for
    // the wide datapath so the board reset is not routed to every AES bit.
    always_ff @(posedge clk) begin
        if(!aes_reset_n) begin
            state<=IDLE; busy<=0; done<=0; block_out<=0; data_reg<=0;
            key_even<=0;key_odd<=0;next_even<=0;schedule_temp<=0;
            round_index<=0;rcon<=1;
`ifdef ITERATIVE_BASELINE_TIMING_FIX
            // The local reset releases one clock after rst_n.  Accept a start
            // presented on that boundary clock instead of dropping the pulse.
            if(rst_n && start) begin
                key_even<=key[255:128];key_odd<=key[127:0];
                next_even<=0;schedule_temp<=0;
                data_reg<=block_in;block_out<=0;rcon<=1;
                round_index<=0;busy<=1;state<=INIT;
            end
`endif
        end else if(zeroize) begin
            state<=IDLE; busy<=0; done<=0; block_out<=0; data_reg<=0;
            key_even<=0;key_odd<=0;next_even<=0;schedule_temp<=0;
            round_index<=0;rcon<=1;
        end else begin
            done<=0;
            case(state)
                IDLE: if(start) begin
                    key_even<=key[255:128];key_odd<=key[127:0];
                    next_even<=0;schedule_temp<=0;
                    data_reg<=block_in;block_out<=0;rcon<=1;
                    round_index<=0; busy<=1; state<=INIT;
                end
                INIT: begin data_reg<=data_reg^key_even;round_index<=1;state<=SUB;end
                SUB: begin data_reg<=subshift(data_reg); state<=(round_index==14)?ADD:MIX; end
                MIX: begin data_reg<=mix(data_reg); state<=ADD; end
                ADD: begin
                    data_reg<=data_reg^active_round_key;
                    if(round_index==14) begin
                        block_out<=data_reg^active_round_key;busy<=0;done<=1;state<=IDLE;
                    end else if(round_index[0]) state<=KS_SUB_EVEN;
                    else begin round_index<=round_index+1'b1;state<=SUB;end
                end
                // Four short key-schedule stages avoid a pair of cascaded
                // S-box layers while retaining only the current 256-bit key.
                KS_SUB_EVEN: begin
                    schedule_temp<=subword({key_odd[23:0],key_odd[31:24]})^{rcon,24'd0};
                    state<=KS_XOR_EVEN;
                end
                KS_XOR_EVEN: begin
                    next_even<=xor_chain(key_even,schedule_temp);state<=KS_SUB_ODD;
                end
                KS_SUB_ODD: begin
                    schedule_temp<=subword(next_even[31:0]);state<=KS_XOR_ODD;
                end
                KS_XOR_ODD: begin
                    key_even<=next_even;
                    key_odd<=xor_chain(key_odd,schedule_temp);
                    rcon<=xt(rcon);round_index<=round_index+1'b1;state<=SUB;
                end
                default: state<=IDLE;
            endcase
        end
    end
endmodule
