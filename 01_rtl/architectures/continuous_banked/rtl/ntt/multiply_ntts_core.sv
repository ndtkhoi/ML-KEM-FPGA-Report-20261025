// Continuous FIPS 203 BaseCaseMultiply stream with deterministic commit order.
// Pair tags and the gamma-delay FIFO are replaced by two small mirror counters.
// Results write directly from the registered multiplier output through one
// modular adder, removing the final result/tag register stage.
module multiply_ntts_core (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        start,
    input  logic        load_a_we,
    input  logic        load_b_we,
    input  logic [7:0]  load_address,
    input  logic [11:0] load_a_data,
    input  logic [11:0] load_b_data,
    input  logic [7:0]  read_address,
    output logic [11:0] read_data,
    output logic        busy,
    output logic        done,
    output logic [31:0] cycle_count,
    output logic [6:0]  debug_pair_index
);

    localparam integer MUL_STAGES = 7;
    typedef enum logic [1:0] {S_IDLE, S_ISSUE, S_DRAIN} state_t;
    state_t state;

    logic [6:0] pair_index;
    logic [6:0] first_result_pair, write_pair;
    logic       issue_valid, read_valid, write_valid;

    logic [7:0] input_addr_a, input_addr_b;
    logic [7:0] result_addr_a, result_addr_b;
    logic [11:0] a_q_a, a_q_b, b_q_a, b_q_b;
    logic [11:0] result_q_a, result_q_b;

    logic [3:0] product_valid;
    logic       gamma_valid;
    logic [11:0] a0_b0, a1_b1, a0_b1, a1_b0;
    logic [11:0] gamma, gamma_product;
    logic [11:0] c0_sum, c1_sum;
    logic [11:0] a0b0_delay [0:MUL_STAGES-1];
    logic [11:0] c1_delay [0:MUL_STAGES-1];
    integer pipeline_index;

    assign debug_pair_index = pair_index;
    assign issue_valid       = state == S_ISSUE;
    assign input_addr_a      = (state == S_IDLE) ? load_address :
                               {pair_index, 1'b0};
    assign input_addr_b      = {pair_index, 1'b1};
    assign result_addr_a     = (state == S_IDLE) ? read_address :
                               {write_pair, 1'b0};
    assign result_addr_b     = {write_pair, 1'b1};
    assign write_valid       = gamma_valid && busy;
    assign read_data         = result_q_a;

    poly_ram_dp u_input_a (
        .clk(clk),
        .we_a(load_a_we && state == S_IDLE),
        .addr_a(input_addr_a),
        .data_a(load_a_data),
        .q_a(a_q_a),
        .we_b(1'b0),
        .addr_b(input_addr_b),
        .data_b(12'd0),
        .q_b(a_q_b)
    );

    poly_ram_dp u_input_b (
        .clk(clk),
        .we_a(load_b_we && state == S_IDLE),
        .addr_a(input_addr_a),
        .data_a(load_b_data),
        .q_a(b_q_a),
        .we_b(1'b0),
        .addr_b(input_addr_b),
        .data_b(12'd0),
        .q_b(b_q_b)
    );

    poly_ram_dp u_result (
        .clk(clk),
        .we_a(write_valid),
        .addr_a(result_addr_a),
        .data_a(c0_sum),
        .q_a(result_q_a),
        .we_b(write_valid),
        .addr_b(result_addr_b),
        .data_b(c1_delay[MUL_STAGES-1]),
        .q_b(result_q_b)
    );

    mod_mul_pipe u_mul_a0_b0 (
        .clk(clk), .rst_n(rst_n), .in_valid(read_valid),
        .a(a_q_a), .b(b_q_a), .out_valid(product_valid[0]), .r(a0_b0)
    );

    mod_mul_pipe u_mul_a1_b1 (
        .clk(clk), .rst_n(rst_n), .in_valid(read_valid),
        .a(a_q_b), .b(b_q_b), .out_valid(product_valid[1]), .r(a1_b1)
    );

    mod_mul_pipe u_mul_a0_b1 (
        .clk(clk), .rst_n(rst_n), .in_valid(read_valid),
        .a(a_q_a), .b(b_q_b), .out_valid(product_valid[2]), .r(a0_b1)
    );

    mod_mul_pipe u_mul_a1_b0 (
        .clk(clk), .rst_n(rst_n), .in_valid(read_valid),
        .a(a_q_b), .b(b_q_a), .out_valid(product_valid[3]), .r(a1_b0)
    );

    gammas_rom u_gammas (
        .pair_index(first_result_pair),
        .gamma(gamma)
    );

    mod_mul_pipe u_mul_gamma (
        .clk(clk), .rst_n(rst_n), .in_valid(product_valid[1]),
        .a(a1_b1), .b(gamma), .out_valid(gamma_valid), .r(gamma_product)
    );

    mod_add u_add_c1 (
        .a(a0_b1),
        .b(a1_b0),
        .r(c1_sum)
    );

    logic [12:0] c0_wide, c0_reduced;
    assign c0_wide = {1'b0,a0b0_delay[MUL_STAGES-1]} + {1'b0,gamma_product};
    assign c0_reduced = c0_wide - 13'd3329;
    assign c0_sum = c0_reduced[12] ? c0_wide[11:0] : c0_reduced[11:0];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state             <= S_IDLE;
            pair_index        <= 7'd0;
            first_result_pair <= 7'd0;
            write_pair        <= 7'd0;
            read_valid        <= 1'b0;
            busy              <= 1'b0;
            done              <= 1'b0;
            cycle_count       <= 32'd0;
            for (pipeline_index = 0; pipeline_index < MUL_STAGES;
                 pipeline_index = pipeline_index + 1) begin
                a0b0_delay[pipeline_index] <= 12'd0;
                c1_delay[pipeline_index]   <= 12'd0;
            end
        end else begin
            done       <= 1'b0;
            read_valid <= issue_valid;
            if (busy)
                cycle_count <= cycle_count + 32'd1;

            a0b0_delay[0] <= product_valid[0] ? a0_b0 : 12'd0;
            c1_delay[0]   <= product_valid[0] ? c1_sum : 12'd0;
            for (pipeline_index = 1; pipeline_index < MUL_STAGES;
                 pipeline_index = pipeline_index + 1) begin
                a0b0_delay[pipeline_index] <= a0b0_delay[pipeline_index-1];
                c1_delay[pipeline_index]   <= c1_delay[pipeline_index-1];
            end

            if (product_valid[1])
                first_result_pair <= first_result_pair + 7'd1;

            case (state)
                S_IDLE: begin
                    if (start) begin
                        pair_index        <= 7'd0;
                        first_result_pair <= 7'd0;
                        write_pair        <= 7'd0;
                        cycle_count       <= 32'd0;
                        busy              <= 1'b1;
                        state             <= S_ISSUE;
                    end
                end

                S_ISSUE: begin
                    if (pair_index == 7'd127)
                        state <= S_DRAIN;
                    else
                        pair_index <= pair_index + 7'd1;
                end

                S_DRAIN: begin
                    // Wait for the two cascaded modular-multiply pipelines.
                end

                default: state <= S_IDLE;
            endcase

            if (write_valid) begin
                if (write_pair == 7'd127) begin
                    busy  <= 1'b0;
                    done  <= 1'b1;
                    state <= S_IDLE;
                end else begin
                    write_pair <= write_pair + 7'd1;
                end
            end
        end
    end

endmodule
