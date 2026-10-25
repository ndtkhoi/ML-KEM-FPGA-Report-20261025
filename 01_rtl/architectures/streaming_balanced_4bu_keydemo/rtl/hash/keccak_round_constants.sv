module keccak_round_constants (
    input  logic [4:0]  round_index,
    output logic [63:0] round_constant
);

    always_comb begin
        case (round_index)
            5'd0:  round_constant = 64'h0000000000000001;
            5'd1:  round_constant = 64'h0000000000008082;
            5'd2:  round_constant = 64'h800000000000808A;
            5'd3:  round_constant = 64'h8000000080008000;
            5'd4:  round_constant = 64'h000000000000808B;
            5'd5:  round_constant = 64'h0000000080000001;
            5'd6:  round_constant = 64'h8000000080008081;
            5'd7:  round_constant = 64'h8000000000008009;
            5'd8:  round_constant = 64'h000000000000008A;
            5'd9:  round_constant = 64'h0000000000000088;
            5'd10: round_constant = 64'h0000000080008009;
            5'd11: round_constant = 64'h000000008000000A;
            5'd12: round_constant = 64'h000000008000808B;
            5'd13: round_constant = 64'h800000000000008B;
            5'd14: round_constant = 64'h8000000000008089;
            5'd15: round_constant = 64'h8000000000008003;
            5'd16: round_constant = 64'h8000000000008002;
            5'd17: round_constant = 64'h8000000000000080;
            5'd18: round_constant = 64'h000000000000800A;
            5'd19: round_constant = 64'h800000008000000A;
            5'd20: round_constant = 64'h8000000080008081;
            5'd21: round_constant = 64'h8000000000008080;
            5'd22: round_constant = 64'h0000000080000001;
            5'd23: round_constant = 64'h8000000080008008;
            default: round_constant = 64'd0;
        endcase
    end

endmodule
