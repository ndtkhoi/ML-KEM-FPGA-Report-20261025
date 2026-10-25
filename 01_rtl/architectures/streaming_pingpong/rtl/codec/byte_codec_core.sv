// ByteEncode_d va ByteDecode_d tuan tu theo FIPS 203.
// Ho tro d = 1, 4, 5, 10, 11, 12 cho ML-KEM-768/1024.
module byte_codec_core (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        start,
    input  logic        encode,
    input  logic [3:0]  d,

    input  logic        load_coefficient_we,
    input  logic [7:0]  load_coefficient_address,
    input  logic [11:0] load_coefficient_data,
    input  logic        load_byte_we,
    input  logic [8:0]  load_byte_address,
    input  logic [7:0]  load_byte_data,

    input  logic [7:0]  read_coefficient_address,
    output logic [11:0] read_coefficient_data,
    input  logic [8:0]  read_byte_address,
    output logic [7:0]  read_byte_data,

    output logic        busy,
    output logic        done,
    output logic        invalid_d,
    output logic [31:0] cycle_count
);

    typedef enum logic [3:0] {
        S_IDLE,
        S_ENCODE_APPEND,
        S_ENCODE_EMIT,
        S_DECODE_FILL,
        S_DECODE_VALUE,
        S_FINISH
    } state_t;

    state_t state;
    logic [11:0] coefficient_q;
    logic [7:0] byte_q;
    logic [7:0] coefficient_port_address;
    logic [8:0] byte_port_address;
    logic coefficient_we, byte_we;
    logic [11:0] coefficient_write_data;
    logic [7:0] byte_write_data;
    logic [3:0]  d_reg;
    logic [7:0]  coefficient_index;
    logic [8:0]  byte_index;
    logic [31:0] bit_buffer;
    logic [5:0]  bit_count;
    logic [31:0] append_buffer;
    logic [5:0]  append_count;
    logic [11:0] decoded_value;
    logic [12:0] decoded_sub_q;

    assign append_buffer = bit_buffer |
        ({20'd0, coefficient_q} << bit_count);
    assign append_count = bit_count + d_reg;
    assign decoded_value = bit_buffer[11:0] & ((12'd1 << d_reg) - 12'd1);
    // d=12 has no mask. Use the subtraction borrow as the >=q test instead
    // of mask -> comparator -> subtractor on the M10K data-input path.
    // 0 <= raw <= 4095 < 2q, so one subtraction is sufficient.
    assign decoded_sub_q = {1'b0, bit_buffer[11:0]} - 13'd3329;

    // Moi RAM co mot cong noi bo doc/ghi va mot cong doc ben ngoai.
    // Nap truoc dia chi tiep theo de giu nguyen so chu ky codec.
    // Khong ghi RAM tu FSM co reset: Quartus se dung M10K thay cho FF/mux.
    always_comb begin
        coefficient_port_address = coefficient_index;
        if (!busy && load_coefficient_we)
            coefficient_port_address = load_coefficient_address;
        else if (state == S_IDLE && start)
            coefficient_port_address = 8'd0;
        else if (state == S_ENCODE_EMIT && bit_count < 8 && coefficient_index != 255)
            coefficient_port_address = coefficient_index + 8'd1;

        byte_port_address = byte_index;
        if (!busy && load_byte_we)
            byte_port_address = load_byte_address;
        else if (state == S_IDLE && start)
            byte_port_address = 9'd0;
        else if (state == S_DECODE_FILL)
            byte_port_address = byte_index + 9'd1;

        coefficient_we = (!busy && load_coefficient_we) ||
                         (state == S_DECODE_VALUE && bit_count >= d_reg);
        coefficient_write_data = load_coefficient_data;
        if (busy)
            coefficient_write_data = (d_reg == 12)
                ? (decoded_sub_q[12] ? bit_buffer[11:0] : decoded_sub_q[11:0])
                : decoded_value;
        byte_we = (!busy && load_byte_we) ||
                  (state == S_ENCODE_EMIT && bit_count >= 8);
        byte_write_data = busy ? bit_buffer[7:0] : load_byte_data;
    end

    poly_ram_dp #(.DATA_WIDTH(12),.ADDR_WIDTH(8),.DEPTH(256)) u_coefficients (
        .clk(clk),.we_a(coefficient_we),.addr_a(coefficient_port_address),
        .data_a(coefficient_write_data),.q_a(coefficient_q),
        .we_b(1'b0),.addr_b(read_coefficient_address),.data_b(12'd0),.q_b(read_coefficient_data)
    );
    poly_ram_dp #(.DATA_WIDTH(8),.ADDR_WIDTH(9),.DEPTH(384)) u_bytes (
        .clk(clk),.we_a(byte_we),.addr_a(byte_port_address),
        .data_a(byte_write_data),.q_a(byte_q),
        .we_b(1'b0),.addr_b(read_byte_address),.data_b(8'd0),.q_b(read_byte_data)
    );

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state             <= S_IDLE;
            d_reg             <= 4'd0;
            coefficient_index <= 8'd0;
            byte_index        <= 9'd0;
            bit_buffer        <= 32'd0;
            bit_count         <= 6'd0;
            busy              <= 1'b0;
            done              <= 1'b0;
            invalid_d         <= 1'b0;
            cycle_count       <= 32'd0;
        end else begin
            done <= 1'b0;
            if (busy)
                cycle_count <= cycle_count + 32'd1;

            case (state)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        d_reg             <= d;
                        coefficient_index <= 8'd0;
                        byte_index        <= 9'd0;
                        bit_buffer        <= 32'd0;
                        bit_count         <= 6'd0;
                        cycle_count       <= 32'd0;
                        invalid_d         <= !(
                            (d == 4'd1) || (d == 4'd4) || (d == 4'd5) ||
                            (d == 4'd10) || (d == 4'd11) || (d == 4'd12)
                        );
                        busy  <= 1'b1;
                        state <= encode ? S_ENCODE_APPEND : S_DECODE_FILL;
                    end
                end

                S_ENCODE_APPEND: begin
                    bit_buffer <= append_buffer;
                    bit_count  <= append_count;
                    state      <= S_ENCODE_EMIT;
                end

                S_ENCODE_EMIT: begin
                    if (bit_count >= 6'd8) begin
                        byte_index <= byte_index + 9'd1;
                        bit_buffer <= bit_buffer >> 8;
                        bit_count  <= bit_count - 6'd8;
                    end else if (coefficient_index == 8'd255) begin
                        state <= S_FINISH;
                    end else begin
                        coefficient_index <= coefficient_index + 8'd1;
                        state <= S_ENCODE_APPEND;
                    end
                end

                S_DECODE_FILL: begin
                    bit_buffer <= bit_buffer |
                        ({24'd0, byte_q} << bit_count);
                    bit_count <= bit_count + 6'd8;
                    byte_index <= byte_index + 9'd1;
                    state <= S_DECODE_VALUE;
                end

                S_DECODE_VALUE: begin
                    if (bit_count >= d_reg) begin
                        bit_buffer <= bit_buffer >> d_reg;
                        bit_count  <= bit_count - d_reg;

                        if (coefficient_index == 8'd255)
                            state <= S_FINISH;
                        else begin
                            coefficient_index <= coefficient_index + 8'd1;
                            if ((bit_count - d_reg) >= d_reg)
                                state <= S_DECODE_VALUE;
                            else
                                state <= S_DECODE_FILL;
                        end
                    end else begin
                        state <= S_DECODE_FILL;
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
