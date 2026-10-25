// Bo phat UART 8-N-1, khong parity, mot stop bit.
// Gia tri mac dinh tao baud 115200 tu clock 50 MHz (434 clock/bit).
module uart_tx #(
    parameter integer CLOCK_HZ = 50_000_000,
    parameter integer BAUD     = 115_200,
    parameter integer CLKS_PER_BIT = (CLOCK_HZ + (BAUD / 2)) / BAUD
) (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       valid,
    input  logic [7:0] data,
    output logic       ready,
    output logic       tx,
    output logic       busy,
    output logic       done
);

    localparam integer COUNT_WIDTH = $clog2(CLKS_PER_BIT);

    logic [COUNT_WIDTH-1:0] clock_count;
    logic [3:0]             bit_index;
    logic [7:0]             data_reg;

    assign ready = !busy;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            clock_count <= '0;
            bit_index   <= 4'd0;
            data_reg    <= 8'd0;
            tx          <= 1'b1;
            busy        <= 1'b0;
            done        <= 1'b0;
        end else begin
            done <= 1'b0;

            if (!busy) begin
                tx <= 1'b1;
                if (valid) begin
                    data_reg    <= data;
                    clock_count <= '0;
                    bit_index   <= 4'd0;
                    tx          <= 1'b0; // start bit
                    busy        <= 1'b1;
                end
            end else if (clock_count == CLKS_PER_BIT - 1) begin
                clock_count <= '0;
                if (bit_index < 4'd8) begin
                    tx        <= data_reg[bit_index];
                    bit_index <= bit_index + 4'd1;
                end else if (bit_index == 4'd8) begin
                    tx        <= 1'b1; // stop bit
                    bit_index <= 4'd9;
                end else begin
                    tx   <= 1'b1;
                    busy <= 1'b0;
                    done <= 1'b1;
                end
            end else begin
                clock_count <= clock_count + 1'b1;
            end
        end
    end

endmodule
