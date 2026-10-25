// Giai ma ky tu cho LED 7 doan active-low tren DE10-Standard.
// symbol 0..15 hien thi 0..F; 16..26 la cac ky tu dung cho demo.
module seg7_decode (
    input  logic [4:0] symbol,
    output logic [6:0] segments
);

    always_comb begin
        case (symbol)
            5'd0:  segments = 7'b1000000;
            5'd1:  segments = 7'b1111001;
            5'd2:  segments = 7'b0100100;
            5'd3:  segments = 7'b0110000;
            5'd4:  segments = 7'b0011001;
            5'd5:  segments = 7'b0010010;
            5'd6:  segments = 7'b0000010;
            5'd7:  segments = 7'b1111000;
            5'd8:  segments = 7'b0000000;
            5'd9:  segments = 7'b0010000;
            5'd10: segments = 7'b0001000; // A
            5'd11: segments = 7'b0000011; // b
            5'd12: segments = 7'b1000110; // C
            5'd13: segments = 7'b0100001; // d
            5'd14: segments = 7'b0000110; // E
            5'd15: segments = 7'b0001110; // F
            5'd17: segments = 7'b0001100; // P
            5'd18: segments = 7'b0010010; // S
            5'd19: segments = 7'b0101111; // r
            5'd20: segments = 7'b1000001; // U
            5'd21: segments = 7'b0101011; // n
            5'd22: segments = 7'b0100001; // d
            5'd23: segments = 7'b0010001; // Y
            5'd24: segments = 7'b1111001; // I
            5'd25: segments = 7'b1000111; // L
            5'd26: segments = 7'b1000010; // G
            default: segments = 7'b1111111; // blank
        endcase
    end

endmodule
