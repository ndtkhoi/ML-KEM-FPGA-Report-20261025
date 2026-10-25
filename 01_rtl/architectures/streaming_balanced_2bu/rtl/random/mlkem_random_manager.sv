// Quan ly entropy va sinh dung 96 byte d || z || m cho mot lan self-test.
// Duong random chi san sang sau khi health test khoi dong PASS va da thu
// du 512 bit entropy moi. Moi yeu cau generate deu tieu thu mot pool moi.
module mlkem_random_manager (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         generate_start,
    input  logic         zeroize,
    input  logic         raw_bit,
    input  logic         raw_valid,
    input  logic         health_pass,
    input  logic         health_alarm,

    output logic [255:0] seed_d,
    output logic [255:0] seed_z,
    output logic [255:0] message_m,
    output logic [31:0]  vector_crc32,
    output logic [31:0]  generate_cycles,
    output logic [31:0]  reseed_count,
    output logic         pool_full,
    output logic         ready,
    output logic         busy,
    output logic         done
);

    logic [511:0] entropy_pool;
    logic [8:0] entropy_index;
    logic [255:0] drbg_state;
    logic [31:0] request_counter;

    logic drbg_start;
    logic drbg_zeroize;
    logic drbg_busy;
    logic drbg_done;
    logic [767:0] drbg_vectors;
    logic [255:0] drbg_next_state;
    logic [31:0] drbg_crc32;
    logic [31:0] drbg_cycles;

    assign ready = pool_full && health_pass && !health_alarm && !busy;
    assign drbg_zeroize = zeroize || health_alarm;

    shake256_drbg u_drbg (
        .clk            (clk),
        .rst_n          (rst_n),
        .start          (drbg_start),
        .zeroize        (drbg_zeroize),
        .entropy_input  (entropy_pool),
        .previous_state (drbg_state),
        .request_counter(request_counter),
        .random_vectors (drbg_vectors),
        .next_state     (drbg_next_state),
        .vector_crc32   (drbg_crc32),
        .cycle_count    (drbg_cycles),
        .busy           (drbg_busy),
        .done           (drbg_done)
    );

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            entropy_pool   <= 512'd0;
            entropy_index  <= 9'd0;
            drbg_state     <= 256'd0;
            request_counter <= 32'd1;
            seed_d         <= 256'd0;
            seed_z         <= 256'd0;
            message_m      <= 256'd0;
            vector_crc32   <= 32'd0;
            generate_cycles <= 32'd0;
            reseed_count   <= 32'd0;
            pool_full      <= 1'b0;
            drbg_start     <= 1'b0;
            busy           <= 1'b0;
            done           <= 1'b0;
        end else if (health_alarm) begin
            entropy_pool   <= 512'd0;
            entropy_index  <= 9'd0;
            drbg_state     <= 256'd0;
            seed_d         <= 256'd0;
            seed_z         <= 256'd0;
            message_m      <= 256'd0;
            vector_crc32   <= 32'd0;
            generate_cycles <= 32'd0;
            pool_full      <= 1'b0;
            drbg_start     <= 1'b0;
            busy           <= 1'b0;
            done           <= 1'b0;
        end else begin
            drbg_start <= 1'b0;
            done       <= 1'b0;

            // Sau khi DRBG da nhan pool, xoa pool cu va thu pool moi.
            if (drbg_start) begin
                entropy_pool  <= 512'd0;
                entropy_index <= 9'd0;
                pool_full     <= 1'b0;
            end else if (raw_valid && health_pass && !pool_full) begin
                entropy_pool[entropy_index] <= raw_bit;
                if (entropy_index == 9'd511) begin
                    entropy_index <= 9'd0;
                    pool_full     <= 1'b1;
                end else begin
                    entropy_index <= entropy_index + 9'd1;
                end
            end

            if (zeroize) begin
                // Khong xoa cac bo dem bang chung khong nhay cam.
                entropy_pool   <= 512'd0;
                entropy_index  <= 9'd0;
                drbg_state     <= 256'd0;
                seed_d         <= 256'd0;
                seed_z         <= 256'd0;
                message_m      <= 256'd0;
                vector_crc32   <= 32'd0;
                generate_cycles <= 32'd0;
                pool_full      <= 1'b0;
                drbg_start     <= 1'b0;
                busy           <= 1'b0;
            end else if (generate_start && ready) begin
                drbg_start <= 1'b1;
                busy       <= 1'b1;
            end else if (drbg_done) begin
                seed_d          <= drbg_vectors[255:0];
                seed_z          <= drbg_vectors[511:256];
                message_m       <= drbg_vectors[767:512];
                drbg_state      <= drbg_next_state;
                vector_crc32    <= drbg_crc32;
                generate_cycles <= drbg_cycles;
                request_counter <= request_counter + 32'd1;
                reseed_count    <= reseed_count + 32'd1;
                busy            <= 1'b0;
                done            <= 1'b1;
            end
        end
    end

endmodule
