// Streaming wrapper for SHA3-256, SHA3-512, SHAKE128 and SHAKE256.
//
// Compared with the reference byte-serial wrapper, absorption has initiation
// interval one: a rotating 64-bit lane accumulator consumes one registered RAM
// byte every clock.  Permutation load/read transfers are also streamed after a
// single priming clock.  The Keccak-f[1600] primitive itself is unchanged.
module keccak_sponge #(
    parameter int MAX_INPUT_BYTES  = 2048,
    parameter int MAX_OUTPUT_BYTES = 1024,
    parameter int INPUT_ADDR_W     = 11,
    parameter int OUTPUT_ADDR_W    = 10,
    // KDF-only physical pipeline. Default retains the KEM sponge schedule.
    parameter bit PERM_THREE_PHASE_ROUND = 1'b0,
    // Only the internal KEM RAM reader enables this gate. Its controller
    // waits beyond done before reading; public users retain immediate masking.
    parameter bit REGISTERED_INTERNAL_VISIBILITY = 1'b0,
    // Internal KDF writes finish before the sponge's absorption setup states.
    // Pipeline that RAM write to separate operational clear from M10K setup.
    // Public callers keep the established immediate-write interface.
    parameter bit REGISTERED_INPUT_WRITE = 1'b0
) (
    input  logic                     clk,
    input  logic                     rst_n,
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

    // Retain the established debug encodings.  Besides keeping waveform tools
    // stable, every state remains reachable by the zeroize coverage test.
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
    (* ramstyle = "M10K" *) logic [7:0] input_memory  [0:MAX_INPUT_BYTES-1];
    (* ramstyle = "M10K" *) logic [7:0] output_memory [0:MAX_OUTPUT_BYTES-1];
    logic [7:0] input_q, output_q;
    logic result_valid;

    logic [1599:0] sponge_state;
    logic [63:0] absorb_lane, absorb_lane_next, squeeze_lane;
`ifndef SYNTHESIS
    // Named zero-valued probes retained only for clear/waveform simulation.
    logic [7:0] absorb_byte_q;
    logic [63:0] absorb_mask;
`endif

    logic [8:0] rate_bytes;
    logic [7:0] domain_byte;
    logic [OUTPUT_ADDR_W:0] output_length_reg;
    logic [8:0] byte_index;
    logic [OUTPUT_ADDR_W:0] output_index;
    logic [4:0] lane_index;
    logic squeezing;

    logic perm_start, perm_load_we;
    logic [4:0] perm_load_lane_index, perm_read_lane_index;
    // Registered look-ahead address for the permutation read port.  The old
    // lane_index+1/state mux directly drove 64 parallel 25:1 selectors inside
    // the permutation, producing the measured lane_index -> read_lane_data
    // critical path.  This counter stays one lane ahead, preserving the
    // existing one-lane-per-clock transfer and its cycle count.
    (* maxfan = 32, preserve, dont_merge *) logic [4:0] perm_read_lane_index_q;
    logic [63:0] perm_load_lane_data, perm_read_lane_data;
    logic perm_busy, perm_done;
    logic [6:0] perm_cycle_count;
    logic [4:0] perm_debug_round;

    // Keep this registered clear local to each sponge instance.  At 160 MHz a
    // merged clear replica can become a long route into all 25 Keccak lanes.
`ifdef MLKEM_STREAMING_BALANCED_4BU
    // The four-lane project is now limited by the final few hundred ps of
    // clear routing, rather than Keccak logic.  A tighter replication bound
    // keeps each physical clear copy close to its lane registers.
    (* maxfan = 8, preserve, dont_merge *) logic datapath_clear_q;
`else
    (* maxfan = 32, preserve, dont_merge *) logic datapath_clear_q;
`endif
    // In the 4BU build the registered clear token is also the local controller
    // reset.  This removes reset_sync_n from the permutation read counter and
    // the sponge FSM; other projects retain their established reset topology.
`ifdef MLKEM_STREAMING_BALANCED_4BU
    wire controller_clear = datapath_clear_q;
`else
    wire controller_clear = !rst_n;
`endif
    // Dedicated registered RAM address removes block_start + byte_index + 1
    // from the M10K port-B address path.  Padding uses a remaining-byte
    // counter, so no global-address adder remains in the Keccak write path.
    (* preserve *) logic [INPUT_ADDR_W-1:0] input_read_address_q;
    logic [INPUT_ADDR_W:0] message_bytes_remaining;
    logic message_present_q;
    logic domain_pending;
    logic [7:0] absorb_byte;
    logic is_last_rate_byte;

    assign debug_state = state;
    assign is_last_rate_byte = (byte_index == (rate_bytes - 9'd1));
    always_ff @(posedge clk) begin
        if (!rst_n) datapath_clear_q <= 1'b1;
        else        datapath_clear_q <= zeroize;
    end

    // Predict FINISH at the same edge as the controller. Register the whole
    // clear expression instead of ORing the shared datapath clear and a
    // decoded state onto the synchronous-clear pins of three wide lanes.
    // Reset/zeroize still clear these lanes on the existing second edge.
    (* preserve, dont_merge, maxfan = 16 *) logic [2:0] transient_clear_q;
    always_ff @(posedge clk)
        transient_clear_q <= {3{!rst_n || zeroize ||
            (!datapath_clear_q && state == S_SQUEEZE &&
             (output_index + 1'b1) >= output_length_reg)}};
`ifndef SYNTHESIS
    always @(negedge clk)
        if (rst_n && transient_clear_q !== {3{datapath_clear_q || state == S_FINISH}})
            $fatal(1,"Keccak transient clear lookahead mismatch");
`endif

    // FIPS 202 multi-rate padding.  The countdown replaces
    // block_start+byte_index followed by wide < and == comparators.
    always_comb begin
        absorb_byte = 8'h00;
        if (message_present_q) begin
            absorb_byte = input_q;
        end else if (domain_pending) begin
            absorb_byte = domain_byte;
        end
        // The final 0x80 bit belongs only to the padded block.  Intermediate
        // full message blocks are permuted without padding.
        if (is_last_rate_byte && !message_present_q)
            absorb_byte = absorb_byte | 8'h80;
    end

    // Rotate one byte and XOR at a fixed bit position.  After eight clocks the
    // lane is back in its original orientation with all eight bytes absorbed;
    // no variable 64-bit barrel shifter is required.
    assign absorb_lane_next = {
        absorb_lane[7:0] ^ absorb_byte,
        absorb_lane[63:8]
    };

    generate if (REGISTERED_INPUT_WRITE) begin : g_input_write_pipeline
        (* preserve, dont_merge *) logic write_q;
        logic [INPUT_ADDR_W-1:0] address_q;
        logic [7:0] data_q;
        always_ff @(posedge clk) begin
            write_q <= rst_n && !zeroize && !datapath_clear_q && !busy && input_we;
            address_q <= input_address;
            data_q <= input_data;
            if (write_q) input_memory[address_q] <= data_q;
        end
        // A pending byte can be committed on an abort edge; RAM was never
        // erased by zeroize. Controller/output masking still aborts the hash,
        // and a later hash overwrites every byte within its declared length.
    end else begin : g_immediate_input_write
        always_ff @(posedge clk)
            if (!zeroize && !datapath_clear_q && !busy && input_we)
                input_memory[input_address] <= input_data;
    end endgenerate
    always_ff @(posedge clk) begin
        input_q  <= input_memory[input_read_address_q];
        output_q <= output_memory[output_address];
    end

    generate if (REGISTERED_INTERNAL_VISIBILITY) begin : g_internal_read_gate
        (* preserve, dont_merge, maxfan = 8 *) logic visible_q;
        always_ff @(posedge clk)
            visible_q <= rst_n && !zeroize && !datapath_clear_q && result_valid;
        assign output_data = visible_q ? output_q : 8'd0;
    end else begin : g_public_read_gate
        assign output_data = (rst_n && !zeroize && !datapath_clear_q && result_valid)
            ? output_q : 8'd0;
    end endgenerate
    always_ff @(posedge clk) begin
        if (controller_clear) result_valid <= 1'b0;
        else if (zeroize || (state == S_IDLE && start)) result_valid <= 1'b0;
        else if (state == S_FINISH) result_valid <= 1'b1;
    end

    assign perm_start = !zeroize && !datapath_clear_q && (state == S_START_PERM);
    assign perm_load_we = !zeroize && !datapath_clear_q && (state == S_LOAD_LANE);
    assign perm_load_lane_index = lane_index;
    // Registered primitive read is primed at lane 0, then the next lane is
    // requested while the current lane is committed to sponge_state.
    assign perm_read_lane_index = perm_read_lane_index_q;
    always_ff @(posedge clk) begin
        if (controller_clear || datapath_clear_q)
            perm_read_lane_index_q <= 5'd0;
        else if (state == S_WAIT_PERM && perm_done)
            perm_read_lane_index_q <= 5'd0;
        else if (state == S_READ_LANE_REQ)
            perm_read_lane_index_q <= 5'd1;
        else if (state == S_READ_LANE && lane_index < 5'd24)
            perm_read_lane_index_q <= perm_read_lane_index_q + 5'd1;
    end

    keccak_f1600_core #(
        .REGISTER_READ  (1'b1),
        .SEQUENTIAL_LOAD(1'b1),
        .THREE_PHASE_ROUND(PERM_THREE_PHASE_ROUND),
        .DIRECT_CONTROL_RESET(1'b0)
    ) u_permutation (
        .clk(clk), .rst_n(rst_n), .zeroize(datapath_clear_q),
        .start(perm_start), .load_we(perm_load_we),
        .load_lane_index(perm_load_lane_index),
        .load_lane_data(perm_load_lane_data),
        .read_lane_index(perm_read_lane_index),
        .read_lane_data(perm_read_lane_data),
        .busy(perm_busy), .done(perm_done),
        .cycle_count(perm_cycle_count),
        .debug_round_index(perm_debug_round)
    );

    genvar state_lane_index;
    generate for (state_lane_index = 0; state_lane_index < 25;
                  state_lane_index = state_lane_index + 1) begin : g_state_lane
        (* preserve, dont_merge, maxfan = 64 *) logic lane_clear_q;
        always_ff @(posedge clk)
            lane_clear_q <= !rst_n || zeroize || (state == S_IDLE && start);
        always_ff @(posedge clk) begin
            if (lane_clear_q) begin
                sponge_state[64*state_lane_index+:64] <= 64'd0;
            end else if (state == S_ABSORB_XOR && byte_index[2:0] == 3'd7 &&
                         lane_index == state_lane_index) begin
                sponge_state[64*state_lane_index+:64] <= absorb_lane_next;
            end else if (state == S_LOAD_LANE) begin
                if (state_lane_index == 24)
                    sponge_state[64*state_lane_index+:64] <= 64'd0;
                else
                    sponge_state[64*state_lane_index+:64] <=
                        sponge_state[64*(state_lane_index+1)+:64];
            end else if (state == S_READ_LANE && lane_index == state_lane_index) begin
                sponge_state[64*state_lane_index+:64] <= perm_read_lane_data;
            end
        end
    end endgenerate

    // Wide transient lanes use the registered local clear token.  Keeping
    // reset_sync_n out of these 192 data bits prevents the board-reset tree
    // from becoming a synchronous data path through the sponge muxes.
    always_ff @(posedge clk) begin
        if (transient_clear_q[0]) absorb_lane <= 64'd0;
        else begin
            if (state == S_ABSORB_READ)
                absorb_lane <= sponge_state[64*lane_index+:64];
            else if (state == S_ABSORB_XOR)
                absorb_lane <= absorb_lane_next;

        end
        if (transient_clear_q[1]) squeeze_lane <= 64'd0;
        else begin
            if (state == S_SQUEEZE_LANE)
                squeeze_lane <= sponge_state[64*byte_index[8:3]+:64];
            // The S_SQUEEZE state has already passed the output-length
            // termination test in the FSM below.  Repeating that wide
            // comparator here created an avoidable output_index ->
            // squeeze_lane critical path.  The next value is only needed
            // while advancing inside the current rate block; on the final
            // byte the FSM moves to S_FINISH and the lane is cleared there.
            else if (state == S_SQUEEZE && !is_last_rate_byte) begin
                if (byte_index[2:0] == 3'd7)
                    squeeze_lane <= sponge_state[
                        64*(byte_index[8:3]+1'b1)+:64];
                else
                    squeeze_lane <= {8'd0, squeeze_lane[63:8]};
            end

        end
        if (transient_clear_q[2]) perm_load_lane_data <= 64'd0;
        else begin
            if (state == S_LOAD_LANE_REQ)
                perm_load_lane_data <= sponge_state[63:0];
            else if (state == S_LOAD_LANE)
                perm_load_lane_data <= sponge_state[127:64];
        end
    end

    always_ff @(posedge clk) begin
        if (controller_clear) begin
            state <= S_IDLE;
`ifndef SYNTHESIS
            absorb_mask <= 64'd0;
            absorb_byte_q <= 8'd0;
`endif
            rate_bytes <= 9'd136;
            domain_byte <= 8'h06;
            output_length_reg <= '0;
            input_read_address_q <= '0;
            message_bytes_remaining <= '0;
            message_present_q <= 1'b0;
            domain_pending <= 1'b0;
            byte_index <= 9'd0;
            output_index <= '0;
            lane_index <= 5'd0;
            squeezing <= 1'b0;
            busy <= 1'b0;
            done <= 1'b0;
            cycle_count <= 32'd0;
        // Clear the counters from the registered token so the external
        // clear net does not become a wide synchronous data path.  A small
        // immediate branch below still returns the controller to IDLE on
        // the first clear edge; the registered token completes the internal
        // wipe on the following edge.
        end else if (datapath_clear_q) begin
            state <= S_IDLE;
`ifndef SYNTHESIS
            absorb_mask <= 64'd0;
            absorb_byte_q <= 8'd0;
`endif
            rate_bytes <= 9'd136;
            domain_byte <= 8'h06;
            output_length_reg <= '0;
            input_read_address_q <= '0;
            message_bytes_remaining <= '0;
            message_present_q <= 1'b0;
            domain_pending <= 1'b0;
            byte_index <= 9'd0;
            output_index <= '0;
            lane_index <= 5'd0;
            squeezing <= 1'b0;
            busy <= 1'b0;
            done <= 1'b0;
            cycle_count <= 32'd0;
        end else if (zeroize) begin
            state <= S_IDLE;
            busy <= 1'b0;
            done <= 1'b0;
            cycle_count <= 32'd0;
        end else begin
            done <= 1'b0;
`ifndef SYNTHESIS
            absorb_mask <= 64'd0;
            absorb_byte_q <= 8'd0;
`endif
            if (busy)
                cycle_count <= cycle_count + 32'd1;

            case (state)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        output_length_reg <= output_length;
                        input_read_address_q <= '0;
                        message_bytes_remaining <= input_length;
                        message_present_q <= (input_length != 0);
                        domain_pending <= 1'b1;
                        byte_index   <= 9'd0;
                        output_index <= '0;
                        lane_index   <= 5'd0;
                        squeezing    <= 1'b0;
                        cycle_count  <= 32'd0;
                        busy         <= 1'b1;
                        case (mode)
                            MODE_SHA3_256: begin rate_bytes <= 9'd136; domain_byte <= 8'h06; end
                            MODE_SHA3_512: begin rate_bytes <= 9'd72;  domain_byte <= 8'h06; end
                            MODE_SHAKE128: begin rate_bytes <= 9'd168; domain_byte <= 8'h1f; end
                            default:       begin rate_bytes <= 9'd136; domain_byte <= 8'h1f; end
                        endcase
                        state <= S_ABSORB_PREP;
                    end
                end

                // Two one-time setup states retain stable debug/abort coverage;
                // the actual per-byte loop uses READ/XOR only.
                S_ABSORB_PREP: state <= S_ABSORB_MASK;
                S_ABSORB_MASK: state <= S_ABSORB_READ;
                S_ABSORB_READ: begin
                    // The synchronous M10K returns the current byte on this
                    // edge.  Advance the registered address so the following
                    // XOR edge prefetches the next byte.
                    if (!is_last_rate_byte)
                        input_read_address_q <= input_read_address_q + 1'b1;
                    state <= S_ABSORB_XOR;
                end
                S_ABSORB_XOR: begin
                    if (message_bytes_remaining != 0) begin
                        message_bytes_remaining <= message_bytes_remaining - 1'b1;
                        message_present_q <= (message_bytes_remaining > 1);
                    end else if (domain_pending)
                        domain_pending <= 1'b0;
                    if (is_last_rate_byte) begin
                        lane_index <= 5'd0;
                        squeezing <= 1'b0;
                        state <= S_LOAD_LANE_REQ;
                    end else begin
                        byte_index <= byte_index + 9'd1;
                        if (byte_index[2:0] == 3'd7) begin
                            // input_read_address_q already points at the first
                            // byte of the next lane.  Hold it through READ so
                            // that byte is not skipped.
                            lane_index <= lane_index + 5'd1;
                            state <= S_ABSORB_READ;
                        end else
                            input_read_address_q <= input_read_address_q + 1'b1;
                    end
                end

                S_LOAD_LANE_REQ: begin
                    lane_index <= 5'd0;
                    state <= S_LOAD_LANE;
                end
                S_LOAD_LANE: begin
                    // sponge_state shifts destructively because it is replaced
                    // by the permutation result before it is used again.
                    if (lane_index == 5'd24) begin
                        lane_index <= 5'd0;
                        state <= S_START_PERM;
                    end else begin
                        lane_index <= lane_index + 5'd1;
                    end
                end
                S_START_PERM: state <= S_WAIT_PERM;
                S_WAIT_PERM: begin
                    if (perm_done) begin
                        lane_index <= 5'd0;
                        state <= S_READ_LANE_REQ;
                    end
                end

                S_READ_LANE_REQ: begin
                    lane_index <= 5'd0;
                    state <= S_READ_LANE;
                end
                S_READ_LANE: begin
                    if (lane_index == 5'd24) begin
                        lane_index <= 5'd0;
                        state <= S_AFTER_PERM;
                    end else begin
                        lane_index <= lane_index + 5'd1;
                    end
                end

                S_AFTER_PERM: begin
                    if (squeezing) begin
                        byte_index <= 9'd0;
                        state <= S_SQUEEZE_LANE;
                    end else if (message_bytes_remaining != 0 || domain_pending) begin
                        // All supported rates end on a lane boundary.  The
                        // sequential prefetch address is already parked at
                        // byte zero of the next absorb block.
                        byte_index <= 9'd0;
                        lane_index <= 5'd0;
                        state <= S_ABSORB_READ;
                    end else begin
                        byte_index <= 9'd0;
                        output_index <= '0;
                        state <= S_SQUEEZE_LANE;
                    end
                end

                S_SQUEEZE_LANE: begin
                    state <= S_SQUEEZE;
                end
                S_SQUEEZE: begin
                    output_memory[output_index[OUTPUT_ADDR_W-1:0]] <= squeeze_lane[7:0];
                    if ((output_index + 1'b1) >= output_length_reg) begin
                        state <= S_FINISH;
                    end else if (is_last_rate_byte) begin
                        output_index <= output_index + 1'b1;
                        lane_index <= 5'd0;
                        squeezing <= 1'b1;
                        state <= S_LOAD_LANE_REQ;
                    end else begin
                        output_index <= output_index + 1'b1;
                        byte_index <= byte_index + 9'd1;
                    end
                end

                S_FINISH: begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    state <= S_IDLE;
                end

                default: begin
                    busy <= 1'b0;
                    state <= S_IDLE;
                end
            endcase
        end
    end

endmodule
