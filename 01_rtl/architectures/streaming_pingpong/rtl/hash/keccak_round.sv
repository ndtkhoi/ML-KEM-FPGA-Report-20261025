// One combinational Keccak-f[1600] round: theta, rho, pi, chi and iota.
//
// Lane mapping follows Keccak's x + 5*y convention.  Bytes within a lane are
// little-endian, which matches SHA3/SHAKE absorb and squeeze ordering.
module keccak_round #(
    // A three-phase caller registers theta_d_state and feeds it back on the
    // following clock.  Keeping this as a constant parameter lets the normal
    // two-phase sponge retain its original latency and hardware cone.
    parameter bit REGISTERED_THETA = 1'b0
) (
    input  logic [1599:0] state_in,
    input  logic [63:0]   round_constant,
    input  logic [319:0]  registered_theta_d,
    output logic [1599:0] state_out,
    output logic [1599:0] theta_rho_pi_state,
    output logic [319:0]  theta_d_state
);

    logic [63:0] a [0:4][0:4];
    logic [63:0] theta_state [0:4][0:4];
    logic [63:0] b [0:4][0:4];
    logic [63:0] chi_state [0:4][0:4];
    logic [63:0] c [0:4];
    logic [63:0] d [0:4];

    integer x;
    integer y;

    function automatic [63:0] rotate_left_64;
        input [63:0] value;
        input integer amount;
        begin
            if (amount == 0)
                rotate_left_64 = value;
            else
                rotate_left_64 =
                    (value << amount) | (value >> (64 - amount));
        end
    endfunction

    function automatic integer rho_offset;
        input integer x_coordinate;
        input integer y_coordinate;
        integer lane_index;
        begin
            lane_index = x_coordinate + 5 * y_coordinate;
            case (lane_index)
                0:  rho_offset = 0;
                1:  rho_offset = 1;
                2:  rho_offset = 62;
                3:  rho_offset = 28;
                4:  rho_offset = 27;
                5:  rho_offset = 36;
                6:  rho_offset = 44;
                7:  rho_offset = 6;
                8:  rho_offset = 55;
                9:  rho_offset = 20;
                10: rho_offset = 3;
                11: rho_offset = 10;
                12: rho_offset = 43;
                13: rho_offset = 25;
                14: rho_offset = 39;
                15: rho_offset = 41;
                16: rho_offset = 45;
                17: rho_offset = 15;
                18: rho_offset = 21;
                19: rho_offset = 8;
                20: rho_offset = 18;
                21: rho_offset = 2;
                22: rho_offset = 61;
                23: rho_offset = 56;
                24: rho_offset = 14;
                default: rho_offset = 0;
            endcase
        end
    endfunction

    always_comb begin
        for (y = 0; y < 5; y = y + 1)
            for (x = 0; x < 5; x = x + 1)
                a[x][y] = state_in[64 * (x + 5 * y) +: 64];

        // Theta
        for (x = 0; x < 5; x = x + 1)
            c[x] =
                a[x][0] ^ a[x][1] ^ a[x][2] ^ a[x][3] ^ a[x][4];

        for (x = 0; x < 5; x = x + 1)
            begin
            d[x] =
                c[(x + 4) % 5] ^
                rotate_left_64(c[(x + 1) % 5], 1);
            theta_d_state[64*x +: 64] = d[x];
            end

        for (y = 0; y < 5; y = y + 1)
            for (x = 0; x < 5; x = x + 1)
                theta_state[x][y] = a[x][y] ^
                    (REGISTERED_THETA ?
                        registered_theta_d[64*x +: 64] : d[x]);

        // Initialize B before the Rho/Pi permutation so every element has a
        // deterministic assignment under older SystemVerilog tools.
        for (y = 0; y < 5; y = y + 1)
            for (x = 0; x < 5; x = x + 1)
                b[x][y] = 64'd0;

        // Rho and Pi
        for (y = 0; y < 5; y = y + 1)
            for (x = 0; x < 5; x = x + 1)
                b[y][(2 * x + 3 * y) % 5] =
                    rotate_left_64(theta_state[x][y], rho_offset(x, y));

        // Chi
        for (y = 0; y < 5; y = y + 1)
            for (x = 0; x < 5; x = x + 1)
                chi_state[x][y] =
                    b[x][y] ^ ((~b[(x + 1) % 5][y]) & b[(x + 2) % 5][y]);

        // Iota
        chi_state[0][0] = chi_state[0][0] ^ round_constant;

        for (y = 0; y < 5; y = y + 1)
            for (x = 0; x < 5; x = x + 1) begin
                state_out[64 * (x + 5 * y) +: 64] = chi_state[x][y];
                theta_rho_pi_state[64 * (x + 5 * y) +: 64] = b[x][y];
            end
    end

endmodule
