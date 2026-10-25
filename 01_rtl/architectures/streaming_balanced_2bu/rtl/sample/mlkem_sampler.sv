// Streaming FIPS 203 SampleNTT and SamplePolyCBD_eta=2.
//
// The byte source is consumed at one byte per clock.  Coefficients are split
// by parity into two 128x12 memories, allowing both 12-bit rejection-sampling
// candidates (or both CBD nibbles) to commit in the same clock.  This changes
// only the schedule: coefficient order and arithmetic are identical to the
// byte-serial reference sampler.
module mlkem_sampler (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        start,
    input  logic        sample_cbd,

    input  logic        load_byte_we,
    input  logic [9:0]  load_byte_address,
    input  logic [7:0]  load_byte_data,

    input  logic [7:0]  read_coefficient_address,
    output logic [11:0] read_coefficient_data,

    output logic        busy,
    output logic        done,
    output logic        sample_error,
    output logic [31:0] cycle_count
);

    typedef enum logic [1:0] {
        S_IDLE,
        S_NTT_STREAM,
        S_CBD_STREAM,
        S_FINISH
    } state_t;

    state_t state;
    // The service loads this RAM only while the sampler is idle.  There is
    // therefore no architecturally visible read-during-write case; disabling
    // the inferred collision/forwarding mux keeps the M10K read path short.
    (* ramstyle = "no_rw_check, M10K" *) logic [7:0]  byte_memory [0:839];
    (* ramstyle = "M10K" *) logic [11:0] coefficient_even [0:127];
    (* ramstyle = "M10K" *) logic [11:0] coefficient_odd  [0:127];

    logic [9:0] byte_read_address;
    logic [7:0] byte_q;
    logic [9:0] byte_index;
    logic [1:0] byte_phase;
    logic [8:0] coefficient_count;
    logic [7:0] byte0, byte1;

    logic [11:0] candidate0, candidate1;
    logic accept0, accept1;
    logic [8:0] count_after1;
    logic any_accept, pair_accept;
    logic [11:0] first_accepted_data;

    logic even_we, odd_we;
    logic [6:0] even_write_address, odd_write_address;
    logic [11:0] even_write_data, odd_write_data;
    logic [11:0] coefficient_even_q, coefficient_odd_q;
    logic read_coefficient_bank_q;

    function automatic [11:0] cbd_eta2(input logic [3:0] nibble);
        logic [2:0] a_count, b_count;
        begin
            a_count = {2'd0, nibble[0]} + {2'd0, nibble[1]};
            b_count = {2'd0, nibble[2]} + {2'd0, nibble[3]};
            cbd_eta2 = (a_count >= b_count)
                ? (a_count - b_count)
                : (12'd3329 - (b_count - a_count));
        end
    endfunction

    assign candidate0 = {byte1[3:0], byte0};
    assign candidate1 = {byte_q, byte1[7:4]};
    // During NTT streaming the counter is in [0,255].  Its bit 8 is the
    // terminal value 256, so the old 9-bit ``count_after0 < 256`` compare can
    // be reduced to a single bit and removed from the candidate-1 timing cone.
    assign accept0 = (state == S_NTT_STREAM) && (byte_phase == 2'd2) &&
                     (candidate0 < 12'd3329) && !coefficient_count[8];
    // Candidate 1 is rejected only when candidate 0 consumes the final slot
    // (count 255).  This is equivalent to testing a post-candidate count,
    // without
    // putting an incrementer in front of the accept1 signal.
    assign accept1 = (state == S_NTT_STREAM) && (byte_phase == 2'd2) &&
                     (candidate1 < 12'd3329) &&
                     ((coefficient_count[7:0] != 8'hFF) || !accept0);
    // Make the increment amount explicit so Quartus can implement one
    // incrementer and a small select instead of two cascaded incrementers.
    always_comb begin
        case ({accept0, accept1})
            2'b11:   count_after1 = coefficient_count + 9'd2;
            2'b10,
            2'b01:   count_after1 = coefficient_count + 9'd1;
            default: count_after1 = coefficient_count;
        endcase
    end
    assign any_accept = accept0 || accept1;
    assign pair_accept = accept0 && accept1;
    // If candidate 0 is rejected, candidate 1 occupies its slot.  Express
    // that compaction once, before the parity-bank routing, instead of making
    // each RAM data port depend on the generic destination incrementer.
    assign first_accepted_data = accept0 ? candidate0 : candidate1;

    // Keep the single-port byte RAM advancing while the current registered
    // byte is consumed.  Address 839 is held to avoid an out-of-range read.
    always_comb begin
        byte_read_address = 10'd0;
        if (state == S_NTT_STREAM || state == S_CBD_STREAM)
            byte_read_address = (byte_index < 10'd839)
                ? byte_index + 10'd1 : byte_index;
    end

    // Route at most one write to each parity bank.  When both candidates are
    // accepted their destinations are consecutive, hence necessarily land in
    // different banks.
    always_comb begin
        even_we = 1'b0;
        odd_we  = 1'b0;
        even_write_address = 7'd0;
        odd_write_address  = 7'd0;
        even_write_data = 12'd0;
        odd_write_data  = 12'd0;

        if (state == S_NTT_STREAM && byte_phase == 2'd2) begin
            // Accepted coefficients are consecutive.  Therefore the first
            // accepted value always goes to the bank selected by the current
            // count and, only when both candidates are accepted, candidate 1
            // goes to the opposite bank.  This parity-specialized crossbar
            // removes count_after0 and two cascaded destination/data muxes
            // from the M10K write-data path.
            if (!coefficient_count[0]) begin
                even_we            = any_accept;
                even_write_address = coefficient_count[7:1];
                even_write_data    = first_accepted_data;
                odd_we             = pair_accept;
                odd_write_address  = coefficient_count[7:1];
                odd_write_data     = candidate1;
            end else begin
                odd_we             = any_accept;
                odd_write_address  = coefficient_count[7:1];
                odd_write_data     = first_accepted_data;
                even_we            = pair_accept;
                even_write_address = coefficient_count[7:1] + 7'd1;
                even_write_data    = candidate1;
            end
        end else if (state == S_CBD_STREAM) begin
            // coefficient_count is even throughout CBD operation.
            even_we = 1'b1;
            odd_we  = 1'b1;
            even_write_address = coefficient_count[7:1];
            odd_write_address  = coefficient_count[7:1];
            even_write_data = cbd_eta2(byte_q[3:0]);
            odd_write_data  = cbd_eta2(byte_q[7:4]);
        end
    end

    // Synchronous memories.  The public coefficient port keeps the original
    // one-clock read latency even though the storage is physically banked.
    always_ff @(posedge clk) begin
        // The service controller only loads this RAM before asserting start.
        // Do not fold the sampler busy/state decode into the M10K write-enable:
        // Quartus may otherwise reuse that internal RAM control register in
        // the coefficient counter feedback path.
        if (load_byte_we)
            byte_memory[load_byte_address] <= load_byte_data;
        byte_q <= byte_memory[byte_read_address];

        if (even_we)
            coefficient_even[even_write_address] <= even_write_data;
        if (odd_we)
            coefficient_odd[odd_write_address] <= odd_write_data;

        coefficient_even_q <= coefficient_even[read_coefficient_address[7:1]];
        coefficient_odd_q  <= coefficient_odd[read_coefficient_address[7:1]];
        read_coefficient_bank_q <= read_coefficient_address[0];
    end

    assign read_coefficient_data = read_coefficient_bank_q
        ? coefficient_odd_q : coefficient_even_q;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state             <= S_IDLE;
            byte_index        <= 10'd0;
            byte_phase        <= 2'd0;
            coefficient_count <= 9'd0;
            byte0             <= 8'd0;
            byte1             <= 8'd0;
            busy              <= 1'b0;
            done              <= 1'b0;
            sample_error      <= 1'b0;
            cycle_count       <= 32'd0;
        end else begin
            done <= 1'b0;
            if (busy)
                cycle_count <= cycle_count + 32'd1;

            case (state)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        byte_index        <= 10'd0;
                        byte_phase        <= 2'd0;
                        coefficient_count <= 9'd0;
                        sample_error      <= 1'b0;
                        cycle_count       <= 32'd0;
                        busy              <= 1'b1;
                        state <= sample_cbd ? S_CBD_STREAM : S_NTT_STREAM;
                    end
                end

                S_NTT_STREAM: begin
                    if (byte_phase == 2'd0) begin
                        byte0      <= byte_q;
                        byte_phase <= 2'd1;
                    end else if (byte_phase == 2'd1) begin
                        byte1      <= byte_q;
                        byte_phase <= 2'd2;
                    end else begin
                        coefficient_count <= count_after1;
                        byte_phase <= 2'd0;
                        if (count_after1 == 9'd256) begin
                            state <= S_FINISH;
                        end else if (byte_index == 10'd839) begin
                            sample_error <= 1'b1;
                            state <= S_FINISH;
                        end
                    end
                    if (byte_index < 10'd839)
                        byte_index <= byte_index + 10'd1;
                end

                S_CBD_STREAM: begin
                    coefficient_count <= coefficient_count + 9'd2;
                    byte_index <= byte_index + 10'd1;
                    if (coefficient_count == 9'd254)
                        state <= S_FINISH;
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

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (rst_n && busy && load_byte_we)
            $fatal(1, "Sampler byte load attempted while busy");
        if (rst_n && pair_accept && !even_we)
            $fatal(1, "Streaming sampler lost even-bank write");
        if (rst_n && pair_accept && !odd_we)
            $fatal(1, "Streaming sampler lost odd-bank write");
    end
`endif

endmodule
