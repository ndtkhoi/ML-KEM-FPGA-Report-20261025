`timescale 1ns/1ps
// Legacy module/port name retained. Cyclone V PLL: 50 -> OUTPUT_MHZ.
// Supported targets are 100, 110, 150 and 160 MHz; never generate a clock in LUT logic.
module clock_100 #(parameter integer OUTPUT_MHZ=100)
                (input wire refclk, input wire rst,
                 output wire clk_100, output wire locked);
    generate if (OUTPUT_MHZ != 100 && OUTPUT_MHZ != 110 && OUTPUT_MHZ != 150 && OUTPUT_MHZ != 160) begin : g_bad_frequency
        // Deliberately unresolved: reject unsupported targets in synthesis too.
        unsupported_clock_frequency invalid_clock_configuration();
    end endgenerate
`ifdef SYNTHESIS
    altera_pll #(
        .fractional_vco_multiplier("false"),
        .reference_clock_frequency("50.0 MHz"),
        .operation_mode("normal"), .number_of_clocks(1),
        .output_clock_frequency0(OUTPUT_MHZ == 160 ? "160.0 MHz" :
                                OUTPUT_MHZ == 150 ? "150.0 MHz" :
                                OUTPUT_MHZ == 110 ? "110.0 MHz" : "100.0 MHz"),
        .phase_shift0("0 ps"), .duty_cycle0(50),
        .pll_type("General"), .pll_subtype("General")
    ) u_pll (
        .refclk(refclk), .rst(rst), .outclk(clk_100), .locked(locked),
        .fbclk(1'b0), .fboutclk(), .refclk1(1'b0),
        .phase_en(1'b0), .updn(1'b0), .num_phase_shifts(3'd0),
        .scanclk(1'b0), .cntsel(5'd0), .reconfig_to_pll(64'd0),
        .extswitch(1'b0), .adjpllin(1'b0), .cclk(1'b0),
        .phase_done(), .reconfig_from_pll(), .activeclk(), .clkbad(),
        .phout(), .lvds_clk(), .loaden(), .extclk_out(), .cascade_out(), .zdbfbclk()
    );
`else
    // Mo hinh chuc nang cho ModelSim: KHONG mo phong jitter/PLL vat ly.
    // Testbench phai cap refclk 50 MHz; test rieng kiem tra chu ky/baud.
    localparam realtime HALF_PERIOD_NS=500.0/OUTPUT_MHZ;
    logic sim_clock=0,sim_locked=0;
    integer lock_count=0;
    always @(posedge refclk or posedge rst) begin
        if(rst)begin lock_count<=0;sim_locked<=0;end
        else if(lock_count==15)sim_locked<=1;
        else lock_count<=lock_count+1;
    end
    always #(HALF_PERIOD_NS) begin
        if(rst || !sim_locked)sim_clock=0;
        else sim_clock=~sim_clock;
    end
    assign clk_100=sim_clock;
    assign locked=sim_locked;
`endif
endmodule
