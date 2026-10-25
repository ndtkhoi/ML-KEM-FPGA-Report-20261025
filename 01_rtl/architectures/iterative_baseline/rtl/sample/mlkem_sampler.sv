// SampleNTT va SamplePolyCBD_eta=2 tuan tu cho ML-KEM-768/1024.
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

    typedef enum logic [3:0] {
        S_IDLE,
        S_NTT_BYTE0,
        S_NTT_BYTE1,
        S_NTT_BYTE2,
        S_NTT_FIRST,
        S_NTT_SECOND,
        S_CBD_BYTE,
        S_CBD_LOW,
        S_CBD_HIGH,
        S_FINISH
    } state_t;

    state_t state;
    (* ramstyle = "M10K" *) logic [7:0] byte_memory [0:839];
    (* ramstyle = "M10K" *) logic [11:0] coefficient_memory [0:255];
    logic [9:0] byte_read_address;
    logic [7:0] byte_q;
    logic coefficient_we;
    logic [11:0] coefficient_write_data;
    logic [9:0]  byte_index;
    logic [8:0]  coefficient_count;
    logic [7:0]  byte0;
    logic [7:0]  byte1;
    logic [7:0]  byte2;
    logic [11:0] candidate0;
    logic [11:0] candidate1;
    logic [3:0]  cbd_nibble;
    logic [2:0]  cbd_a;
    logic [2:0]  cbd_b;
    logic [11:0] cbd_value;

    assign candidate0 = {byte1[3:0], byte0};
    assign candidate1 = {byte2, byte1[7:4]};
    assign cbd_a = cbd_nibble[0] + cbd_nibble[1];
    assign cbd_b = cbd_nibble[2] + cbd_nibble[3];
    assign cbd_value = (cbd_a >= cbd_b)
        ? (cbd_a - cbd_b)
        : (12'd3329 - (cbd_b - cbd_a));

    // Doc RAM dong bo, nap truoc byte 1/2 trong luc dung byte 0/1.
    // Hai trang thai nhan he so tao san khoang doc cho nhom 3 byte tiep.
    always_comb begin
        byte_read_address = byte_index;
        if (state == S_IDLE) byte_read_address = 10'd0;
        else if (state == S_NTT_BYTE0) byte_read_address = byte_index + 10'd1;
        else if (state == S_NTT_BYTE1) byte_read_address = byte_index + 10'd2;

        coefficient_we = 1'b0;
        coefficient_write_data = cbd_value;
        if (state == S_NTT_FIRST) begin
            coefficient_we = candidate0 < 3329;
            coefficient_write_data = candidate0;
        end else if (state == S_NTT_SECOND) begin
            coefficient_we = candidate1 < 3329 && coefficient_count < 256;
            coefficient_write_data = candidate1;
        end else if (state == S_CBD_HIGH) coefficient_we = 1'b1;
    end

    always_ff @(posedge clk) begin
        if (!busy && load_byte_we)
            byte_memory[load_byte_address] <= load_byte_data;
        byte_q <= byte_memory[byte_read_address];
        if (coefficient_we)
            coefficient_memory[coefficient_count[7:0]] <= coefficient_write_data;
        read_coefficient_data <= coefficient_memory[read_coefficient_address];
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state             <= S_IDLE;
            byte_index        <= 10'd0;
            coefficient_count <= 9'd0;
            byte0             <= 8'd0;
            byte1             <= 8'd0;
            byte2             <= 8'd0;
            cbd_nibble        <= 4'd0;
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
                        coefficient_count <= 9'd0;
                        sample_error      <= 1'b0;
                        cycle_count       <= 32'd0;
                        busy              <= 1'b1;
                        state <= sample_cbd ? S_CBD_BYTE : S_NTT_BYTE0;
                    end
                end

                S_NTT_BYTE0: begin
                    byte0 <= byte_q;
                    state <= S_NTT_BYTE1;
                end

                S_NTT_BYTE1: begin
                    byte1 <= byte_q;
                    state <= S_NTT_BYTE2;
                end

                S_NTT_BYTE2: begin
                    byte2 <= byte_q;
                    byte_index <= byte_index + 10'd3;
                    state <= S_NTT_FIRST;
                end

                S_NTT_FIRST: begin
                    if (candidate0 < 12'd3329) begin
                        coefficient_count <= coefficient_count + 9'd1;
                    end
                    state <= S_NTT_SECOND;
                end

                S_NTT_SECOND: begin
                    if ((candidate1 < 12'd3329) &&
                        (coefficient_count < 9'd256)) begin
                        coefficient_count <= coefficient_count + 9'd1;
                    end

                    if ((coefficient_count >= 9'd256) ||
                        ((candidate1 < 12'd3329) &&
                         (coefficient_count == 9'd255))) begin
                        state <= S_FINISH;
                    end else if (byte_index >= 10'd840) begin
                        sample_error <= 1'b1;
                        state <= S_FINISH;
                    end else begin
                        state <= S_NTT_BYTE0;
                    end
                end

                S_CBD_BYTE: begin
                    byte0 <= byte_q;
                    byte_index <= byte_index + 10'd1;
                    state <= S_CBD_LOW;
                end

                S_CBD_LOW: begin
                    cbd_nibble <= byte0[3:0];
                    state <= S_CBD_HIGH;
                end

                S_CBD_HIGH: begin
                    // Gia tri cua nibble thap da on dinh tu chu ky truoc.
                    coefficient_count <= coefficient_count + 9'd1;
                    cbd_nibble <= byte0[7:4];

                    if (coefficient_count[0] == 1'b0) begin
                        state <= S_CBD_HIGH;
                    end else if (coefficient_count == 9'd255) begin
                        state <= S_FINISH;
                    end else begin
                        state <= S_CBD_BYTE;
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
