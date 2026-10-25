module mod_add #(
    parameter logic [12:0] Q = 13'd3329
) (
    input  logic [11:0] a,
    input  logic [11:0] b,
    output logic [11:0] r
);

    logic [12:0] sum;
    logic [12:0] corrected_sum;

    always_comb begin
        // Contract: both operands are canonical coefficients in [0, Q-1].
        sum = {1'b0, a} + {1'b0, b};
        corrected_sum = sum;

        if (sum >= Q)
            corrected_sum = sum - Q;

        r = corrected_sum[11:0];
    end

endmodule
