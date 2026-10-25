// One of 16 synchronous 1R1W banks. Total store is 256 x 12 bits.
module poly_bank_16_sdp (
    input logic clk,
    input logic [3:0] read_address,
    output logic [11:0] read_data,
    input logic write_enable,
    input logic [3:0] write_address,
    input logic [11:0] write_data
);
    (* ramstyle = "no_rw_check, M10K" *) logic [11:0] memory [0:15];
    always_ff @(posedge clk) begin
        read_data <= memory[read_address];
        if(write_enable) memory[write_address] <= write_data;
    end
endmodule
