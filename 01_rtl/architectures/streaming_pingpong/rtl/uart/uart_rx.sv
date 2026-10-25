// Bo thu UART 8-N-1, 115200 baud voi clock mac dinh 50 MHz.
// Dau vao bat dong bo duoc qua hai flip-flop truoc khi lay mau giua bit.
module uart_rx #(
    parameter integer CLOCK_HZ = 50_000_000,
    parameter integer BAUD = 115_200,
    parameter integer CLKS_PER_BIT = (CLOCK_HZ + (BAUD / 2)) / BAUD
) (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       rx,
    output logic [7:0] data,
    output logic       valid,
    output logic       framing_error,
    output logic       busy
);

    localparam integer HALF_CLKS = CLKS_PER_BIT / 2;
    localparam integer COUNT_WIDTH = $clog2(CLKS_PER_BIT + 1);

    typedef enum logic [1:0] {
        S_IDLE,
        S_START,
        S_DATA,
        S_STOP
    } state_t;

    state_t state;
    logic rx_meta;
    logic rx_sync;
    logic [COUNT_WIDTH-1:0] clock_count;
    logic [2:0] bit_index;
    logic [7:0] data_reg;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            rx_meta <= 1'b1;
            rx_sync <= 1'b1;
        end else begin
            rx_meta <= rx;
            rx_sync <= rx_meta;
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state         <= S_IDLE;
            clock_count   <= '0;
            bit_index     <= 3'd0;
            data_reg      <= 8'd0;
            data          <= 8'd0;
            valid         <= 1'b0;
            framing_error <= 1'b0;
            busy          <= 1'b0;
        end else begin
            valid         <= 1'b0;
            framing_error <= 1'b0;

            case (state)
                S_IDLE: begin
                    busy        <= 1'b0;
                    clock_count <= '0;
                    if (!rx_sync) begin
                        busy  <= 1'b1;
                        state <= S_START;
                    end
                end

                S_START: begin
                    if (clock_count == HALF_CLKS - 1) begin
                        clock_count <= '0;
                        if (!rx_sync) begin
                            bit_index <= 3'd0;
                            state     <= S_DATA;
                        end else begin
                            // Xung thap qua ngan, khong phai start bit hop le.
                            busy  <= 1'b0;
                            state <= S_IDLE;
                        end
                    end else begin
                        clock_count <= clock_count + 1'b1;
                    end
                end

                S_DATA: begin
                    if (clock_count == CLKS_PER_BIT - 1) begin
                        clock_count          <= '0;
                        data_reg[bit_index]  <= rx_sync;
                        if (bit_index == 3'd7)
                            state <= S_STOP;
                        else
                            bit_index <= bit_index + 3'd1;
                    end else begin
                        clock_count <= clock_count + 1'b1;
                    end
                end

                S_STOP: begin
                    if (clock_count == CLKS_PER_BIT - 1) begin
                        clock_count <= '0;
                        busy        <= 1'b0;
                        if (rx_sync) begin
                            data  <= data_reg;
                            valid <= 1'b1;
                        end else begin
                            framing_error <= 1'b1;
                        end
                        state <= S_IDLE;
                    end else begin
                        clock_count <= clock_count + 1'b1;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
