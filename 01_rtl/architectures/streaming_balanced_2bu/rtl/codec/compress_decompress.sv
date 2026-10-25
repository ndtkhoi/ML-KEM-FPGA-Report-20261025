// Coefficient-level FIPS 203 Compress_d and Decompress_d.
//
// Supported d values: 1, 4, 5, 10, 11, 12.
//
// Khong dung toan tu "/ 3329" vi Quartus 18.1 se tao mot divider to hop
// rat dai.  Ta dung floor(2^32/3329) = 1290167 de uoc luong thuong, sau
// do hieu chinh mot lan bang so du.  Voi mien dau vao cua ML-KEM, ket qua
// nay chinh xac nhu phep chia nguyen ban dau.
module compress_decompress (
    input  logic [3:0]  d,
    input  logic [11:0] coefficient,
    input  logic [11:0] compressed_input,
    output logic [11:0] compressed_output,
    output logic [11:0] decompressed_output,
    output logic        valid_d
);

    localparam logic [12:0] Q_CONST = 13'd3329;
    localparam logic [20:0] Q_RECIPROCAL = 21'd1290167;

    logic [12:0] scale;
    logic [11:0] mask;
    logic [24:0] compress_numerator;
    logic [45:0] reciprocal_product;
    logic [13:0] quotient_estimate;
    logic [26:0] estimate_times_q;
    logic [26:0] compress_remainder;
    logic [13:0] compress_quotient;
    logic [24:0] decompress_numerator;
    logic [24:0] decompress_shifted;

    always_comb begin
        valid_d = (
            (d == 4'd1)  ||
            (d == 4'd4)  ||
            (d == 4'd5)  ||
            (d == 4'd10) ||
            (d == 4'd11) ||
            (d == 4'd12)
        );

        scale = 13'd1 << d;
        // Lay dung 12 bit thap; voi d=12, 0 - 1 tren 12 bit cho 12'hfff.
        mask  = scale[11:0] - 12'd1;

        compress_numerator = coefficient * scale + (Q_CONST >> 1);
        reciprocal_product = compress_numerator * Q_RECIPROCAL;
        quotient_estimate  = reciprocal_product[45:32];
        estimate_times_q   = quotient_estimate * Q_CONST;
        compress_remainder = {2'b00, compress_numerator} -
                             estimate_times_q;
        compress_quotient  = quotient_estimate +
                             ((compress_remainder >= Q_CONST) ? 14'd1 : 14'd0);
        compressed_output  = compress_quotient[11:0] & mask;

        decompress_numerator =
            compressed_input * Q_CONST + (scale >> 1);
        decompress_shifted = decompress_numerator >> d;
        decompressed_output = decompress_shifted[11:0];

        if (!valid_d) begin
            compressed_output   = 12'd0;
            decompressed_output = 12'd0;
        end
    end

endmodule
