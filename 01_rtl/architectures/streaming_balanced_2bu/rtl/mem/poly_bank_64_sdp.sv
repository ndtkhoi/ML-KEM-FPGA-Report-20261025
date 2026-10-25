// One of 4 synchronous 1R1W banks. Total store is 256 x 12 bits.
module poly_bank_64_sdp (
    input logic clk,
    input logic [5:0] read_address,
    output logic [11:0] read_data,
    input logic write_enable,
    input logic [5:0] write_address,
    input logic [11:0] write_data
);
    (* ramstyle = "no_rw_check, M10K" *) logic [11:0] memory [0:63];
    always_ff @(posedge clk) begin
        read_data <= memory[read_address];
        if(write_enable) memory[write_address] <= write_data;
    end
endmodule
