// Bo sinh bit gia ngau nhien dua tren SHAKE256 cho nguyen mau FPGA.
//
// Input cua moi lan generate:
//   64 byte entropy moi || 32 byte state cu || counter || "MLKR"
// Output SHAKE256 128 byte:
//   96 byte dau -> d || z || m; 32 byte cuoi -> state moi.
//
// Khoi nay tai su dung Keccak-f[1600] cua du an va co domain separation
// SHAKE (0x1F). Day la SHAKE256-DRBG nguyen mau, khong tuyen bo la mot
// co che DRBG da duoc chung nhan SP 800-90A.
module shake256_drbg (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         start,
    input  logic         zeroize,
    input  logic [511:0] entropy_input,
    input  logic [255:0] previous_state,
    input  logic [31:0]  request_counter,

    output logic [767:0] random_vectors,
    output logic [255:0] next_state,
    output logic [31:0]  vector_crc32,
    output logic [31:0]  cycle_count,
    output logic         busy,
    output logic         done
);

    typedef enum logic [3:0] {
        S_IDLE,
        S_LOAD_REQ,
        S_LOAD,
        S_START,
        S_WAIT,
        S_READ_REQ,
        S_READ,
        S_CAPTURE,
        S_CRC,
        S_FINISH
`ifdef MLKEM_STREAMING_BALANCED_2BU
        ,
        S_SCRUB
`endif
    } state_t;

    state_t state;
    logic [1599:0] absorb_block;
    logic [1023:0] squeeze_block;
    logic [4:0] lane_index;
`ifdef MLKEM_STREAMING_BALANCED_2BU
    // One registered write token per 64-bit squeeze lane.  The read-request
    // cycle performs the lane decode; the following read cycle only drives a
    // local enable.  This cuts lane_index out of the 1024-bit register bank.
    (* maxfan = 32, preserve, dont_merge *) logic [15:0] squeeze_write_select_q;
`endif
    logic [6:0] crc_byte_index;
    logic [31:0] crc_reg;
    logic [31:0] crc_next;

    logic        perm_start;
    logic        perm_load_we;
    logic [4:0]  perm_load_lane_index;
    logic [63:0] perm_load_lane_data;
    logic [4:0]  perm_read_lane_index;
    logic [63:0] perm_read_lane_data;
    logic        perm_busy;
    logic        perm_done;
    logic [6:0]  perm_cycle_count;
    logic [4:0]  perm_round;
`ifdef MLKEM_STREAMING_BALANCED_2BU
    // Synchronize the external level locally, then convert it to one abort
    // event.  A health alarm may remain asserted for many clocks; the event
    // must fire once so the following 25 scrub clocks are allowed to run.
    (* preserve, dont_merge *) logic zeroize_local_q;
    (* preserve, dont_merge *) logic zeroize_local_d_q;
    wire internal_zeroize = zeroize_local_q && !zeroize_local_d_q;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            zeroize_local_q   <= 1'b0;
            zeroize_local_d_q <= 1'b0;
        end else begin
            zeroize_local_q   <= zeroize;
            zeroize_local_d_q <= zeroize_local_q;
        end
    end
`else
    wire internal_zeroize = zeroize;
`endif
    // Clear the primitive synchronously through a local, duplicable register.
    // Wrapper outputs clear on the zeroize edge; primitive state clears one
    // clock later. No request/load may reach it while this clear is in flight.
    // Quartus 18.1 Lite accepts the register-local preserve/dont_merge
    // attributes here.  ALLOW_REGISTER_RETIMING is a QSF-only assignment in
    // this version and must not be emitted through ALTERA_ATTRIBUTE.
`ifndef MLKEM_STREAMING_BALANCED_2BU
    (* maxfan = 32, preserve, dont_merge *) logic permutation_clear_q;
    always_ff @(posedge clk) begin
        // Hold a local clear token through reset so the wide Keccak datapath
        // is scrubbed without routing the global reset to every state bit.
        if (!rst_n) permutation_clear_q <= 1'b1;
        else permutation_clear_q <= zeroize;
    end
`endif

    function automatic logic [1599:0] make_input_block(
        input logic [511:0] entropy_value,
        input logic [255:0] state_value,
        input logic [31:0]  counter_value
    );
        logic [1599:0] value;
        begin
            value = 1600'd0;
            value[511:0]   = entropy_value;
            value[767:512] = state_value;
            value[8*96 +: 32] = counter_value;
            value[8*100 +: 8] = 8'h4d; // M
            value[8*101 +: 8] = 8'h4c; // L
            value[8*102 +: 8] = 8'h4b; // K
            value[8*103 +: 8] = 8'h52; // R
            value[8*104 +: 8] = 8'h1f;
            value[8*135 +: 8] = 8'h80;
            make_input_block = value;
        end
    endfunction

    function automatic logic [31:0] crc32_byte(
        input logic [31:0] crc_in,
        input logic [7:0] data_in
    );
        logic [31:0] value;
        integer bit_number;
        begin
            value = crc_in ^ data_in;
            for (bit_number = 0; bit_number < 8; bit_number = bit_number + 1)
                value = value[0] ? ((value >> 1) ^ 32'hEDB88320) :
                                   (value >> 1);
            crc32_byte = value;
        end
    endfunction

`ifdef MLKEM_STREAMING_BALANCED_2BU
    // The 4BU build scrubs the permutation through its 25-lane sequential
    // load port.  Only the small control plane consumes zeroize directly.
    assign perm_start           = rst_n && (state == S_START) &&
                                  !zeroize_local_q && !internal_zeroize;
    assign perm_load_we         = rst_n &&
                                  ((state == S_LOAD) || (state == S_SCRUB)) &&
                                  !internal_zeroize;
`else
    assign perm_start           = (state == S_START) && !zeroize && !permutation_clear_q;
    assign perm_load_we         = (state == S_LOAD) && !zeroize && !permutation_clear_q;
`endif
    assign perm_load_lane_index = lane_index;
    assign perm_read_lane_index = lane_index;
    // After S_CAPTURE, random_vectors and next_state already retain the DRBG
    // result.  Reuse the transient squeeze bank as a byte shift register for
    // CRC instead of placing a 96:1 byte mux between crc_byte_index and the
    // CRC feedback network.
    assign crc_next = crc32_byte(crc_reg, squeeze_block[7:0]);

    keccak_f1600_core #(
        .REGISTER_READ  (1'b1),
        .SEQUENTIAL_LOAD(1'b1),
        .THREE_PHASE_ROUND(1'b1),
`ifdef MLKEM_STREAMING_BALANCED_2BU
        .DIRECT_CONTROL_RESET(1'b1),
        .ZEROIZE_DATAPATH(1'b0)
`else
        .DIRECT_CONTROL_RESET(1'b0)
`endif
    ) u_permutation (
        .clk               (clk),
        .rst_n             (rst_n),
`ifdef MLKEM_STREAMING_BALANCED_2BU
        .zeroize           (internal_zeroize),
`else
        .zeroize           (permutation_clear_q),
`endif
        .start             (perm_start),
        .load_we           (perm_load_we),
        .load_lane_index   (perm_load_lane_index),
        .load_lane_data    (perm_load_lane_data),
        .read_lane_index   (perm_read_lane_index),
        .read_lane_data    (perm_read_lane_data),
        .busy              (perm_busy),
        .done              (perm_done),
        .cycle_count       (perm_cycle_count),
        .debug_round_index (perm_round)
    );

    genvar squeeze_lane_index;
    generate
        for(squeeze_lane_index=0;squeeze_lane_index<15;squeeze_lane_index=squeeze_lane_index+1) begin : g_squeeze_lane
            always_ff @(posedge clk) begin
                // Every lane is cleared at request start and before external
                // zeroize completes; it is also overwritten before S_CAPTURE.
                // Avoid routing reset_sync_n to this 1024-bit transient bank.
                if(internal_zeroize || (state==S_IDLE && start))
                    squeeze_block[64*squeeze_lane_index+:64]<=0;
`ifdef MLKEM_STREAMING_BALANCED_2BU
                else if(squeeze_write_select_q[squeeze_lane_index])
`else
                else if(state==S_READ && lane_index==squeeze_lane_index)
`endif
                    squeeze_block[64*squeeze_lane_index+:64]<=perm_read_lane_data;
                else if(state==S_CRC)
                    squeeze_block[64*squeeze_lane_index+:64] <=
                        squeeze_block[64*squeeze_lane_index+8+:64];
            end
        end
        begin : g_squeeze_last_lane
            always_ff @(posedge clk) begin
                if(internal_zeroize || (state==S_IDLE && start))
                    squeeze_block[1023:960] <= 64'd0;
`ifdef MLKEM_STREAMING_BALANCED_2BU
                else if(squeeze_write_select_q[15])
`else
                else if(state==S_READ && lane_index==5'd15)
`endif
                    squeeze_block[1023:960] <= perm_read_lane_data;
                else if(state==S_CRC)
                    squeeze_block[1023:960] <= {8'd0,squeeze_block[1023:968]};
            end
        end
    endgenerate

    always_ff @(posedge clk) begin
        if (!rst_n) begin
`ifdef MLKEM_STREAMING_BALANCED_2BU
            // After reset release, physically overwrite all 25 retained
            // permutation lanes before accepting a DRBG request.
            state          <= S_SCRUB;
`else
            state          <= S_IDLE;
`endif
            perm_load_lane_data <= 0;
            absorb_block   <= 1600'd0;
            lane_index     <= 5'd0;
`ifdef MLKEM_STREAMING_BALANCED_2BU
            squeeze_write_select_q <= 16'd0;
`endif
            crc_byte_index <= 7'd0;
            crc_reg        <= 32'hFFFFFFFF;
            random_vectors <= 768'd0;
            next_state     <= 256'd0;
            vector_crc32   <= 32'd0;
            cycle_count    <= 32'd0;
`ifdef MLKEM_STREAMING_BALANCED_2BU
            busy           <= 1'b1;
`else
            busy           <= 1'b0;
`endif
            done           <= 1'b0;
        end else if (internal_zeroize) begin
`ifdef MLKEM_STREAMING_BALANCED_2BU
            // Abort the control plane on this edge, then scrub one 64-bit
            // lane per clock.  A complete scrub takes only 25 clocks.
            state          <= S_SCRUB;
`else
            state          <= S_IDLE;
`endif
            perm_load_lane_data <= 0;
            absorb_block   <= 1600'd0;
            lane_index     <= 5'd0;
`ifdef MLKEM_STREAMING_BALANCED_2BU
            squeeze_write_select_q <= 16'd0;
`endif
            crc_byte_index <= 7'd0;
            crc_reg        <= 32'hFFFFFFFF;
            random_vectors <= 768'd0;
            next_state     <= 256'd0;
            vector_crc32   <= 32'd0;
            cycle_count    <= 32'd0;
`ifdef MLKEM_STREAMING_BALANCED_2BU
            busy           <= 1'b1;
`else
            busy           <= 1'b0;
`endif
            done           <= 1'b0;
        end else begin
            done <= 1'b0;
            if (busy)
                cycle_count <= cycle_count + 32'd1;

            case (state)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (start
`ifdef MLKEM_STREAMING_BALANCED_2BU
                        && !zeroize_local_q
`endif
                    ) begin
                        absorb_block <= make_input_block(
                            entropy_input, previous_state, request_counter
                        );
                        random_vectors <= 768'd0;
                        next_state     <= 256'd0;
                        vector_crc32   <= 32'd0;
                        cycle_count    <= 32'd0;
                        lane_index     <= 5'd0;
`ifdef MLKEM_STREAMING_BALANCED_2BU
                        squeeze_write_select_q <= 16'd0;
`endif
                        busy           <= 1'b1;
                        state          <= S_LOAD_REQ;
                    end
                end

                S_LOAD_REQ: begin
                    perm_load_lane_data <= absorb_block[64 * lane_index +: 64];
                    state <= S_LOAD;
                end
                S_LOAD: begin
                    if (lane_index == 5'd24) begin
                        lane_index <= 5'd0;
                        state      <= S_START;
                    end else begin
                        lane_index <= lane_index + 5'd1;
                        state <= S_LOAD_REQ;
                    end
                end

                S_START: state <= S_WAIT;

                S_WAIT: begin
                    if (perm_done) begin
                        lane_index <= 5'd0;
                        state      <= S_READ_REQ;
                    end
                end

                S_READ_REQ: begin
`ifdef MLKEM_STREAMING_BALANCED_2BU
                    squeeze_write_select_q <= 16'h0001 << lane_index[3:0];
`endif
                    state <= S_READ;
                end
                S_READ: begin
`ifdef MLKEM_STREAMING_BALANCED_2BU
                    // The lane banks consume the old one-hot value on this
                    // edge; clear it for every non-read cycle afterwards.
                    squeeze_write_select_q <= 16'd0;
`endif
                    if (lane_index == 5'd15) begin
                        lane_index <= 5'd0;
                        state      <= S_CAPTURE;
                    end else begin
                        lane_index <= lane_index + 5'd1;
                        state <= S_READ_REQ;
                    end
                end

                S_CAPTURE: begin
                    random_vectors <= squeeze_block[767:0];
                    next_state     <= squeeze_block[1023:768];
                    crc_byte_index <= 7'd0;
                    crc_reg        <= 32'hFFFFFFFF;
                    state          <= S_CRC;
                end

                S_CRC: begin
                    if (crc_byte_index == 7'd95) begin
                        vector_crc32 <= ~crc_next;
                        state        <= S_FINISH;
                    end else begin
                        crc_reg        <= crc_next;
                        crc_byte_index <= crc_byte_index + 7'd1;
                    end
                end

                S_FINISH: begin
                    busy  <= 1'b0;
                    done  <= 1'b1;
                    state <= S_IDLE;
                end

`ifdef MLKEM_STREAMING_BALANCED_2BU
                S_SCRUB: begin
                    // SEQUENTIAL_LOAD shifts one zero lane into the Keccak
                    // state on every edge.  After 25 edges no old state bit
                    // remains, while no global 1600-bit clear net is needed.
                    perm_load_lane_data <= 64'd0;
                    if (lane_index == 5'd24) begin
                        lane_index <= 5'd0;
                        busy       <= 1'b0;
                        state      <= S_IDLE;
                    end else begin
                        lane_index <= lane_index + 5'd1;
                    end
                end
`endif

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
