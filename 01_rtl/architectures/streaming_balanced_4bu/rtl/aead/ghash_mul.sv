// Four-bit-per-clock GF(2^128) multiplier for GCM (SP 800-38D Algorithm 1).
// Four identical MSB-first recurrence steps are unrolled combinationally, so
// the result is bit-for-bit equal to the 128-cycle reference implementation
// while each 128-bit block completes in 32 clocks.
module ghash_mul (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         zeroize,
    input  logic         start,
    input  logic [127:0] x,
    input  logic [127:0] h,
    output logic [127:0] result,
    output logic         busy,
    output logic         done
);
    localparam logic [127:0] REDUCTION =
        128'he1000000000000000000000000000000;

    logic [127:0] a, v, z;
    logic [4:0] count;
    logic [127:0] a_next, v_next, z_next;
    logic [127:0] a_step, v_step, z_step;
    integer step;

    always_comb begin
        a_step = a;
        v_step = v;
        z_step = z;
        for (step = 0; step < 4; step = step + 1) begin
            if (a_step[127])
                z_step = z_step ^ v_step;
            a_step = {a_step[126:0], 1'b0};
            v_step = (v_step >> 1) ^
                     (v_step[0] ? REDUCTION : 128'd0);
        end
        a_next = a_step;
        v_next = v_step;
        z_next = z_step;
    end

    // Control receives the synchronized reset.  Secret datapath registers are
    // scrubbed by zeroize; omitting reset from their enables avoids a global
    // reset tree across 512 data bits and improves recovery/Fmax placement.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            count <= 5'd0;
            busy  <= 1'b0;
            done  <= 1'b0;
        end else if (zeroize) begin
            count <= 5'd0;
            busy  <= 1'b0;
            done  <= 1'b0;
        end else begin
            done <= 1'b0;
            if (!busy && start) begin
                count <= 5'd0;
                busy  <= 1'b1;
            end else if (busy) begin
                if (count == 5'd31) begin
                    busy <= 1'b0;
                    done <= 1'b1;
                end else begin
                    count <= count + 5'd1;
                end
            end
        end
    end

    always_ff @(posedge clk) begin
        if (zeroize) begin
            a      <= 128'd0;
            v      <= 128'd0;
            z      <= 128'd0;
            result <= 128'd0;
        end else if (!busy && start && rst_n) begin
            a      <= x;
            v      <= h;
            z      <= 128'd0;
            result <= 128'd0;
        end else if (busy) begin
            a <= a_next;
            v <= v_next;
            z <= z_next;
            if (count == 5'd31)
                result <= z_next;
        end
    end

endmodule
