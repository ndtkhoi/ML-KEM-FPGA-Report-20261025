module mod_sub #(
    parameter logic [12:0] Q = 13'd3329
) (
    input  logic [11:0] a,
    input  logic [11:0] b,
    output logic [11:0] r
);

    logic [12:0] difference;

    always_comb begin
        // Contract: both operands are canonical coefficients in [0, Q-1].
        // A single extended subtraction exposes the underflow bit directly.
        // The previous compare plus two-branch add/subtract implementation
        // created a long carry/compare/mux cone on the NTT writeback path.
        // With 13 bits, an underflow wraps by 2^13; adding Q therefore
        // restores the canonical representative with one correction adder.
        difference = {1'b0, a} - {1'b0, b};
        if (difference[12])
            difference = difference + Q;
        r = difference[11:0];
    end

endmodule
