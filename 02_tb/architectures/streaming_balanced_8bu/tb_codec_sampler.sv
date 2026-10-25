`timescale 1ns/1ps

module tb_codec_sampler;

    logic clk;
    logic rst_n;

    logic codec_start;
    logic codec_encode;
    logic [3:0] codec_d;
    logic codec_load_coeff_we;
    logic [7:0] codec_load_coeff_addr;
    logic [11:0] codec_load_coeff_data;
    logic codec_load_byte_we;
    logic [8:0] codec_load_byte_addr;
    logic [7:0] codec_load_byte_data;
    logic [7:0] codec_read_coeff_addr;
    logic [11:0] codec_read_coeff_data;
    logic [8:0] codec_read_byte_addr;
    logic [7:0] codec_read_byte_data;
    logic codec_busy;
    logic codec_done;
    logic codec_invalid_d;
    logic [31:0] codec_cycles;

    logic sampler_start;
    logic sampler_cbd;
    logic sampler_load_we;
    logic [9:0] sampler_load_addr;
    logic [7:0] sampler_load_data;
    logic [7:0] sampler_read_addr;
    logic [11:0] sampler_read_data;
    logic sampler_busy;
    logic sampler_done;
    logic sampler_error;
    logic [31:0] sampler_cycles;

    logic [7:0] byte_vector [0:839];
    logic [7:0] coefficient_bytes [0:511];
    integer index;
    integer errors;
    integer value;

    byte_codec_core u_codec (
        .clk                      (clk),
        .rst_n                    (rst_n),
        .start                    (codec_start),
        .encode                   (codec_encode),
        .d                        (codec_d),
        .load_coefficient_we      (codec_load_coeff_we),
        .load_coefficient_address (codec_load_coeff_addr),
        .load_coefficient_data    (codec_load_coeff_data),
        .load_byte_we             (codec_load_byte_we),
        .load_byte_address        (codec_load_byte_addr),
        .load_byte_data           (codec_load_byte_data),
        .read_coefficient_address (codec_read_coeff_addr),
        .read_coefficient_data    (codec_read_coeff_data),
        .read_byte_address        (codec_read_byte_addr),
        .read_byte_data           (codec_read_byte_data),
        .busy                     (codec_busy),
        .done                     (codec_done),
        .invalid_d                (codec_invalid_d),
        .cycle_count              (codec_cycles)
    );

    mlkem_sampler u_sampler (
        .clk                      (clk),
        .rst_n                    (rst_n),
        .start                    (sampler_start),
        .sample_cbd               (sampler_cbd),
        .load_byte_we             (sampler_load_we),
        .load_byte_address        (sampler_load_addr),
        .load_byte_data           (sampler_load_data),
        .read_coefficient_address (sampler_read_addr),
        .read_coefficient_data    (sampler_read_data),
        .busy                     (sampler_busy),
        .done                     (sampler_done),
        .sample_error             (sampler_error),
        .cycle_count              (sampler_cycles)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task automatic codec_case(input integer selected_d);
        string coeff_file;
        string packed_file;
        integer packed_bytes;
        begin
            coeff_file = $sformatf("03_vectors/full/codec/d%0d_coeff.hex", selected_d);
            packed_file = $sformatf("03_vectors/full/codec/d%0d_packed.hex", selected_d);
            packed_bytes = 32 * selected_d;
            $readmemh(coeff_file, coefficient_bytes, 0, 511);
            $readmemh(packed_file, byte_vector, 0, packed_bytes - 1);

            for (index = 0; index < 256; index = index + 1) begin
                @(negedge clk);
                codec_load_coeff_we   = 1'b1;
                codec_load_coeff_addr = index[7:0];
                codec_load_coeff_data = {
                    coefficient_bytes[2 * index], coefficient_bytes[2 * index + 1]
                };
            end
            @(negedge clk);
            codec_load_coeff_we = 1'b0;
            codec_encode = 1'b1;
            codec_d = selected_d[3:0];
            codec_start = 1'b1;
            @(negedge clk);
            codec_start = 1'b0;
            wait (codec_done);

            errors = 0;
            for (index = 0; index < packed_bytes; index = index + 1) begin
                @(negedge clk);
                codec_read_byte_addr = index[8:0];
                @(posedge clk);
                #1;
                if (codec_read_byte_data !== byte_vector[index])
                    errors = errors + 1;
            end
            if (errors)
                $fatal(1, "BYTE_ENCODE d=%0d errors=%0d", selected_d, errors);

            for (index = 0; index < packed_bytes; index = index + 1) begin
                @(negedge clk);
                codec_load_byte_we   = 1'b1;
                codec_load_byte_addr = index[8:0];
                codec_load_byte_data = byte_vector[index];
            end
            @(negedge clk);
            codec_load_byte_we = 1'b0;
            codec_encode = 1'b0;
            codec_start = 1'b1;
            @(negedge clk);
            codec_start = 1'b0;
            wait (codec_done);

            errors = 0;
            for (index = 0; index < 256; index = index + 1) begin
                @(negedge clk);
                codec_read_coeff_addr = index[7:0];
                @(posedge clk);
                #1;
                value = {coefficient_bytes[2 * index], coefficient_bytes[2 * index + 1]};
                if (codec_read_coeff_data !== value[11:0])
                    errors = errors + 1;
            end
            if (errors)
                $fatal(1, "BYTE_DECODE d=%0d errors=%0d", selected_d, errors);
            $display("BYTE_CODEC_d%0d: PASS", selected_d);
        end
    endtask

    task automatic sampler_case(
        input string stream_file,
        input string expected_file,
        input integer stream_bytes,
        input logic use_cbd
    );
        begin
            $readmemh(stream_file, byte_vector, 0, stream_bytes - 1);
            $readmemh(expected_file, coefficient_bytes, 0, 511);
            for (index = 0; index < stream_bytes; index = index + 1) begin
                @(negedge clk);
                sampler_load_we   = 1'b1;
                sampler_load_addr = index[9:0];
                sampler_load_data = byte_vector[index];
            end
            @(negedge clk);
            sampler_load_we = 1'b0;
            sampler_cbd = use_cbd;
            sampler_start = 1'b1;
            @(negedge clk);
            sampler_start = 1'b0;
            wait (sampler_done);
            if (sampler_error)
                $fatal(1, "SAMPLER reported error");

            errors = 0;
            for (index = 0; index < 256; index = index + 1) begin
                @(negedge clk);
                sampler_read_addr = index[7:0];
                @(posedge clk);
                #1;
                value = {coefficient_bytes[2 * index], coefficient_bytes[2 * index + 1]};
                if (sampler_read_data !== value[11:0])
                    errors = errors + 1;
            end
            if (errors)
                $fatal(1, "SAMPLER cbd=%0d errors=%0d", use_cbd, errors);
            $display("SAMPLER_%s: PASS", use_cbd ? "CBD2" : "NTT");
        end
    endtask

    initial begin
        rst_n = 1'b0;
        codec_start = 1'b0;
        codec_encode = 1'b0;
        codec_d = 4'd0;
        codec_load_coeff_we = 1'b0;
        codec_load_coeff_addr = 8'd0;
        codec_load_coeff_data = 12'd0;
        codec_load_byte_we = 1'b0;
        codec_load_byte_addr = 9'd0;
        codec_load_byte_data = 8'd0;
        codec_read_coeff_addr = 8'd0;
        codec_read_byte_addr = 9'd0;
        sampler_start = 1'b0;
        sampler_cbd = 1'b0;
        sampler_load_we = 1'b0;
        sampler_load_addr = 10'd0;
        sampler_load_data = 8'd0;
        sampler_read_addr = 8'd0;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;

        codec_case(1);
        codec_case(4);
        codec_case(5);
        codec_case(10);
        codec_case(11);
        codec_case(12);
        sampler_case(
            "03_vectors/full/sample/ntt_stream.hex",
            "03_vectors/full/sample/ntt_expected.hex", 840, 1'b0
        );
        sampler_case(
            "03_vectors/full/sample/cbd_stream.hex",
            "03_vectors/full/sample/cbd_expected.hex", 128, 1'b1
        );
        $display("CODEC_SAMPLER_REGRESSION: PASS");
        $finish;
    end

endmodule
