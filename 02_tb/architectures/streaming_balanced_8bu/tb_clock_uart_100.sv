`timescale 1ns/1ps
// Legacy filename; exercises all supported PLL targets with -gCLOCK_MHZ.
module tb_clock_uart_100 #(parameter integer CLOCK_MHZ=160);
    localparam integer CLOCK_HZ=CLOCK_MHZ*1_000_000;
    localparam integer BIT_CYCLES=(CLOCK_HZ+115200/2)/115200;
    localparam realtime PERIOD_NS=1000.0/CLOCK_MHZ;
    localparam realtime BIT_NS=BIT_CYCLES*PERIOD_NS;
`ifdef SYNTHESIS
    // Intel's generic_pll model periodically re-aligns to refclk. At 110 MHz
    // the rounded 9.090 ns periods include a 9.100 ns correction period.
    localparam realtime EDGE_TOLERANCE_NS=0.020;
`else
    localparam realtime EDGE_TOLERANCE_NS=0.002;
`endif
    logic refclk=0;always #10 refclk=~refclk;
    logic rst=1;wire clk_100,locked;
    clock_100 #(.OUTPUT_MHZ(CLOCK_MHZ)) dut(.*);
    logic meta=0,rst_n=0;
    wire release_n=!rst&&locked;
    always_ff @(posedge clk_100 or negedge release_n)
        if(!release_n)begin meta<=0;rst_n<=0;end else begin meta<=1;rst_n<=meta;end
    logic valid=0;logic [7:0] data=0;
    wire ready,tx,rx_valid;wire [7:0] rx_data;wire framing_error;
    uart_tx #(.CLOCK_HZ(CLOCK_HZ),.BAUD(115200)) utx(
        .clk(clk_100),.rst_n(rst_n),.valid(valid),.data(data),.ready(ready),.tx(tx),.busy(),.done());
    uart_rx #(.CLOCK_HZ(CLOCK_HZ),.BAUD(115200)) urx(
        .clk(clk_100),.rst_n(rst_n),.rx(tx),.data(rx_data),.valid(rx_valid),.framing_error(framing_error),.busy());
    realtime previous_time,start_time,measured_period,measured_bit,window_start,average_period;
    integer k;
    task automatic send_byte(input logic [7:0] b);
        begin
            wait(ready);@(negedge clk_100);data=b;valid=1;
            @(negedge clk_100);valid=0;wait(rx_valid);@(negedge clk_100);
            if(rx_data!==b||framing_error)$fatal(1,"UART mismatch %h/%h",b,rx_data);
            wait(ready);repeat(4)@(negedge clk_100);
        end
    endtask
    initial begin
        repeat(4)@(negedge refclk);rst=0;wait(locked);wait(rst_n);
        @(posedge clk_100);previous_time=$realtime;window_start=$realtime;
        repeat(CLOCK_MHZ*10)begin
            @(posedge clk_100);measured_period=$realtime-previous_time;
            if(measured_period<PERIOD_NS-EDGE_TOLERANCE_NS || measured_period>PERIOD_NS+EDGE_TOLERANCE_NS)
                $fatal(1,"PLL period %0.6f ns expected %0.6f ns",measured_period,PERIOD_NS);
            previous_time=$realtime;
        end
        // A persistent frequency error must fail even if each individual
        // period falls within the vendor model's resynchronization allowance.
        average_period=($realtime-window_start)/(CLOCK_MHZ*10);
        if(average_period<PERIOD_NS-0.002 || average_period>PERIOD_NS+0.002)
            $fatal(1,"average PLL period %0.6f ns expected %0.6f ns",average_period,PERIOD_NS);
        fork
            begin @(negedge tx);start_time=$realtime;@(posedge tx);
                measured_bit=$realtime-start_time;
                // The per-cycle quantization accumulates across BIT_CYCLES.
                if(measured_bit<BIT_NS-2.0 || measured_bit>BIT_NS+2.0)
                    $fatal(1,"wrong baud bit duration %0.6f ns expected %0.6f ns",measured_bit,BIT_NS);
            end
            send_byte(8'h55);
        join
        send_byte(8'h00);send_byte(8'hff);send_byte(8'ha5);
        @(negedge refclk);rst=1;#1;
        if(rst_n!==0)$fatal(1,"reset did not assert");
        repeat(4)@(negedge refclk);rst=0;wait(locked);wait(rst_n);send_byte(8'h3c);
        $display("CLOCK_UART: ALL TESTS PASS ref=50MHz core=%0dMHz cycles_per_bit=%0d measured_bit_ns=%0.3f average_period_ns=%0.6f 115200_8N1 reset_relock",CLOCK_MHZ,BIT_CYCLES,measured_bit,average_period);$finish;
    end
    initial begin #1000000;$fatal(1,"clock/UART timeout");end
endmodule
