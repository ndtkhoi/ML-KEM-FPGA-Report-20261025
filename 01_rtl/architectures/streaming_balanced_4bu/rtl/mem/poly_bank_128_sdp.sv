// One half of a conflict-free in-place polynomial store.
// Port A performs one synchronous read while port B performs one write.
module poly_bank_128_sdp (
    input  logic        clk,
    input  logic [6:0]  read_address,
    output logic [11:0] read_data,
    input  logic        write_enable,
    input  logic [6:0]  write_address,
    input  logic [11:0] write_data
);

    (* ramstyle = "no_rw_check, M10K" *) logic [11:0] memory [0:127];

    always_ff @(posedge clk) begin
        read_data <= memory[read_address];
        if (write_enable)
            memory[write_address] <= write_data;
    end

endmodule
