// FIPS 203 Appendix A values for MultiplyNTTs.
// gamma[i] = zeta^(2*BitRev7(i)+1) mod q.
module gammas_rom (
    input  logic [6:0]  pair_index,
    output logic [11:0] gamma
);

    localparam logic [11:0] Q_CONST = 12'd3329;

    logic [6:0]  zeta_address;
    logic [11:0] base_zeta;

    assign zeta_address = 7'd64 + (pair_index >> 1);

    zetas_rom u_zetas (
        .address (zeta_address),
        .zeta    (base_zeta)
    );

    always_comb begin
        if (pair_index[0])
            gamma = Q_CONST - base_zeta;
        else
            gamma = base_zeta;
    end

endmodule
