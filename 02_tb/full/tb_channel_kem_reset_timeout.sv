`timescale 1ns/1ps
// Exercise the actual UART parser, not a model of the lookahead equations.
module tb_channel_kem_reset_timeout;
    logic clk=0; always #5 clk=~clk;
    logic rst_n=0,rx_valid=0,rx_error=0;
    logic [7:0] rx_data=0;
    wire tx_valid; wire [7:0] tx_data;
    logic rng_ready=0,rng_done=0,rng_alarm=0;
    logic [255:0] rng_d=256'h1234,rng_z=256'h5678,rng_m=256'h9abc;
    wire rng_generate,rng_zeroize,service_busy,key_ready,op_done,op_pass;
    wire [7:0] last_error; wire [1:0] last_operation;
    wire last_mode; wire [3:0] stage; wire [31:0] last_cycles;
    wire [23:0] display_code;
    wire channel_clear,channel_key_valid,channel_key_mode,channel_key_encaps;
    wire [255:0] channel_key;
    channel_kem_uart #(.RX_TIMEOUT_CYCLES(40),.RNG_TIMEOUT_CYCLES(12)) dut(
        .clk(clk),.rst_n(rst_n),.rx_valid(rx_valid),.rx_data(rx_data),.rx_error(rx_error),
        .tx_valid(tx_valid),.tx_data(tx_data),.tx_ready(1'b1),
        .rng_ready(rng_ready),.rng_done(rng_done),.rng_alarm(rng_alarm),.rng_health(1'b1),
        .rng_d(rng_d),.rng_z(rng_z),.rng_m(rng_m),.rng_generate(rng_generate),.rng_zeroize(rng_zeroize),
        .service_busy(service_busy),.key_ready(key_ready),.op_done(op_done),.op_pass(op_pass),
        .last_error(last_error),.last_operation(last_operation),.last_mode(last_mode),.stage(stage),
        .last_cycles(last_cycles),.board_mode_1024(1'b0),.display_code(display_code),
        .channel_clear(channel_clear),.channel_key_valid(channel_key_valid),.channel_key_mode(channel_key_mode),
        .channel_key_encaps(channel_key_encaps),.channel_key(channel_key));
    task automatic step; @(posedge clk); #1; endtask
    task automatic reset_one;
        @(negedge clk); rst_n=0; rx_valid=0; rng_done=0; rng_ready=0; rng_alarm=0;
        #1;
        if(tx_valid || dut.core_start || dut.core_load_valid || channel_key_valid)
            $fatal(1,"Reset did not immediately mask outward commands");
        step(); @(negedge clk); rst_n=1;
        step();
        if(dut.core_start || dut.core_load_valid || tx_valid)
            $fatal(1,"Stale parser command on reset handoff");
        // The KEM core also scrubs its 8192-entry stores during reset.
        // Its 4096 write pairs outlast the parser's 1600-byte frame scrub.
        repeat(5000) step();
        if(service_busy || dut.seed_d!==0 || dut.seed_z!==0 || dut.message_m!==0)
            $fatal(1,"Parser reset/scrub incomplete");
    endtask
    task automatic put(input logic [7:0] b);
        @(negedge clk); rx_data=b; rx_valid=1;
        step(); @(negedge clk);rx_valid=0;step();
    endtask
    function automatic logic [31:0] crc(input logic [31:0] old,input byte b);
        logic [31:0] x; integer k;
        begin x=old^b;for(k=0;k<8;k++)x=x[0]?((x>>1)^32'hedb88320):(x>>1);crc=x;end
    endfunction
    task automatic rng_request;
        string body,frame;logic [31:0] c;integer i;
        begin body="K710000";c=32'hffffffff;
            for(i=0;i<body.len();i++) c=crc(c,body.getc(i));
            frame={"!",body,$sformatf("%08x",~c),"\n"};
            for(i=0;i<frame.len();i++)put(frame.getc(i));
            repeat(2)step();
        end
    endtask
    function automatic byte hex_digit(input logic [3:0] x);
        hex_digit=(x<10)?8'h30+x:8'h61+x-10;
    endfunction
    task automatic adjacent_seed_request;
        string body,frame;logic [31:0] c;integer i,t;
        logic [255:0] expected_d,expected_z;
        begin
            body="K700040";expected_d=0;expected_z=0;
            for(i=0;i<64;i++)begin
                body={body,hex_digit((i>>4)&15),hex_digit(i&15)};
                if(i<32)expected_d[8*i+:8]=i;
                else expected_z[8*(i-32)+:8]=i;
            end
            c=32'hffffffff;
            for(i=0;i<body.len();i++)c=crc(c,body.getc(i));
            frame={"!",body,$sformatf("%08x",~c),"\n"};
            for(i=0;i<frame.len();i++)begin
                @(negedge clk);rx_valid=1;rx_data=frame.getc(i);step();
            end
            @(negedge clk);rx_valid=0;
            t=0;while(!dut.core_start && t<400)begin step();t++;end
            if(!dut.core_start || last_error!=0 || dut.seed_d!==expected_d || dut.seed_z!==expected_z)
                $fatal(1,"Adjacent-byte UART payload/CRC/seed mismatch");
        end
    endtask
    task automatic timeout_at(input integer limit,input logic [7:0] code);
        integer watchdog;
        begin
            watchdog=0;
            while(dut.timeout_count<limit && last_error==0 && watchdog<100)begin step();watchdog++;end
            if(last_error!=0 || dut.timeout_count!=limit)
                $fatal(1,"Timeout arrived early count=%0d code=%h",dut.timeout_count,last_error);
            step();
            if(last_error!=code)$fatal(1,"Timeout boundary delayed count=%0d code=%h",dut.timeout_count,last_error);
        end
    endtask
    initial begin
        reset_one();put("!");timeout_at(40,8'hf3);
        reset_one();rng_request();
        if(dut.state!=dut.RNG_READY)$fatal(1,"Expected RNG_READY");
        timeout_at(12,8'he1);
        reset_one();rng_request();
        @(negedge clk);rng_ready=1;step();
        if(dut.state!=dut.RNG_WAIT)$fatal(1,"Expected RNG_WAIT");
        timeout_at(12,8'he1);
        reset_one();rng_request();@(negedge clk);rng_ready=1;step();
        @(negedge clk);rng_done=1;step();
        if(dut.seed_d!==rng_d || dut.seed_z!==rng_z || dut.message_m!==rng_m || !dut.core_start)
            $fatal(1,"Valid RNG result not captured/launched");
        // Reset exactly while LAUNCH is asserted: stale start must be masked.
        reset_one();rng_request();@(negedge clk);rng_ready=1;step();
        // Reset while waiting for RNG, then accept a fresh request.
        reset_one();rng_request();@(negedge clk);rng_alarm=1;step();
        if(last_error!=8'he1 || dut.core_start)$fatal(1,"Alarm not rejected");
        reset_one();adjacent_seed_request();reset_one();
        $display("CHANNEL_KEM_RESET_TIMEOUT: PASS exact_RX_RNG_deadlines one_clock_reset launch_mask restart alarm adjacent_payload");
        $finish;
    end
    initial begin #1000000;$fatal(1,"Parser reset/timeout watchdog");end
endmodule
