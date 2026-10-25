// Continuous-flow radix-2 CT/GS NTT for n=256 and q=3329.
//
// The logical polynomial is stored once in two 128x12 banks.  The bank of
// logical coefficient i is parity(i), while the row is i>>1.  Butterfly
// operands differ in exactly one address bit, so they always occupy opposite
// banks at every radix-2 stage.  Each bank therefore supports one read and one
// write per clock without duplicating the polynomial.
//
// All 7x128 butterflies are issued as one continuous stream.  A mirrored
// write scheduler reconstructs commit addresses, replacing address-tag FIFOs.
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

    localparam integer MUL_STAGES = 7;
    localparam logic [9:0] LAST_BUTTERFLY = 10'd895;

    typedef enum logic [1:0] {S_IDLE, S_ISSUE, S_DRAIN} state_t;
    state_t state;

    logic inverse_latched;
    logic [9:0] issued_total, written_total;

    logic [7:0] issue_length, issue_j, issue_group_offset;
    logic [6:0] zeta_index;
    logic [7:0] issue_addr_b;
    logic       issue_bank_a;
    logic       issue_valid;

    logic [7:0] write_length, write_j, write_group_offset;
    logic [7:0] write_addr_b;
    logic       write_bank_a;
    logic       write_valid;

    logic [6:0] bank0_read_address, bank1_read_address;
    logic [6:0] bank0_write_address, bank1_write_address;
    logic       bank0_write_enable, bank1_write_enable;
    logic [11:0] bank0_write_data, bank1_write_data;
    logic [11:0] bank0_read_data, bank1_read_data;
    logic        external_read_bank_q;

    logic        read_valid, read_bank_a;
    logic [11:0] read_zeta;
    logic [11:0] coefficient_a, coefficient_b;
    logic [11:0] inverse_sum, inverse_difference;
    logic [11:0] launch_side, launch_value, launch_zeta;
    // The inferred M10K read output previously drove the butterfly muxes and
    // the first DSP input register in one cycle.  Keep an explicit local
    // boundary beside the multiplier so placement is no longer constrained by
    // the bank-to-DSP route (the measured 160 MHz critical path).
    logic        launch_valid_q;
    logic [11:0] launch_side_q, launch_value_q, launch_zeta_q;

    logic        product_valid;
    logic [11:0] product;
    logic [11:0] side_delay [0:MUL_STAGES-1];
    logic [11:0] forward_sum, forward_difference;
    logic [11:0] result_a, result_b;
    logic [11:0] write_result_a, write_result_b;
`ifdef CONTINUOUS_BANKED_V2_TIMING_FIX
    // A local writeback boundary keeps the two-stage modular add/subtract
    // cone away from the M10K input register.  Throughput remains one
    // butterfly per clock; only the fixed drain latency grows by one cycle.
    logic        writeback_valid_q;
    logic [11:0] result_a_q, result_b_q;
`endif
    logic [11:0] zeta_value;
    integer pipeline_index;

    function automatic [11:0] half_mod(input logic [11:0] value);
        logic [12:0] even_value;
        begin
            even_value = {1'b0, value} + (value[0] ? 13'd3329 : 13'd0);
            half_mod = even_value[12:1];
        end
    endfunction

    assign issue_valid  = state == S_ISSUE;
    assign issue_addr_b = issue_j + issue_length;
    assign issue_bank_a = ^issue_j;

    assign write_addr_b = write_j + write_length;
    assign write_bank_a = ^write_j;
`ifdef CONTINUOUS_BANKED_V2_TIMING_FIX
    assign write_valid  = writeback_valid_q && busy;
    assign write_result_a = result_a_q;
    assign write_result_b = result_b_q;
`else
    assign write_valid  = product_valid && busy;
    assign write_result_a = result_a;
    assign write_result_b = result_b;
`endif

    assign debug_length     = issue_length;
    assign debug_j          = issue_j;
    assign debug_zeta_index = zeta_index;

    // Logical-to-physical routing.  Both read ports are also pointed at the
    // external row while idle; read_address parity selects the returned bank.
    always_comb begin
        bank0_read_address  = read_address[7:1];
        bank1_read_address  = read_address[7:1];
        bank0_write_address = 7'd0;
        bank1_write_address = 7'd0;
        bank0_write_enable  = 1'b0;
        bank1_write_enable  = 1'b0;
        bank0_write_data    = 12'd0;
        bank1_write_data    = 12'd0;

        if (issue_valid) begin
            if (!issue_bank_a) begin
                bank0_read_address = issue_j[7:1];
                bank1_read_address = issue_addr_b[7:1];
            end else begin
                bank1_read_address = issue_j[7:1];
                bank0_read_address = issue_addr_b[7:1];
            end
        end

        if (state == S_IDLE && load_we) begin
            // The selected bank is already protected by its write enable, so
            // broadcast the payload to both RAM data ports.  Keeping the
            // address-parity decision out of the data cone removes an
            // unnecessary load_address -> M10K input mux at 160 MHz.
            bank0_write_data = load_data;
            bank1_write_data = load_data;
            if (!(^load_address)) begin
                bank0_write_enable  = 1'b1;
                bank0_write_address = load_address[7:1];
            end else begin
                bank1_write_enable  = 1'b1;
                bank1_write_address = load_address[7:1];
            end
        end else if (write_valid) begin
            if (!write_bank_a) begin
                bank0_write_enable  = 1'b1;
                bank0_write_address = write_j[7:1];
                bank0_write_data    = write_result_a;
                bank1_write_enable  = 1'b1;
                bank1_write_address = write_addr_b[7:1];
                bank1_write_data    = write_result_b;
            end else begin
                bank1_write_enable  = 1'b1;
                bank1_write_address = write_j[7:1];
                bank1_write_data    = write_result_a;
                bank0_write_enable  = 1'b1;
                bank0_write_address = write_addr_b[7:1];
                bank0_write_data    = write_result_b;
            end
        end
    end

    poly_bank_128_sdp u_bank0 (
        .clk          (clk),
        .read_address (bank0_read_address),
        .read_data    (bank0_read_data),
        .write_enable (bank0_write_enable),
        .write_address(bank0_write_address),
        .write_data   (bank0_write_data)
    );

    poly_bank_128_sdp u_bank1 (
        .clk          (clk),
        .read_address (bank1_read_address),
        .read_data    (bank1_read_data),
        .write_enable (bank1_write_enable),
        .write_address(bank1_write_address),
        .write_data   (bank1_write_data)
    );

    // Delay the parity select with the synchronous bank read.  This lets the
    // service prefetch address i+1 while consuming coefficient i without the
    // mux switching to the next bank one clock too early.
    assign read_data = external_read_bank_q ? bank1_read_data : bank0_read_data;
    assign coefficient_a = read_bank_a ? bank1_read_data : bank0_read_data;
    assign coefficient_b = read_bank_a ? bank0_read_data : bank1_read_data;

    zetas_rom u_zetas (
        .address(zeta_index),
        .zeta   (zeta_value)
    );

    mod_add u_inverse_add (
        .a(coefficient_a),
        .b(coefficient_b),
        .r(inverse_sum)
    );

    mod_sub u_inverse_sub (
        .a(coefficient_b),
        .b(coefficient_a),
        .r(inverse_difference)
    );

    assign launch_value = inverse_latched ? inverse_difference : coefficient_b;
    assign launch_zeta  = inverse_latched ? half_mod(read_zeta) : read_zeta;
    assign launch_side  = inverse_latched ? half_mod(inverse_sum) : coefficient_a;

    mod_mul_pipe u_multiply (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid (launch_valid_q),
        .a         (launch_value_q),
        .b         (launch_zeta_q),
        .out_valid(product_valid),
        .r         (product)
    );

    mod_add u_forward_add (
        .a(side_delay[MUL_STAGES-1]),
        .b(product),
        .r(forward_sum)
    );

    mod_sub u_forward_sub (
        .a(side_delay[MUL_STAGES-1]),
        .b(product),
        .r(forward_difference)
    );

    assign result_a = inverse_latched ? side_delay[MUL_STAGES-1] : forward_sum;
    assign result_b = inverse_latched ? product : forward_difference;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state              <= S_IDLE;
            inverse_latched    <= 1'b0;
            issued_total       <= 10'd0;
            written_total      <= 10'd0;
            issue_length       <= 8'd0;
            issue_j            <= 8'd0;
            issue_group_offset <= 8'd0;
            zeta_index         <= 7'd0;
            write_length       <= 8'd0;
            write_j            <= 8'd0;
            write_group_offset <= 8'd0;
            read_valid         <= 1'b0;
            read_bank_a        <= 1'b0;
            read_zeta          <= 12'd0;
            external_read_bank_q <= 1'b0;
            launch_valid_q     <= 1'b0;
            launch_side_q      <= 12'd0;
            launch_value_q     <= 12'd0;
            launch_zeta_q      <= 12'd0;
`ifdef CONTINUOUS_BANKED_V2_TIMING_FIX
            writeback_valid_q  <= 1'b0;
            result_a_q         <= 12'd0;
            result_b_q         <= 12'd0;
`endif
            busy               <= 1'b0;
            done               <= 1'b0;
            cycle_count        <= 32'd0;
            for (pipeline_index = 0; pipeline_index < MUL_STAGES;
                 pipeline_index = pipeline_index + 1)
                side_delay[pipeline_index] <= 12'd0;
        end else begin
            done       <= 1'b0;
            external_read_bank_q <= ^read_address;
            read_valid <= issue_valid;
            if (issue_valid) begin
                read_bank_a <= issue_bank_a;
                read_zeta   <= zeta_value;
            end

            launch_valid_q <= read_valid;
            if (read_valid) begin
                launch_side_q  <= launch_side;
                launch_value_q <= launch_value;
                launch_zeta_q  <= launch_zeta;
            end

            // product_valid is the writeback qualifier; values travelling in
            // bubble slots are never observed.  Propagating the held side
            // value avoids twelve bubble-zero muxes in front of this delay
            // line and gives the fitter a cleaner pipeline to place.
            side_delay[0] <= launch_side_q;
            for (pipeline_index = 1; pipeline_index < MUL_STAGES;
                 pipeline_index = pipeline_index + 1)
                side_delay[pipeline_index] <= side_delay[pipeline_index-1];

`ifdef CONTINUOUS_BANKED_V2_TIMING_FIX
            writeback_valid_q <= product_valid && busy;
            if (product_valid && busy) begin
                result_a_q <= result_a;
                result_b_q <= result_b;
            end
`endif

            if (busy)
                cycle_count <= cycle_count + 32'd1;

            case (state)
                S_IDLE: begin
                    if (start) begin
                        inverse_latched    <= inverse;
                        issued_total       <= 10'd0;
                        written_total      <= 10'd0;
                        issue_length       <= inverse ? 8'd2 : 8'd128;
                        issue_j            <= 8'd0;
                        issue_group_offset <= 8'd0;
                        zeta_index         <= inverse ? 7'd127 : 7'd1;
                        write_length       <= inverse ? 8'd2 : 8'd128;
                        write_j            <= 8'd0;
                        write_group_offset <= 8'd0;
                        cycle_count        <= 32'd0;
                        busy               <= 1'b1;
                        state              <= S_ISSUE;
                    end
                end

                S_ISSUE: begin
                    issued_total <= issued_total + 10'd1;
                    if (issue_group_offset == issue_length - 8'd1) begin
                        issue_group_offset <= 8'd0;
                        zeta_index <= inverse_latched ?
                                      zeta_index - 7'd1 : zeta_index + 7'd1;
                        if ((issue_j + issue_length) >= 8'd255) begin
                            issue_j <= 8'd0;
                            issue_length <= inverse_latched ?
                                            (issue_length << 1) :
                                            (issue_length >> 1);
                        end else begin
                            issue_j <= issue_j + issue_length + 8'd1;
                        end
                    end else begin
                        issue_group_offset <= issue_group_offset + 8'd1;
                        issue_j            <= issue_j + 8'd1;
                    end

                    if (issued_total == LAST_BUTTERFLY)
                        state <= S_DRAIN;
                end

                S_DRAIN: begin
                    // Wait only for the fixed-latency arithmetic pipeline.
                end

                default: state <= S_IDLE;
            endcase

            if (write_valid) begin
                written_total <= written_total + 10'd1;
                if (write_group_offset == write_length - 8'd1) begin
                    write_group_offset <= 8'd0;
                    if ((write_j + write_length) >= 8'd255) begin
                        write_j <= 8'd0;
                        write_length <= inverse_latched ?
                                        (write_length << 1) :
                                        (write_length >> 1);
                    end else begin
                        write_j <= write_j + write_length + 8'd1;
                    end
                end else begin
                    write_group_offset <= write_group_offset + 8'd1;
                    write_j            <= write_j + 8'd1;
                end

                if (written_total == LAST_BUTTERFLY) begin
                    busy  <= 1'b0;
                    done  <= 1'b1;
                    state <= S_IDLE;
                end
            end
        end
    end

`ifndef SYNTHESIS
    // Radix-2 partners differ in exactly one bit and must never collide.
    always_ff @(posedge clk) begin
        if (rst_n && issue_valid && (issue_bank_a == (^issue_addr_b)))
            $fatal(1, "NTT conflict-free read mapping violated");
        if (rst_n && write_valid && (write_bank_a == (^write_addr_b)))
            $fatal(1, "NTT conflict-free write mapping violated");
    end
`endif

endmodule
