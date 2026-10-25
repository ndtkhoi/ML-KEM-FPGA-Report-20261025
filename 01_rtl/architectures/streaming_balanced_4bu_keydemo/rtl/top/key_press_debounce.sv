// Active-low mechanical button. A stable release arms one stable press.
// Holding KEY1 during reset or while busy never queues another transaction.
module key_press_debounce #(
    parameter integer STABLE_CYCLES = 3200000,
    parameter integer COUNT_WIDTH = (STABLE_CYCLES < 2) ? 1 : $clog2(STABLE_CYCLES)
) (
    input logic clk, rst_n, key_n,
    output logic pressed
);
    (* async_reg = "true" *) logic key_meta, key_sync;
    logic armed;
    logic [COUNT_WIDTH-1:0] stable_count;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            key_meta<=0; key_sync<=0; armed<=0; stable_count<=0; pressed<=0;
        end else begin
            key_meta<=key_n; key_sync<=key_meta; pressed<=0;
            if (key_sync == armed) stable_count<=0;
            else if (stable_count == STABLE_CYCLES-1) begin
                stable_count<=0; armed<=key_sync;
                if (!key_sync) pressed<=1;
            end else stable_count<=stable_count+1'b1;
        end
    end
endmodule
