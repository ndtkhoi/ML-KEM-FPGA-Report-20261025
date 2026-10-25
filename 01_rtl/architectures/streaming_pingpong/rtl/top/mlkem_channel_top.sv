// Top DE10-Standard: ML-KEM doc lap + HKDF + AES-256-GCM, PLL 160 MHz target.
// UART: JP1-1 TX, JP1-2 RX, 115200-8N1. KEY0 reset va xoa key slot.
// Cac phep toan do PC yeu cau rieng, khong con nut chay ca chuoi.
module mlkem_channel_top #(
    parameter integer CORE_CLOCK_MHZ = 160,
    parameter integer UART_CLOCK_HZ = CORE_CLOCK_MHZ * 1_000_000,
    parameter integer UART_BAUD = 115_200
) (
    input logic CLOCK_50,
    input logic [3:0] KEY,
    input logic [9:0] SW,
    output logic [9:0] LEDR,
    output logic [6:0] HEX0, HEX1, HEX2, HEX3, HEX4, HEX5,
    input logic UART_RX,
    output logic UART_TX
);
    // UART_CLOCK_HZ may be overridden only to accelerate serial simulation.
    // Hardware defaults always follow the actual PLL frequency.
    localparam integer CORE_CLOCK_HZ=CORE_CLOCK_MHZ*1_000_000;
    // Lay mau xap xi moi 10 us. He so le +1 tranh lay mau dung mot pha
    // lap cua PLL/RO; 512 mau khoi dong van chi mat khoang 5.1 ms.
    localparam integer ENTROPY_SAMPLE_DIV=CORE_CLOCK_MHZ*10+1;
    // Tat ca logic dong bo dung clk_sys; UART van 115200-8N1.
    wire clk_sys,pll_locked;
    wire reset_release_n=KEY[0] && pll_locked;
    logic reset_meta_n, reset_sync_n;
    clock_100 #(.OUTPUT_MHZ(CORE_CLOCK_MHZ)) u_clock(
        .refclk(CLOCK_50),.rst(!KEY[0]),.clk_100(clk_sys),.locked(pll_locked));
    wire [7:0] rx_data, tx_data;
    wire rx_valid, rx_error, tx_valid, tx_ready;
    wire raw_bit, raw_valid, health, alarm, startup;
    wire [31:0] samples, checked_samples, rng_crc, rng_cycles, reseeds;
    wire [15:0] rct_fails, apt_fails;
    wire [9:0] apt_ones;
    wire [255:0] rng_d, rng_z, rng_m;
    wire rng_ready, rng_done, rng_busy, rng_generate, rng_zeroize;
    wire service_busy, key_ready, op_done, op_pass;
    wire [7:0] last_error;
    wire [2:0] last_operation;
    wire last_mode;
    wire [3:0] stage;
    wire [31:0] last_cycles;
    wire k_busy,k_done,k_pass,k_mode,c_busy,c_done,c_pass,c_mode,session_active;
    wire [7:0] k_error,c_error;
    wire [1:0] k_op,c_op;
    wire channel_clear,channel_key_valid,channel_key_mode,channel_key_encaps;
    wire [255:0] channel_key;
    wire [7:0] k_tx_data,c_tx_data;
    wire k_tx_valid,c_tx_valid;
    wire [8:0] record_length;
    wire [31:0] tx_packets,rx_packets,auth_fails,replays;
    logic [1:0] route;
    logic last_is_record;
    logic [9:0] sw_meta,sw_sync;
    wire [23:0] kem_display_code;
    // Register the arbitration readiness.  Without this boundary the record
    // FSM state fed k_rx_valid and then the 32-bit KEM timeout clear network in
    // one cycle, creating a long cross-chip path.
    logic dispatch_ready_q;
    wire k_rx_valid=rx_valid && (route==1 || (route==0&&dispatch_ready_q&&rx_data=="!"));
    wire c_rx_valid=rx_valid && (route==2 || (route==0&&dispatch_ready_q&&rx_data=="$"));
    assign tx_valid=(route==1)?k_tx_valid:((route==2)?c_tx_valid:1'b0);
    assign tx_data=(route==1)?k_tx_data:c_tx_data;
    assign service_busy=k_busy||c_busy;
    assign op_done=k_done||c_done;
    assign op_pass=last_is_record?c_pass:k_pass;
    assign last_error=last_is_record?c_error:k_error;
    assign last_mode=last_is_record?c_mode:k_mode;
    assign last_operation=last_is_record?({1'b0,c_op}+3'd4):{1'b0,k_op};
    // reset_sync_n is async-assert/sync-release at the two flops below.  All
    // consumers use it synchronously, giving a full cycle for reset release
    // and eliminating the high-fanout recovery tree from functional logic.
    always_ff @(posedge clk_sys) begin
        if(!reset_sync_n)begin route<=0;last_is_record<=0;sw_meta<=0;sw_sync<=0;dispatch_ready_q<=0;end
        else begin
            sw_meta<=SW;sw_sync<=sw_meta;
            dispatch_ready_q<=!k_busy&&!c_busy;
            if(k_done)last_is_record<=0;
            if(c_done)last_is_record<=1;
            if(route==0)begin
                if(dispatch_ready_q&&rx_valid)begin
                    if(rx_data=="!")route<=1;
                    else if(rx_data=="$")route<=2;
                end
            end else if((route==1&&!k_busy)||(route==2&&!c_busy))route<=0;
        end
    end
    logic have_result;
    logic [4:0] symbols[0:5];
    always_ff @(posedge clk_sys or negedge reset_release_n) begin
        if(!reset_release_n) begin reset_meta_n<=0; reset_sync_n<=0; end
        else begin reset_meta_n<=1; reset_sync_n<=reset_meta_n; end
    end
    always_ff @(posedge clk_sys) begin
        if(!reset_sync_n) have_result<=0;
        else if(op_done) have_result<=1;
    end
    uart_rx #(.CLOCK_HZ(UART_CLOCK_HZ),.BAUD(UART_BAUD)) u_rx(
        .clk(clk_sys),.rst_n(reset_sync_n),.rx(UART_RX),.data(rx_data),
        .valid(rx_valid),.framing_error(rx_error),.busy());
    uart_tx #(.CLOCK_HZ(UART_CLOCK_HZ),.BAUD(UART_BAUD)) u_tx(
        .clk(clk_sys),.rst_n(reset_sync_n),.valid(tx_valid),.data(tx_data),
        .ready(tx_ready),.tx(UART_TX),.busy(),.done());
`ifdef CONTINUOUS_BANKED_TRNG_VER3
    // Ver3: dem cac chuyen tiep RO trong ca cua so lay mau roi tron ba
    // phep chieu cua cac bit dem. Cach nay khai thac jitter tich luy thay
    // vi chi chup pha RO tai mot thoi diem.
    fpga_ro_entropy_ver3 #(.SAMPLE_DIV(ENTROPY_SAMPLE_DIV)) u_trng(
`elsif CONTINUOUS_BANKED_TRNG_VER2
    // Ver2: cac RO 3/5/7 tang duoc tron theo ba bank va lay mau luan
    // phien. Module va macro rieng giup Ver1/Ver2 dung chung phan ML-KEM
    // ma khong thay doi netlist TRNG cua Ver1.
    fpga_ro_entropy_ver2 #(.SAMPLE_DIV(ENTROPY_SAMPLE_DIV)) u_trng(
`else
    // Ver1: 15 RO ba tang, tron dong thoi bang mot cay XOR.
    fpga_ro_entropy #(.RO_COUNT(15),.RO_STAGES(3),.SAMPLE_DIV(ENTROPY_SAMPLE_DIV)) u_trng(
`endif
        .clk(clk_sys),.rst_n(reset_sync_n),.enable(1'b1),
        .raw_bit(raw_bit),.raw_valid(raw_valid),.sample_count(samples));
    entropy_health u_health(
        .clk(clk_sys),.rst_n(reset_sync_n),.clear(1'b0),
        .raw_bit(raw_bit),.raw_valid(raw_valid),.startup_done(startup),
        .health_pass(health),.alarm_latched(alarm),.rct_fail_count(rct_fails),
        .apt_fail_count(apt_fails),.last_apt_ones(apt_ones),.checked_samples(checked_samples));
    mlkem_random_manager u_rng(
        .clk(clk_sys),.rst_n(reset_sync_n),.generate_start(rng_generate),.zeroize(rng_zeroize),
        .raw_bit(raw_bit),.raw_valid(raw_valid),.health_pass(health),.health_alarm(alarm),
        .seed_d(rng_d),.seed_z(rng_z),.message_m(rng_m),.vector_crc32(rng_crc),
        .generate_cycles(rng_cycles),.reseed_count(reseeds),.pool_full(),
        .ready(rng_ready),.busy(rng_busy),.done(rng_done));
    channel_kem_uart #(
        .RX_TIMEOUT_CYCLES(2*CORE_CLOCK_HZ),.RNG_TIMEOUT_CYCLES(3*CORE_CLOCK_HZ),
`ifdef CONTINUOUS_BANKED_BOARD_DEMO
        .MODE_FROM_SWITCH(1)
`else
        .MODE_FROM_SWITCH(0)
`endif
    ) u_service(
        .clk(clk_sys),.rst_n(reset_sync_n),.rx_valid(k_rx_valid),.rx_data(rx_data),.rx_error(rx_error),
        .tx_valid(k_tx_valid),.tx_data(k_tx_data),.tx_ready(tx_ready && route==1),
        .rng_ready(rng_ready),.rng_done(rng_done),.rng_alarm(alarm),.rng_health(health),
        .rng_d(rng_d),.rng_z(rng_z),.rng_m(rng_m),.rng_generate(rng_generate),.rng_zeroize(rng_zeroize),
        .service_busy(k_busy),.key_ready(key_ready),.op_done(k_done),.op_pass(k_pass),
        .last_error(k_error),.last_operation(k_op),.last_mode(k_mode),.stage(stage),.last_cycles(last_cycles),
        .board_mode_1024(sw_sync[0]),.display_code(kem_display_code),
        .channel_clear(channel_clear),.channel_key_valid(channel_key_valid),.channel_key_mode(channel_key_mode),
        .channel_key_encaps(channel_key_encaps),.channel_key(channel_key));
    channel_record_uart #(.RX_TIMEOUT_CYCLES(2*CORE_CLOCK_HZ)) u_record(
        .clk(clk_sys),.rst_n(reset_sync_n),.rx_valid(c_rx_valid),.rx_error(rx_error),.rx_data(rx_data),
        .tx_valid(c_tx_valid),.tx_data(c_tx_data),.tx_ready(tx_ready && route==2),
        .kem_clear(channel_clear),.kem_valid(channel_key_valid),.kem_mode(channel_key_mode),
        .kem_encaps(channel_key_encaps),.kem_secret(channel_key),
        .service_busy(c_busy),.active(session_active),.op_done(c_done),.op_pass(c_pass),.last_error(c_error),
        .last_op(c_op),.last_mode(c_mode),.result_length(record_length),
        .tx_count(tx_packets),.rx_count(rx_packets),.auth_fail_count(auth_fails),.replay_count(replays));
    always_comb begin
`ifdef CONTINUOUS_BANKED_BOARD_DEMO
        // Video-demo board map:
        // LEDR0 mode (0=768, 1=1024), 1 RUN, 2 RNG ready, 3 RNG health,
        // 4 BUSY, 5 key ready, 6 secure session, 7 PASS,
        // 8 authentication attack caught, 9 replay attack caught.
        LEDR={replays!=0,auth_fails!=0,(have_result&&op_pass),session_active,
              key_ready,service_busy,health,rng_ready,reset_sync_n,sw_sync[0]};
        symbols[5]=31;symbols[4]=31;symbols[3]=31;symbols[2]=7;symbols[1]=6;symbols[0]=8;
        if(sw_sync[0]) begin
            symbols[3]=1;symbols[2]=0;symbols[1]=2;symbols[0]=4;
        end
        if(kem_display_code!=0) begin
            symbols[5]={1'b0,kem_display_code[23:20]};symbols[4]={1'b0,kem_display_code[19:16]};
            symbols[3]={1'b0,kem_display_code[15:12]};symbols[2]={1'b0,kem_display_code[11:8]};
            symbols[1]={1'b0,kem_display_code[7:4]};symbols[0]={1'b0,kem_display_code[3:0]};
        end
        if(service_busy) begin
            symbols[5]=19;symbols[4]=20;symbols[3]=21;symbols[2]=16;
            symbols[1]={2'd0,last_operation};symbols[0]={1'd0,stage};
        end else if(have_result&&!op_pass) begin
            symbols[5]=15;symbols[4]=10;symbols[3]=24;symbols[2]=25;
            symbols[1]={1'b0,last_error[7:4]};symbols[0]={1'b0,last_error[3:0]};
        end
        // SW1..SW9 are display pages. Highest-numbered active switch wins.
        if(sw_sync[1]) begin
            symbols[5]={1'b0,rx_packets[11:8]};symbols[4]={1'b0,rx_packets[7:4]};symbols[3]={1'b0,rx_packets[3:0]};
            symbols[2]={1'b0,tx_packets[11:8]};symbols[1]={1'b0,tx_packets[7:4]};symbols[0]={1'b0,tx_packets[3:0]};
        end
        if(sw_sync[2]) begin
            symbols[5]={1'b0,auth_fails[11:8]};symbols[4]={1'b0,auth_fails[7:4]};symbols[3]={1'b0,auth_fails[3:0]};
            symbols[2]={1'b0,replays[11:8]};symbols[1]={1'b0,replays[7:4]};symbols[0]={1'b0,replays[3:0]};
        end
        if(sw_sync[3]) begin
            symbols[5]=19;symbols[4]={1'b0,rct_fails[7:4]};symbols[3]={1'b0,rct_fails[3:0]};
            symbols[2]=10;symbols[1]={1'b0,apt_fails[7:4]};symbols[0]={1'b0,apt_fails[3:0]};
        end
        if(sw_sync[4]) begin
            symbols[5]=17;symbols[4]=10;symbols[3]=18;symbols[2]=18;
            symbols[1]={2'd0,last_operation};symbols[0]=last_mode?5'd4:5'd3;
        end
        if(sw_sync[5]) begin
            symbols[5]={1'b0,kem_display_code[23:20]};symbols[4]={1'b0,kem_display_code[19:16]};
            symbols[3]={1'b0,kem_display_code[15:12]};symbols[2]={1'b0,kem_display_code[11:8]};
            symbols[1]={1'b0,kem_display_code[7:4]};symbols[0]={1'b0,kem_display_code[3:0]};
        end
        if(sw_sync[6]) begin
            symbols[5]=16;symbols[4]={2'd0,last_operation};symbols[3]=16;
            symbols[2]={4'd0,record_length[8]};symbols[1]={1'b0,record_length[7:4]};symbols[0]={1'b0,record_length[3:0]};
        end
        if(sw_sync[7]) begin
            symbols[5]={1'b0,last_cycles[23:20]};symbols[4]={1'b0,last_cycles[19:16]};
            symbols[3]={1'b0,last_cycles[15:12]};symbols[2]={1'b0,last_cycles[11:8]};
            symbols[1]={1'b0,last_cycles[7:4]};symbols[0]={1'b0,last_cycles[3:0]};
        end
        if(sw_sync[8]) begin
            symbols[5]={1'b0,rng_crc[23:20]};symbols[4]={1'b0,rng_crc[19:16]};
            symbols[3]={1'b0,rng_crc[15:12]};symbols[2]={1'b0,rng_crc[11:8]};
            symbols[1]={1'b0,rng_crc[7:4]};symbols[0]={1'b0,rng_crc[3:0]};
        end
        if(sw_sync[9]) begin
            LEDR=10'h3ff;
            symbols[5]=8;symbols[4]=8;symbols[3]=8;symbols[2]=8;symbols[1]=8;symbols[0]=8;
        end
`else
        // LED0 OK, 1 ERROR, 2 KEY_READY, 3 BUSY, 4 SESSION, 5 RX_OK, 6 REPLAY,
        // 7 RNG alarm, 8 health PASS, 9 random ready.
        LEDR={rng_ready,health,alarm,(replays!=0),(rx_packets!=0),
              session_active,service_busy,key_ready,(have_result&&!op_pass),(have_result&&op_pass)};
        symbols[5]=19; symbols[4]=14; symbols[3]=10; symbols[2]=22; symbols[1]=23; symbols[0]=16;
        if(service_busy) begin
            symbols[5]=19; symbols[4]=20; symbols[3]=21; symbols[2]=16;
            symbols[1]={2'd0,last_operation}; symbols[0]={1'd0,stage};
        end else if(have_result) begin
            if(op_pass) begin
                symbols[5]=17; symbols[4]=10; symbols[3]=18; symbols[2]=18;
                symbols[1]={2'd0,last_operation}; symbols[0]=last_mode?5'd4:5'd3;
            end else begin
                symbols[5]=15; symbols[4]=10; symbols[3]=24; symbols[2]=25;
                symbols[1]={1'b0,last_error[7:4]}; symbols[0]={1'b0,last_error[3:0]};
            end
        end
        // Cong tac chi chon man hinh thong ke; khong thay doi giao thuc.
        // SW3: rXXAXX = so lan RCT fail va APT fail (8 bit thap).
        // Man hinh nay cung giu lai hai bo dem chan doan qua Fitter.
        if(sw_sync[3]) begin
            symbols[5]=19;
            symbols[4]={1'b0,rct_fails[7:4]};symbols[3]={1'b0,rct_fails[3:0]};
            symbols[2]=10;
            symbols[1]={1'b0,apt_fails[7:4]};symbols[0]={1'b0,apt_fails[3:0]};
        end else if(sw_sync[0]) begin
            symbols[5]={1'b0,rx_packets[11:8]};symbols[4]={1'b0,rx_packets[7:4]};symbols[3]={1'b0,rx_packets[3:0]};
            symbols[2]={1'b0,tx_packets[11:8]};symbols[1]={1'b0,tx_packets[7:4]};symbols[0]={1'b0,tx_packets[3:0]};
        end else if(sw_sync[1])begin
            symbols[5]={1'b0,auth_fails[11:8]};symbols[4]={1'b0,auth_fails[7:4]};symbols[3]={1'b0,auth_fails[3:0]};
            symbols[2]={1'b0,replays[11:8]};symbols[1]={1'b0,replays[7:4]};symbols[0]={1'b0,replays[3:0]};
        end else if(sw_sync[2])begin
            symbols[5]=16;symbols[4]={2'd0,last_operation};symbols[3]=16;
            symbols[2]={4'd0,record_length[8]};symbols[1]={1'b0,record_length[7:4]};symbols[0]={1'b0,record_length[3:0]};
        end
`endif
    end
    seg7_decode h0(.symbol(symbols[0]),.segments(HEX0));
    seg7_decode h1(.symbol(symbols[1]),.segments(HEX1));
    seg7_decode h2(.symbol(symbols[2]),.segments(HEX2));
    seg7_decode h3(.symbol(symbols[3]),.segments(HEX3));
    seg7_decode h4(.symbol(symbols[4]),.segments(HEX4));
    seg7_decode h5(.symbol(symbols[5]),.segments(HEX5));
endmodule
