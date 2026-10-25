// Simple true dual-port polynomial memory.
//
// The read ports are synchronous.  No reset is applied to the memory array so
// Quartus can infer an M10K block instead of registers.
module poly_ram_dp #(
    parameter integer DATA_WIDTH = 12,
    parameter integer ADDR_WIDTH = 8,
    parameter integer DEPTH      = 256
) (
    input  logic                  clk,

    input  logic                  we_a,
    input  logic [ADDR_WIDTH-1:0] addr_a,
    input  logic [DATA_WIDTH-1:0] data_a,
    output logic [DATA_WIDTH-1:0] q_a,

    input  logic                  we_b,
    input  logic [ADDR_WIDTH-1:0] addr_b,
    input  logic [DATA_WIDTH-1:0] data_b,
    output logic [DATA_WIDTH-1:0] q_b
);

    // Quartus Prime 18.1 recognizes this as a true dual-port synchronous RAM.
    // "no_rw_check" avoids adding bypass logic for the intentionally undefined
    // case where both ports access the same address while either port writes.
    (* ramstyle = "no_rw_check, M10K" *)
    logic [DATA_WIDTH-1:0] memory [0:DEPTH-1];

    always_ff @(posedge clk) begin
        if (we_a)
            memory[addr_a] <= data_a;
        q_a <= memory[addr_a];
    end

    always_ff @(posedge clk) begin
        if (we_b)
            memory[addr_b] <= data_b;
        q_b <= memory[addr_b];
    end

endmodule
