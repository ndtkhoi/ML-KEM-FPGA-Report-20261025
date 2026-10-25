// Baseline architecture: one in-place polynomial RAM and one shared modular
// multiplier.  A butterfly must finish before the next butterfly is issued.
// This preserves the FIPS 203 transform while intentionally exposing the
// latency of a conventional resource-shared iterative schedule.
module ntt_core (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        start,
    input  logic        inverse,
    input  logic        load_we,
    input  logic [7:0]  load_address,
    input  logic [11:0] load_data,
    input  logic [7:0]  read_address,
    output logic [11:0] read_data,
    output logic        busy,
    output logic        done,
    output logic [31:0] cycle_count,
    output logic [7:0]  debug_length,
    output logic [7:0]  debug_j,
    output logic [6:0]  debug_zeta_index
);

    typedef enum logic [3:0] {
        S_IDLE,
        S_GROUP_BEGIN,
        S_READ,
        S_CAPTURE,
        S_LAUNCH,
        S_WAIT,
        S_WRITE,
        S_SCALE_READ,
        S_SCALE_CAPTURE,
        S_SCALE_LAUNCH,
        S_SCALE_WAIT,
        S_SCALE_WRITE,
        S_FINISH
    } state_t;

    state_t state;
    logic inverse_latched;
    logic [7:0] length_reg;
    logic [7:0] j_index;
    logic [7:0] group_offset;
    logic [6:0] zeta_index;
    logic [7:0] scale_index;

    logic [7:0] ram_addr_a, ram_addr_b;
    logic ram_we_a, ram_we_b;
    logic [11:0] ram_data_a, ram_data_b;
    logic [11:0] ram_q_a, ram_q_b;

    logic [11:0] zeta_value, zeta_reg;
    logic [11:0] coefficient_a_reg, coefficient_b_reg;
    logic [11:0] result_a_reg, result_b_reg;
    logic [11:0] scale_value_reg, scale_result_reg;

    logic mul_in_valid, mul_out_valid;
    logic [11:0] mul_a, mul_b, mul_result;
    logic [11:0] forward_sum, forward_difference;
    logic [11:0] inverse_sum, inverse_difference;

    assign debug_length     = length_reg;
    assign debug_j          = j_index;
    assign debug_zeta_index = zeta_index;
    assign read_data        = ram_q_a;

    zetas_rom u_zetas (
        .address (zeta_index),
        .zeta    (zeta_value)
    );

    mod_add u_forward_add (
        .a (coefficient_a_reg),
        .b (mul_result),
        .r (forward_sum)
    );

    mod_sub u_forward_sub (
        .a (coefficient_a_reg),
        .b (mul_result),
        .r (forward_difference)
    );

    mod_add u_inverse_add (
        .a (coefficient_a_reg),
        .b (coefficient_b_reg),
        .r (inverse_sum)
    );

    mod_sub u_inverse_sub (
        .a (coefficient_b_reg),
        .b (coefficient_a_reg),
        .r (inverse_difference)
    );

    assign mul_in_valid = (state == S_LAUNCH) ||
                          (state == S_SCALE_LAUNCH);
    assign mul_a = (state == S_SCALE_LAUNCH) ? scale_value_reg :
                   (inverse_latched ? inverse_difference : coefficient_b_reg);
    assign mul_b = (state == S_SCALE_LAUNCH) ? 12'd3303 : zeta_reg;

    mod_mul_pipe u_shared_multiply (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid (mul_in_valid),
        .a         (mul_a),
        .b         (mul_b),
        .out_valid(mul_out_valid),
        .r         (mul_result)
    );

    // One true dual-port M10K is shared by load/read, butterflies and the
    // final INTT scale pass.  There is no second plane for overlapped stages.
    always_comb begin
        ram_addr_a = 8'd0;
        ram_addr_b = 8'd0;
        ram_we_a   = 1'b0;
        ram_we_b   = 1'b0;
        ram_data_a = result_a_reg;
        ram_data_b = result_b_reg;

        case (state)
            S_IDLE: begin
                ram_addr_a = load_we ? load_address : read_address;
                ram_we_a   = load_we;
                ram_data_a = load_data;
            end

            S_READ,
            S_CAPTURE,
            S_LAUNCH,
            S_WAIT: begin
                ram_addr_a = j_index;
                ram_addr_b = j_index + length_reg;
            end

            S_WRITE: begin
                ram_addr_a = j_index;
                ram_addr_b = j_index + length_reg;
                ram_we_a   = 1'b1;
                ram_we_b   = 1'b1;
            end

            S_SCALE_READ,
            S_SCALE_CAPTURE,
            S_SCALE_LAUNCH,
            S_SCALE_WAIT: begin
                ram_addr_a = scale_index;
            end

            S_SCALE_WRITE: begin
                ram_addr_a = scale_index;
                ram_we_a   = 1'b1;
                ram_data_a = scale_result_reg;
            end

            default: begin
                ram_addr_a = 8'd0;
                ram_addr_b = 8'd0;
            end
        endcase
    end

    poly_ram_dp u_in_place_memory (
        .clk   (clk),
        .we_a  (ram_we_a),
        .addr_a(ram_addr_a),
        .data_a(ram_data_a),
        .q_a   (ram_q_a),
        .we_b  (ram_we_b),
        .addr_b(ram_addr_b),
        .data_b(ram_data_b),
        .q_b   (ram_q_b)
    );

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state                 <= S_IDLE;
            inverse_latched       <= 1'b0;
            length_reg            <= 8'd0;
            j_index               <= 8'd0;
            group_offset          <= 8'd0;
            zeta_index            <= 7'd0;
            scale_index           <= 8'd0;
            zeta_reg              <= 12'd0;
            coefficient_a_reg     <= 12'd0;
            coefficient_b_reg     <= 12'd0;
            result_a_reg          <= 12'd0;
            result_b_reg          <= 12'd0;
            scale_value_reg       <= 12'd0;
            scale_result_reg      <= 12'd0;
            busy                  <= 1'b0;
            done                  <= 1'b0;
            cycle_count           <= 32'd0;
        end else begin
            done <= 1'b0;
            if (busy)
                cycle_count <= cycle_count + 32'd1;

            case (state)
                S_IDLE: begin
                    if (start) begin
                        inverse_latched <= inverse;
                        length_reg      <= inverse ? 8'd2 : 8'd128;
                        j_index         <= 8'd0;
                        group_offset    <= 8'd0;
                        zeta_index      <= inverse ? 7'd127 : 7'd1;
                        scale_index     <= 8'd0;
                        cycle_count     <= 32'd0;
                        busy            <= 1'b1;
                        state           <= S_GROUP_BEGIN;
                    end
                end

                S_GROUP_BEGIN: begin
                    zeta_reg <= zeta_value;
                    state    <= S_READ;
                end

                S_READ: begin
                    state <= S_CAPTURE;
                end

                S_CAPTURE: begin
                    coefficient_a_reg <= ram_q_a;
                    coefficient_b_reg <= ram_q_b;
                    state             <= S_LAUNCH;
                end

                S_LAUNCH: begin
                    state <= S_WAIT;
                end

                S_WAIT: begin
                    if (mul_out_valid) begin
                        if (inverse_latched) begin
                            result_a_reg <= inverse_sum;
                            result_b_reg <= mul_result;
                        end else begin
                            result_a_reg <= forward_sum;
                            result_b_reg <= forward_difference;
                        end
                        state <= S_WRITE;
                    end
                end

                S_WRITE: begin
                    if (group_offset == length_reg - 8'd1) begin
                        group_offset <= 8'd0;
                        zeta_index   <= inverse_latched ?
                                        zeta_index - 7'd1 :
                                        zeta_index + 7'd1;

                        if ((j_index + length_reg) >= 8'd255) begin
                            j_index <= 8'd0;
                            if ((!inverse_latched && length_reg == 8'd2)) begin
                                state <= S_FINISH;
                            end else if (inverse_latched &&
                                         length_reg == 8'd128) begin
                                scale_index <= 8'd0;
                                state       <= S_SCALE_READ;
                            end else begin
                                length_reg <= inverse_latched ?
                                              (length_reg << 1) :
                                              (length_reg >> 1);
                                state <= S_GROUP_BEGIN;
                            end
                        end else begin
                            j_index <= j_index + length_reg + 8'd1;
                            state   <= S_GROUP_BEGIN;
                        end
                    end else begin
                        group_offset <= group_offset + 8'd1;
                        j_index      <= j_index + 8'd1;
                        state        <= S_READ;
                    end
                end

                S_SCALE_READ: begin
                    state <= S_SCALE_CAPTURE;
                end

                S_SCALE_CAPTURE: begin
                    scale_value_reg <= ram_q_a;
                    state           <= S_SCALE_LAUNCH;
                end

                S_SCALE_LAUNCH: begin
                    state <= S_SCALE_WAIT;
                end

                S_SCALE_WAIT: begin
                    if (mul_out_valid) begin
                        scale_result_reg <= mul_result;
                        state            <= S_SCALE_WRITE;
                    end
                end

                S_SCALE_WRITE: begin
                    if (scale_index == 8'd255)
                        state <= S_FINISH;
                    else begin
                        scale_index <= scale_index + 8'd1;
                        state       <= S_SCALE_READ;
                    end
                end

                S_FINISH: begin
                    busy  <= 1'b0;
                    done  <= 1'b1;
                    state <= S_IDLE;
                end

                default: begin
                    busy  <= 1'b0;
                    state <= S_IDLE;
                end
            endcase
        end
    end

endmodule
