// Keccak sponge dung chung cho SHA3-256, SHA3-512, SHAKE128 va SHAKE256.
//
// Du lieu vao duoc nap vao RAM byte truoc khi start. Ket qua duoc luu trong
// RAM byte dau ra. Khoi xu ly duoc thong diep nhieu block va squeeze nhieu
// block, trong khi chi tai su dung mot keccak_f1600_core.
module keccak_sponge #(
    parameter int MAX_INPUT_BYTES  = 2048,
    parameter int MAX_OUTPUT_BYTES = 1024,
    parameter int INPUT_ADDR_W     = 11,
    parameter int OUTPUT_ADDR_W    = 10
) (
    input  logic                     clk,
    input  logic                     rst_n,
    // Operational abort/clear, sampled on clk. Never combine it with rst_n.
    input  logic                     zeroize,
    input  logic                     start,
    input  logic [1:0]               mode,
    input  logic [INPUT_ADDR_W:0]    input_length,
    input  logic [OUTPUT_ADDR_W:0]   output_length,

    input  logic                     input_we,
    input  logic [INPUT_ADDR_W-1:0]  input_address,
    input  logic [7:0]               input_data,

    input  logic [OUTPUT_ADDR_W-1:0] output_address,
    output logic [7:0]               output_data,

    output logic                     busy,
    output logic                     done,
    output logic [31:0]              cycle_count,
    output logic [3:0]               debug_state
);

    localparam logic [1:0] MODE_SHA3_256 = 2'd0;
    localparam logic [1:0] MODE_SHA3_512 = 2'd1;
    localparam logic [1:0] MODE_SHAKE128 = 2'd2;
    localparam logic [1:0] MODE_SHAKE256 = 2'd3;

    typedef enum logic [3:0] {
        S_IDLE,
        S_ABSORB_READ,
        S_ABSORB_PREP,
        S_ABSORB_MASK,
        S_ABSORB_XOR,
        S_LOAD_LANE_REQ,
        S_LOAD_LANE,
        S_START_PERM,
        S_WAIT_PERM,
        S_READ_LANE_REQ,
        S_READ_LANE,
        S_AFTER_PERM,
        S_SQUEEZE_LANE,
        S_SQUEEZE,
        S_FINISH
    } state_t;

    state_t state;

    logic [7:0] input_memory  [0:MAX_INPUT_BYTES-1];
    logic [7:0] output_memory [0:MAX_OUTPUT_BYTES-1];
    logic [7:0] input_q;
    logic [7:0] output_q;
    logic result_valid;

    logic [1599:0] sponge_state;
    logic [63:0] squeeze_lane;
    logic [8:0] rate_bytes;
    logic [7:0] domain_byte;
    logic [INPUT_ADDR_W:0] input_length_reg;
    logic [OUTPUT_ADDR_W:0] output_length_reg;
    logic [INPUT_ADDR_W:0] block_start;
    logic [8:0] byte_index;
    logic [OUTPUT_ADDR_W:0] output_index;
    logic [4:0] lane_index;
    logic squeezing;

    logic        perm_start;
    logic        perm_load_we;
    logic [4:0]  perm_load_lane_index;
    logic [63:0] perm_load_lane_data;
    logic [4:0]  perm_read_lane_index;
    logic [63:0] perm_read_lane_data;
    logic        perm_busy;
    logic        perm_done;
    logic [6:0]  perm_cycle_count;
    logic [4:0]  perm_debug_round;

    // Pipeline the operational wipe at the primitive boundary.  The external
    // zeroize still aborts the small controller immediately; this local token
    // drives the 4800-bit sponge/permutation datapath one cycle later.  That
    // removes the caller-state decode and long cross-hierarchy route from the
    // wide synchronous-clear network.
    (* maxfan = 64, preserve *) logic datapath_clear_q;
    always_ff @(posedge clk) begin
        if (!rst_n) datapath_clear_q <= 1'b1;
        else        datapath_clear_q <= zeroize;
    end

    logic [INPUT_ADDR_W:0] global_input_index;
    logic [7:0] absorb_byte;
    logic [7:0] absorb_byte_q;
    logic       is_last_rate_byte;
    logic [63:0] absorb_mask;

    assign debug_state = state;
    assign global_input_index = block_start + byte_index;
    assign is_last_rate_byte = (byte_index == (rate_bytes - 9'd1));

    always_comb begin
        absorb_byte = 8'h00;
        if (global_input_index < input_length_reg) begin
            absorb_byte = input_q;
        end else if (global_input_index == input_length_reg) begin
            absorb_byte = domain_byte;
            if (is_last_rate_byte)
                absorb_byte = domain_byte | 8'h80;
        end else if (is_last_rate_byte) begin
            absorb_byte = 8'h80;
        end
    end

    always_ff @(posedge clk) begin
        // This scratchpad is always fully reloaded before a hash starts, while
        // zeroize still blocks writes. Keeping rst_n off the M10K data/enable
        // cone removes the final high-fanout reset path into the RAM port.
        if (!zeroize && !datapath_clear_q && !busy && input_we)
            input_memory[input_address] <= input_data;
        input_q    <= input_memory[global_input_index[INPUT_ADDR_W-1:0]];
        output_q <= output_memory[output_address];
    end

    // Keep the RAM ports synchronous/inferable. Clear invalidates their output;
    // it does NOT physically scrub the input/output scratch RAM contents.
    assign output_data = (rst_n && !zeroize && !datapath_clear_q && result_valid) ? output_q : 8'd0;
    always_ff @(posedge clk) begin
        if (!rst_n) result_valid <= 1'b0;
        else if (zeroize || (state == S_IDLE && start)) result_valid <= 1'b0;
        else if (state == S_FINISH) result_valid <= 1'b1;
    end

    assign perm_start           = !zeroize && !datapath_clear_q && (state == S_START_PERM);
    assign perm_load_we         = !zeroize && !datapath_clear_q && (state == S_LOAD_LANE);
    assign perm_load_lane_index = lane_index;
    assign perm_read_lane_index = lane_index;

    keccak_f1600_core #(
        .REGISTER_READ  (1'b1),
        .SEQUENTIAL_LOAD(1'b1),
        .DIRECT_CONTROL_RESET(1'b0)
    ) u_permutation (
        .clk               (clk),
        .rst_n             (rst_n),
        .zeroize           (datapath_clear_q),
        .start             (perm_start),
        .load_we           (perm_load_we),
        .load_lane_index   (perm_load_lane_index),
        .load_lane_data    (perm_load_lane_data),
        .read_lane_index   (perm_read_lane_index),
        .read_lane_data    (perm_read_lane_data),
        .busy              (perm_busy),
        .done              (perm_done),
        .cycle_count       (perm_cycle_count),
        .debug_round_index (perm_debug_round)
    );

    // Moi lane XOR truc tiep voi mask byte: khong doc qua mux 200 byte
    // roi ghi nguoc ve 1600 bit. Mask duoc dang ky truoc khi cap nhat lane.
    genvar state_lane_index;
    generate for (state_lane_index=0; state_lane_index<25; state_lane_index=state_lane_index+1) begin : g_state_lane
        always_ff @(posedge clk) begin
            // Every request starts from a fully cleared sponge and zeroize is
            // retained for physical secret erasure.  Keeping global reset off
            // this 1600-bit bank avoids another high-fanout reset data path.
            if (datapath_clear_q || (state==S_IDLE && start)) sponge_state[64*state_lane_index+:64] <= 64'd0;
            else if (state==S_ABSORB_XOR && byte_index[8:3]==state_lane_index)
                sponge_state[64*state_lane_index+:64] <= sponge_state[64*state_lane_index+:64] ^ absorb_mask;
            else if (state==S_READ_LANE && lane_index==state_lane_index)
                sponge_state[64*state_lane_index+:64] <= perm_read_lane_data;
        end
    end endgenerate

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state             <= S_IDLE;
            absorb_mask       <= 64'd0;
            absorb_byte_q     <= 8'd0;
            squeeze_lane      <= 64'd0;
            perm_load_lane_data <= 64'd0;
            rate_bytes        <= 9'd136;
            domain_byte       <= 8'h06;
            input_length_reg  <= '0;
            output_length_reg <= '0;
            block_start       <= '0;
            byte_index        <= 9'd0;
            output_index      <= '0;
            lane_index        <= 5'd0;
            squeezing         <= 1'b0;
            busy              <= 1'b0;
            done              <= 1'b0;
            cycle_count       <= 32'd0;
        end else if (zeroize || datapath_clear_q) begin
            // This clear has priority over every FSM action, including the
            // output RAM write in S_SQUEEZE and done generation in S_FINISH.
            state             <= S_IDLE;
            absorb_mask       <= 64'd0;
            absorb_byte_q     <= 8'd0;
            squeeze_lane      <= 64'd0;
            perm_load_lane_data <= 64'd0;
            rate_bytes        <= 9'd136;
            domain_byte       <= 8'h06;
            input_length_reg  <= '0;
            output_length_reg <= '0;
            block_start       <= '0;
            byte_index        <= 9'd0;
            output_index      <= '0;
            lane_index        <= 5'd0;
            squeezing         <= 1'b0;
            busy              <= 1'b0;
            done              <= 1'b0;
            cycle_count       <= 32'd0;
        end else begin
            done <= 1'b0;
            if (busy)
                cycle_count <= cycle_count + 32'd1;

            case (state)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        input_length_reg  <= input_length;
                        output_length_reg <= output_length;
                        block_start       <= '0;
                        byte_index        <= 9'd0;
                        output_index      <= '0;
                        lane_index        <= 5'd0;
                        squeezing         <= 1'b0;
                        cycle_count       <= 32'd0;
                        busy              <= 1'b1;

                        case (mode)
                            MODE_SHA3_256: begin
                                rate_bytes  <= 9'd136;
                                domain_byte <= 8'h06;
                            end
                            MODE_SHA3_512: begin
                                rate_bytes  <= 9'd72;
                                domain_byte <= 8'h06;
                            end
                            MODE_SHAKE128: begin
                                rate_bytes  <= 9'd168;
                                domain_byte <= 8'h1f;
                            end
                            default: begin
                                rate_bytes  <= 9'd136;
                                domain_byte <= 8'h1f;
                            end
                        endcase
                        state <= S_ABSORB_READ;
                    end
                end

                S_ABSORB_READ: begin
                    state <= S_ABSORB_PREP;
                end
                S_ABSORB_PREP: begin
                    // Register padding/data selection before byte-to-lane mux.
                    absorb_byte_q <= absorb_byte;
                    state <= S_ABSORB_MASK;
                end
                S_ABSORB_MASK: begin
                    absorb_mask <= {56'd0,absorb_byte_q} << {byte_index[2:0],3'b0};
                    absorb_byte_q <= 8'd0;
                    state <= S_ABSORB_XOR;
                end

                S_ABSORB_XOR: begin
                    if (is_last_rate_byte) begin
                        lane_index <= 5'd0;
                        squeezing  <= 1'b0;
                        state      <= S_LOAD_LANE_REQ;
                    end else begin
                        byte_index <= byte_index + 9'd1;
                        state      <= S_ABSORB_READ;
                    end
                end

                S_LOAD_LANE_REQ: begin
                    perm_load_lane_data <= sponge_state[64 * lane_index +: 64];
                    state <= S_LOAD_LANE;
                end
                S_LOAD_LANE: begin
                    if (lane_index == 5'd24) begin
                        lane_index <= 5'd0;
                        state      <= S_START_PERM;
                    end else begin
                        lane_index <= lane_index + 5'd1;
                        state <= S_LOAD_LANE_REQ;
                    end
                end

                S_START_PERM: state <= S_WAIT_PERM;

                S_WAIT_PERM: begin
                    if (perm_done) begin
                        lane_index <= 5'd0;
                        state      <= S_READ_LANE_REQ;
                    end
                end

                S_READ_LANE_REQ: state <= S_READ_LANE;
                S_READ_LANE: begin
                    if (lane_index == 5'd24) begin
                        lane_index <= 5'd0;
                        state      <= S_AFTER_PERM;
                    end else begin
                        lane_index <= lane_index + 5'd1;
                        state <= S_READ_LANE_REQ;
                    end
                end

                S_AFTER_PERM: begin
                    if (squeezing) begin
                        byte_index <= 9'd0;
                        state      <= S_SQUEEZE_LANE;
                    end else if ((block_start + rate_bytes) <= input_length_reg) begin
                        block_start <= block_start + rate_bytes;
                        byte_index  <= 9'd0;
                        state       <= S_ABSORB_READ;
                    end else begin
                        byte_index   <= 9'd0;
                        output_index <= '0;
                        state        <= S_SQUEEZE_LANE;
                    end
                end

                // One registered 25:1 lane read per eight output bytes.
                // Avoid the former 200:1 byte mux directly feeding M10K RAM.
                S_SQUEEZE_LANE: begin
                    squeeze_lane <= sponge_state[64 * byte_index[8:3] +: 64];
                    state <= S_SQUEEZE;
                end
                S_SQUEEZE: begin
                    output_memory[output_index[OUTPUT_ADDR_W-1:0]] <=
                        squeeze_lane[7:0];
                    squeeze_lane <= {8'd0,squeeze_lane[63:8]};

                    if ((output_index + 1'b1) >= output_length_reg) begin
                        state <= S_FINISH;
                    end else if (is_last_rate_byte) begin
                        output_index <= output_index + 1'b1;
                        lane_index   <= 5'd0;
                        squeezing    <= 1'b1;
                        state        <= S_LOAD_LANE_REQ;
                    end else begin
                        output_index <= output_index + 1'b1;
                        byte_index   <= byte_index + 9'd1;
                        if (byte_index[2:0] == 3'd7) state <= S_SQUEEZE_LANE;
                    end
                end

                S_FINISH: begin
                    squeeze_lane <= 64'd0;
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
