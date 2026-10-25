// Q=3329 Barrett pipeline, target 160 MHz. Seven registered stages:
// operands -> product -> two 12x15 partial products -> recombine -> q*Q
// -> residue -> correction. Output is valid six clocks after input capture;
// throughput remains one result per clock, including back-to-back inputs.
module mod_mul_pipe (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        in_valid,
    input  logic [11:0] a,
    input  logic [11:0] b,
    output logic        out_valid,
    output logic [11:0] r
);

    localparam logic [11:0] Q_CONST = 12'd3329;
    localparam logic [14:0] RECIP    = 15'd20158;

    logic        valid_s1;
    logic        valid_s0, valid_partial;
    logic        valid_s2;
    logic        valid_s3;
    logic        valid_s4;
    // Keep this architectural boundary explicit.  Without preserve, physical
    // retiming can absorb product_s1 into the input register of the following
    // DSP and recreate a long DSP-to-DSP route in the same timing path.
    (* preserve *) logic [23:0] product_s1;
    logic [11:0] a_s0, b_s0;
    logic [26:0] scaled_low, scaled_high;
    logic [23:0] value_partial;
    logic [23:0] value_s2;
    logic [23:0] value_s3;
    logic [38:0] scaled_s2;
    logic [24:0] q_product_s3;
    logic [24:0] residue_s4;

    // Only validity/control needs reset.  Datapath registers are overwritten
    // every clock and cannot be observed until the validity pipeline fills.
    // Leaving them reset-free removes DSP SCLR muxes and improves packing.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            valid_s0     <= 1'b0;
            valid_partial <= 1'b0;
            valid_s1     <= 1'b0;
            valid_s2     <= 1'b0;
            valid_s3     <= 1'b0;
            valid_s4     <= 1'b0;
            out_valid    <= 1'b0;
        end else begin
            valid_s0  <= in_valid;
            valid_s1  <= valid_s0;
            valid_partial <= valid_s1;
            valid_s2  <= valid_partial;
            valid_s3  <= valid_s2;
            valid_s4  <= valid_s3;
            out_valid <= valid_s4;
        end
    end

    always_ff @(posedge clk) begin
            // Isolate M10K read/mux delay from the first DSP multiplier.
            a_s0 <= a; b_s0 <= b;
            product_s1 <= a_s0 * b_s0;

            // Split the former critical 24x15 multiplier. Both products fit
            // native DSP input widths; recombination is a separate clock.
            scaled_low <= product_s1[11:0] * RECIP;
            scaled_high <= product_s1[23:12] * RECIP;
            value_partial <= product_s1;
            value_s2  <= value_partial;
            scaled_s2 <= {12'd0,scaled_low} + {scaled_high,12'd0};

            // Stage 5: form the multiple of Q.
            value_s3     <= value_s2;
            q_product_s3 <= scaled_s2[38:26] * Q_CONST;

            // Stage 6: provisional residue.
            residue_s4 <= {1'b0, value_s3} - q_product_s3;

            // Tang cuoi: dua ket qua ve mien chuan 0..3328.
            if (residue_s4 >= Q_CONST)
                r <= residue_s4[11:0] - Q_CONST;
            else
                r <= residue_s4[11:0];
    end

endmodule
