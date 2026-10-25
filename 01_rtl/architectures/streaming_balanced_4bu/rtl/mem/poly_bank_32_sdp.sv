// One eighth of the four-butterfly conflict-free NTT store.
// Each logical polynomial coefficient is held exactly once.  The companion
// ntt_core_stream4 maps an address to {xor(address[7:2]), address[1:0]}; the
// remaining five address bits select one of the 32 rows in this bank.
module poly_bank_32_sdp (
    input  logic        clk,
    input  logic [4:0]  read_address,
    output logic [11:0] read_data,
    input  logic        write_enable,
    input  logic [4:0]  write_address,
    input  logic [11:0] write_data
);

    (* ramstyle = "no_rw_check, M10K" *) logic [11:0] memory [0:31];

    always_ff @(posedge clk) begin
        read_data <= memory[read_address];
        if (write_enable)
            memory[write_address] <= write_data;
    end

endmodule

