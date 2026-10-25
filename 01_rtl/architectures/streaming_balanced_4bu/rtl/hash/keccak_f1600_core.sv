// Iterative Keccak-f[1600]: two clocks per round (theta/rho/pi, then chi/iota).
// The round constant and index remain stable across both pipeline phases.
module keccak_f1600_core #(
    parameter bit REGISTER_READ   = 1'b0,
    // Sponge/DRBG clients always present lanes 0..24 in order.  In that mode
    // shift the state while loading, so every input bit drives one state bit
    // instead of a 25-way variable-write fanout.  Keep indexed loading as the
    // default for the standalone core interface and its unit tests.
    parameter bit SEQUENTIAL_LOAD = 1'b0,
    // The DRBG can select a registered theta boundary to prevent the global
    // column-parity network from becoming the 160 MHz critical path.  Sponge
    // clients keep the two-phase default and therefore keep their latency.
    parameter bit THREE_PHASE_ROUND = 1'b0,
    // Integrated sponge/DRBG instances already hold zeroize high through
    // reset using a local register.  They can disable the chip-wide reset on
    // this control bank; standalone users retain the conventional default.
    parameter bit DIRECT_CONTROL_RESET = 1'b1,
    // Some clients scrub all 25 lanes through the sequential-load port.  They
    // can then keep zeroize on the small control plane without building a
    // 1600-bit synchronous-clear network on the permutation state.
    parameter bit ZEROIZE_DATAPATH = 1'b1
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        zeroize,
    input  logic        start,

    input  logic        load_we,
    input  logic [4:0]  load_lane_index,
    input  logic [63:0] load_lane_data,

    input  logic [4:0]  read_lane_index,
    output logic [63:0] read_lane_data,

    output logic        busy,
    output logic        done,
    output logic [6:0]  cycle_count,
    output logic [4:0]  debug_round_index
);

    logic [1599:0] state;
    logic [1599:0] next_round_state;
    logic [1599:0] theta_rho_pi_state;
    logic [1599:0] round_mid;
    logic [319:0]  theta_d_state;
    logic [319:0]  theta_d_q;
    logic [1:0]    round_phase;
    logic [24:0]   theta_lane_enable;
    logic [24:0]   chi_lane_enable;
    logic [4:0]    round_index;
    logic [63:0]   round_constant;

    generate if (REGISTER_READ) begin : g_registered_read
        // Thanh ghi cat duong mux 25 lane -> ghi du lieu vao khoi goi.
        always_ff @(posedge clk)
            if (zeroize) read_lane_data <= 64'd0;
            else read_lane_data <= (read_lane_index < 25) ? state[64 * read_lane_index +: 64] : 64'd0;
    end else begin : g_async_read
        assign read_lane_data = zeroize ? 64'd0 : state[64 * read_lane_index +: 64];
    end endgenerate
    assign debug_round_index = round_index;

    keccak_round_constants u_round_constants (
        .round_index    (round_index),
        .round_constant (round_constant)
    );

    keccak_round #(
        .REGISTERED_THETA(THREE_PHASE_ROUND)
    ) u_round (
        .state_in       (state),
        .round_constant (round_constant),
        .registered_theta_d(theta_d_q),
        .state_out      (),
        .theta_rho_pi_state(theta_rho_pi_state),
        .theta_d_state  (theta_d_state)
    );

    genvar x, y;
    generate for (y=0; y<5; y=y+1) begin : g_chi_y
        for (x=0; x<5; x=x+1) begin : g_chi_x
            assign next_round_state[64*(x+5*y)+:64] =
                round_mid[64*(x+5*y)+:64] ^
                ((~round_mid[64*((x+1)%5+5*y)+:64]) &
                    round_mid[64*((x+2)%5+5*y)+:64]) ^
                ((x==0 && y==0) ? round_constant : 64'd0);
        end
    end endgenerate

    // A single busy/phase decode used to drive the synchronous-load control
    // of all 1600 state bits.  On Cyclone V that net reached more than 1700
    // loads and became a chip-spanning timing path.  Materialize one kept
    // decode per 64-bit lane so each control branch is physically local.
    genvar control_lane;
    generate for (control_lane=0; control_lane<25;
                  control_lane=control_lane+1) begin : g_phase_control
        (* keep = "true", maxfan = 64 *)
        wire theta_enable_local = busy &&
            (round_phase == (THREE_PHASE_ROUND ? 2'd1 : 2'd0));
        (* keep = "true", maxfan = 64 *)
        wire chi_enable_local = busy &&
            (round_phase == (THREE_PHASE_ROUND ? 2'd2 : 2'd1));
        assign theta_lane_enable[control_lane] = theta_enable_local;
        assign chi_lane_enable[control_lane]   = chi_enable_local;
    end endgenerate

    // The 3200-bit permutation datapath is always fully initialized before it
    // is consumed: clients load all 25 state lanes before start, and phase 0
    // writes every round_mid bit before phase 1 reads it.  Do not put the
    // chip-wide reset on these data registers; it creates thousands of long
    // synchronous-reset data paths.  Explicit zeroize still physically clears
    // both banks, while the small control plane below remains reset normally.
    always_ff @(posedge clk) begin : p_datapath
        if (ZEROIZE_DATAPATH && zeroize) begin
            state     <= 1600'd0;
            round_mid <= 1600'd0;
            theta_d_q <= 320'd0;
        end else begin
            if (THREE_PHASE_ROUND && busy && round_phase == 2'd0)
                theta_d_q <= theta_d_state;

            if (!busy && load_we) begin
                if (SEQUENTIAL_LOAD) begin
                    state <= {load_lane_data, state[1599:64]};
                    // A client that disables the wide zeroize network uses a
                    // full 25-lane zero load for scrubbing.  Shift the two
                    // transient banks at the same time so zeroization covers
                    // every permutation register, not only retained state.
                    if (!ZEROIZE_DATAPATH) begin
                        round_mid <= {64'd0, round_mid[1599:64]};
                        theta_d_q <= {64'd0, theta_d_q[319:64]};
                    end
                end else begin
                    state[64 * load_lane_index +: 64] <= load_lane_data;
                end
            end

            for (integer lane_index=0; lane_index<25;
                 lane_index=lane_index+1) begin
                if (theta_lane_enable[lane_index]) begin
                    round_mid[64*lane_index +: 64] <=
                        theta_rho_pi_state[64*lane_index +: 64];
                end else if (chi_lane_enable[lane_index]) begin
                    state[64*lane_index +: 64] <=
                        next_round_state[64*lane_index +: 64];
                    round_mid[64*lane_index +: 64] <= 64'd0;
                end
            end
        end
    end

    always_ff @(posedge clk) begin : p_control
        if ((DIRECT_CONTROL_RESET && !rst_n) || zeroize) begin
            round_phase <= 2'd0;
            round_index <= 5'd0;
            busy        <= 1'b0;
            done        <= 1'b0;
            cycle_count <= 7'd0;
        end else begin
            done <= 1'b0;

            if (!busy && start) begin
                round_phase <= 2'd0;
                round_index <= 5'd0;
                cycle_count <= 7'd0;
                busy        <= 1'b1;
            end else if (busy) begin
                cycle_count <= cycle_count + 7'd1;
                if (round_phase != (THREE_PHASE_ROUND ? 2'd2 : 2'd1))
                    round_phase <= round_phase + 2'd1;
                else begin
                    round_phase <= 2'd0;
                    if (round_index == 5'd23) begin
                        busy <= 1'b0;
                        done <= 1'b1;
                    end else begin
                        round_index <= round_index + 5'd1;
                    end
                end
            end
        end
    end

endmodule
