// Kiem tra suc khoe truc tiep tren chuoi bit tho cua nguon entropy.
//
// RCT (Repetition Count Test): phat hien chuoi bit giong nhau qua dai.
// APT (Adaptive Proportion Test): dem so bit 1 trong cua so 512 mau.
//
// Cac nguong mac dinh mang tinh nguyen mau ky thuat cho demo FPGA.
// Muon tuyen bo danh gia SP 800-90B phai do min-entropy tren phan cung
// thuc va tinh lai nguong theo mo hinh nguon nhieu, khong chi dua vao PASS.
module entropy_health #(
    parameter integer RCT_LIMIT      = 32,
    parameter integer APT_WINDOW     = 512,
    parameter integer APT_LOW_ONES   = 176,
    parameter integer APT_HIGH_ONES  = 336
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        clear,
    input  logic        raw_bit,
    input  logic        raw_valid,

    output logic        startup_done,
    output logic        health_pass,
    output logic        alarm_latched,
    output logic [15:0] rct_fail_count,
    output logic [15:0] apt_fail_count,
    output logic [9:0]  last_apt_ones,
    output logic [31:0] checked_samples
);

    localparam integer RCT_W = (RCT_LIMIT <= 2) ? 1 : $clog2(RCT_LIMIT + 1);
    localparam integer APT_W = (APT_WINDOW <= 2) ? 1 : $clog2(APT_WINDOW);

    logic previous_bit;
    logic previous_valid;
    logic [RCT_W-1:0] repetition_count;
    logic [APT_W-1:0] apt_sample_index;
    logic [9:0] apt_ones_count;
    logic [9:0] apt_ones_with_current;

    assign apt_ones_with_current = apt_ones_count + (raw_bit ? 10'd1 : 10'd0);
    assign health_pass = startup_done && !alarm_latched;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            previous_bit      <= 1'b0;
            previous_valid    <= 1'b0;
            repetition_count  <= '0;
            apt_sample_index  <= '0;
            apt_ones_count    <= 10'd0;
            startup_done      <= 1'b0;
            alarm_latched     <= 1'b0;
            rct_fail_count    <= 16'd0;
            apt_fail_count    <= 16'd0;
            last_apt_ones     <= 10'd0;
            checked_samples   <= 32'd0;
        end else if (clear) begin
            previous_bit      <= 1'b0;
            previous_valid    <= 1'b0;
            repetition_count  <= '0;
            apt_sample_index  <= '0;
            apt_ones_count    <= 10'd0;
            startup_done      <= 1'b0;
            alarm_latched     <= 1'b0;
            rct_fail_count    <= 16'd0;
            apt_fail_count    <= 16'd0;
            last_apt_ones     <= 10'd0;
            checked_samples   <= 32'd0;
        end else if (raw_valid) begin
            checked_samples <= checked_samples + 32'd1;

            if (!previous_valid || (raw_bit != previous_bit)) begin
                previous_bit     <= raw_bit;
                previous_valid   <= 1'b1;
                repetition_count <= {{(RCT_W-1){1'b0}}, 1'b1};
            end else if (repetition_count < RCT_LIMIT) begin
                repetition_count <= repetition_count + 1'b1;
                if (repetition_count == RCT_LIMIT - 1) begin
                    alarm_latched  <= 1'b1;
                    rct_fail_count <= rct_fail_count + 16'd1;
                end
            end

            if (apt_sample_index == APT_WINDOW - 1) begin
                last_apt_ones    <= apt_ones_with_current;
                apt_sample_index <= '0;
                apt_ones_count   <= 10'd0;
                startup_done     <= 1'b1;
                if ((apt_ones_with_current < APT_LOW_ONES) ||
                    (apt_ones_with_current > APT_HIGH_ONES)) begin
                    alarm_latched <= 1'b1;
                    apt_fail_count <= apt_fail_count + 16'd1;
                end
            end else begin
                apt_sample_index <= apt_sample_index + 1'b1;
                if (raw_bit)
                    apt_ones_count <= apt_ones_count + 10'd1;
            end
        end
    end

endmodule
