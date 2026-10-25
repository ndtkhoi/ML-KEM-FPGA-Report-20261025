// Nguon entropy vat ly danh cho Cyclone V.
//
// Khi tong hop, moi ring oscillator gom ba LUT dao tao thanh vong le.
// Quartus duoc yeu cau giu lai cac LUT va cho phep vong to hop. Moi dau
// ra RO bat dong bo duoc dua qua hai FF rieng truoc khi tron XOR. Cach
// nay ngan metastability/glitch cua mot RO lan vao cay XOR trong mien clk.
//
// Khi mo phong, khong the mo phong jitter vat ly bang RTL. Nhanh mo phong
// dung LFSR chi de kiem tra FSM, health test va giao tiep; khong duoc xem
// la bang chung entropy.
module fpga_ro_entropy #(
    parameter integer RO_COUNT   = 16,
    parameter integer RO_STAGES  = 3,
    parameter integer SAMPLE_DIV = 16
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        enable,
    output logic        raw_bit,
    output logic        raw_valid,
    output logic [31:0] sample_count
);

    localparam integer DIV_W = (SAMPLE_DIV <= 2) ? 1 : $clog2(SAMPLE_DIV);
    localparam integer TAP_COUNT = RO_COUNT * RO_STAGES;

    logic [DIV_W-1:0] divider_count;
    logic entropy_meta;
    logic entropy_sync;

`ifdef SYNTHESIS
    // Mang wire hai chieu chi ton tai o nhanh tong hop FPGA.
    // altera_attribute ngan fitter rut gon hay gop cac ring oscillator.
    (* keep = "true", preserve = "true", dont_merge = "true" *)
    wire [RO_STAGES-1:0] ring_node [0:RO_COUNT-1];
    wire [TAP_COUNT-1:0] ring_tap;

    // Khong XOR truc tiep cac dau ra bat dong bo. Moi RO co mot chuoi
    // dong bo rieng; preserve/dont_merge ngan retiming hay gop cac FF
    // dau tien, vi do la ranh gioi metastability cua tung nguon entropy.
    (* preserve = "true", dont_merge = "true" *)
    logic [TAP_COUNT-1:0] ring_meta;
    (* preserve = "true", dont_merge = "true" *)
    logic [TAP_COUNT-1:0] ring_sync;
    wire [RO_COUNT-1:0] ring_vote;

    genvar ro_index;
    genvar stage_index;
    generate
        for (ro_index = 0; ro_index < RO_COUNT; ro_index = ro_index + 1) begin : g_ro
            for (stage_index = 0; stage_index < RO_STAGES;
                 stage_index = stage_index + 1) begin : g_stage
                // lut_mask 0x5555... tao ham NOT(dataa).
                // Moi dau ra LUT co fanout chuc nang den FF ring_meta ben
                // duoi. Nho vay keep co the giu tung tang ma Fitter van duoc
                // phep chon ALM/routing hop le cho vong hoi tiep.
                (* keep = "true", preserve = "true", dont_merge = "true",
                   altera_attribute = "-name ADV_NETLIST_OPT_ALLOWED NEVER_ALLOW" *)
                cyclonev_lcell_comb #(
                    .lut_mask(64'h5555555555555555)
                ) u_ro_lut (
                    .dataa  (ring_node[ro_index][(stage_index + 1) % RO_STAGES]),
                    .datab  (1'b0),
                    .datac  (1'b0),
                    .datad  (1'b0),
                    .datae  (1'b0),
                    .dataf  (1'b0),
                    .datag  (1'b0),
                    .cin    (1'b0),
                    .sharein(1'b0),
                    .combout(ring_node[ro_index][stage_index])
                );
                assign ring_tap[ro_index * RO_STAGES + stage_index] =
                    ring_node[ro_index][stage_index];
            end

            // Majority cua ba pha lien tiep tao mot bit cho moi RO va lam
            // giam xung hep. Cau hinh san pham dung RO_STAGES=3.
            assign ring_vote[ro_index] =
                (ring_sync[ro_index * RO_STAGES] &
                 ring_sync[ro_index * RO_STAGES + 1]) |
                (ring_sync[ro_index * RO_STAGES] &
                 ring_sync[ro_index * RO_STAGES + 2]) |
                (ring_sync[ro_index * RO_STAGES + 1] &
                 ring_sync[ro_index * RO_STAGES + 2]);
        end
    endgenerate

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            ring_meta <= '0;
            ring_sync <= '0;
        end else begin
            ring_meta <= ring_tap;
            ring_sync <= ring_meta;
        end
    end

    // Tu day tro di, cay XOR chi nhan cac tin hieu da duoc dong bo.
    wire entropy_combined = ^ring_vote;
`else
    // Mo hinh chuc nang co chu ky dai va khong lap lai ngan. Day khong
    // phai TRNG va chi duoc dung trong ModelSim.
    logic [31:0] simulation_lfsr;
    wire entropy_combined = simulation_lfsr[0] ^ simulation_lfsr[5] ^
                            simulation_lfsr[9] ^ simulation_lfsr[31];

    always_ff @(posedge clk) begin
        if (!rst_n)
            simulation_lfsr <= 32'h6D2B79F5;
        else if (enable)
            simulation_lfsr <= {
                simulation_lfsr[30:0],
                simulation_lfsr[31] ^ simulation_lfsr[21] ^
                simulation_lfsr[1] ^ simulation_lfsr[0]
            };
    end
`endif

    // Dang ky ket qua XOR. O nhanh FPGA, tung RO da duoc dong bo rieng
    // phia tren; hai FF nay tao ranh gioi timing sach cho bo chia mau.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            entropy_meta <= 1'b0;
            entropy_sync <= 1'b0;
        end else begin
            entropy_meta <= entropy_combined;
            entropy_sync <= entropy_meta;
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            divider_count <= '0;
            raw_bit       <= 1'b0;
            raw_valid     <= 1'b0;
            sample_count  <= 32'd0;
        end else begin
            raw_valid <= 1'b0;
            if (!enable) begin
                divider_count <= '0;
            end else if (divider_count == SAMPLE_DIV - 1) begin
                divider_count <= '0;
                raw_bit       <= entropy_sync;
                raw_valid     <= 1'b1;
                sample_count  <= sample_count + 32'd1;
            end else begin
                divider_count <= divider_count + 1'b1;
            end
        end
    end

endmodule
