// Baseline FIPS 203 BaseCaseMultiply architecture.  A coefficient pair is
// read, fully evaluated and written before the next pair starts.  It uses the
// same registered modular multipliers as the optimized design, but performs
// no inter-pair streaming or pipeline overlap.
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

    typedef enum logic [3:0] {
        S_IDLE,
        S_READ,
        S_CAPTURE,
        S_LAUNCH_PRODUCTS,
        S_WAIT_PRODUCTS,
        S_LAUNCH_GAMMA,
        S_WAIT_GAMMA,
        S_WRITE,
        S_FINISH
    } state_t;

    state_t state;
    logic [6:0] pair_index;
    logic [7:0] input_addr_a, input_addr_b;
    logic [7:0] result_addr_a, result_addr_b;
    logic [11:0] a_q_a, a_q_b, b_q_a, b_q_b;
    logic [11:0] result_q_a, result_q_b;
    logic result_we;

    logic [11:0] a0_reg, a1_reg, b0_reg, b1_reg;
    logic [11:0] gamma, gamma_reg;
    logic [3:0] product_valid;
    logic gamma_valid;
    logic products_in_valid, gamma_in_valid;
    logic [11:0] a0_b0, a1_b1, a0_b1, a1_b0;
    logic [11:0] a0_b0_reg, a1_b1_reg, c1_reg;
    logic [11:0] gamma_product;
    logic [11:0] c0_sum, c1_sum;
    logic [11:0] c0_reg;

    assign debug_pair_index = pair_index;
    assign read_data        = result_q_a;
    assign input_addr_a     = (state == S_IDLE) ? load_address :
                              {pair_index, 1'b0};
    assign input_addr_b     = {pair_index, 1'b1};
    assign result_addr_a    = (state == S_IDLE) ? read_address :
                              {pair_index, 1'b0};
    assign result_addr_b    = {pair_index, 1'b1};
    assign result_we        = (state == S_WRITE) && busy;
    assign products_in_valid = state == S_LAUNCH_PRODUCTS;
    assign gamma_in_valid    = state == S_LAUNCH_GAMMA;

    poly_ram_dp u_input_a (
        .clk   (clk),
        .we_a  (load_a_we && state == S_IDLE),
        .addr_a(input_addr_a),
        .data_a(load_a_data),
        .q_a   (a_q_a),
        .we_b  (1'b0),
        .addr_b(input_addr_b),
        .data_b(12'd0),
        .q_b   (a_q_b)
    );

    poly_ram_dp u_input_b (
        .clk   (clk),
        .we_a  (load_b_we && state == S_IDLE),
        .addr_a(input_addr_a),
        .data_a(load_b_data),
        .q_a   (b_q_a),
        .we_b  (1'b0),
        .addr_b(input_addr_b),
        .data_b(12'd0),
        .q_b   (b_q_b)
    );

    poly_ram_dp u_result (
        .clk   (clk),
        .we_a  (result_we),
        .addr_a(result_addr_a),
        .data_a(c0_reg),
        .q_a   (result_q_a),
        .we_b  (result_we),
        .addr_b(result_addr_b),
        .data_b(c1_reg),
        .q_b   (result_q_b)
    );

    gammas_rom u_gammas (
        .pair_index(pair_index),
        .gamma     (gamma)
    );

    mod_mul_pipe u_mul_a0_b0 (
        .clk(clk), .rst_n(rst_n), .in_valid(products_in_valid),
        .a(a0_reg), .b(b0_reg), .out_valid(product_valid[0]), .r(a0_b0)
    );

    mod_mul_pipe u_mul_a1_b1 (
        .clk(clk), .rst_n(rst_n), .in_valid(products_in_valid),
        .a(a1_reg), .b(b1_reg), .out_valid(product_valid[1]), .r(a1_b1)
    );

    mod_mul_pipe u_mul_a0_b1 (
        .clk(clk), .rst_n(rst_n), .in_valid(products_in_valid),
        .a(a0_reg), .b(b1_reg), .out_valid(product_valid[2]), .r(a0_b1)
    );

    mod_mul_pipe u_mul_a1_b0 (
        .clk(clk), .rst_n(rst_n), .in_valid(products_in_valid),
        .a(a1_reg), .b(b0_reg), .out_valid(product_valid[3]), .r(a1_b0)
    );

    mod_mul_pipe u_mul_gamma (
        .clk(clk), .rst_n(rst_n), .in_valid(gamma_in_valid),
        .a(a1_b1_reg), .b(gamma_reg),
        .out_valid(gamma_valid), .r(gamma_product)
    );

    mod_add u_add_c1 (
        .a(a0_b1),
        .b(a1_b0),
        .r(c1_sum)
    );

    mod_add u_add_c0 (
        .a(a0_b0_reg),
        .b(gamma_product),
        .r(c0_sum)
    );

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            pair_index   <= 7'd0;
            a0_reg       <= 12'd0;
            a1_reg       <= 12'd0;
            b0_reg       <= 12'd0;
            b1_reg       <= 12'd0;
            gamma_reg    <= 12'd0;
            a0_b0_reg    <= 12'd0;
            a1_b1_reg    <= 12'd0;
            c0_reg       <= 12'd0;
            c1_reg       <= 12'd0;
            busy         <= 1'b0;
            done         <= 1'b0;
            cycle_count  <= 32'd0;
        end else begin
            done <= 1'b0;
            if (busy)
                cycle_count <= cycle_count + 32'd1;

            case (state)
                S_IDLE: begin
                    if (start) begin
                        pair_index  <= 7'd0;
                        cycle_count <= 32'd0;
                        busy        <= 1'b1;
                        state       <= S_READ;
                    end
                end

                S_READ: begin
                    state <= S_CAPTURE;
                end

                S_CAPTURE: begin
                    a0_reg    <= a_q_a;
                    a1_reg    <= a_q_b;
                    b0_reg    <= b_q_a;
                    b1_reg    <= b_q_b;
                    gamma_reg <= gamma;
                    state     <= S_LAUNCH_PRODUCTS;
                end

                S_LAUNCH_PRODUCTS: begin
                    state <= S_WAIT_PRODUCTS;
                end

                S_WAIT_PRODUCTS: begin
                    if (&product_valid) begin
                        a0_b0_reg <= a0_b0;
                        a1_b1_reg <= a1_b1;
                        c1_reg    <= c1_sum;
                        state     <= S_LAUNCH_GAMMA;
                    end
                end

                S_LAUNCH_GAMMA: begin
                    state <= S_WAIT_GAMMA;
                end

                S_WAIT_GAMMA: begin
                    if (gamma_valid) begin
                        c0_reg <= c0_sum;
                        state  <= S_WRITE;
                    end
                end

                S_WRITE: begin
                    if (pair_index == 7'd127)
                        state <= S_FINISH;
                    else begin
                        pair_index <= pair_index + 7'd1;
                        state      <= S_READ;
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
