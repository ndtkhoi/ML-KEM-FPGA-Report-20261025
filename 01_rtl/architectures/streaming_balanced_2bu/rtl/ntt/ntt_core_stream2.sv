// 2 radix-2 butterflies per issue clock; 4 conflict-free 1R1W banks.
// Derived from the 4BU snapshot; same 11-clock issue-to-commit pipeline.
// bank(i)={xor(i[7:1]),i[0:0]}; row(i)=i[7:2].
// Eight lanes insert four empty issue clocks at the first forward / last
// inverse stage boundary. Other boundaries and all 2BU stages are continuous.
// These gaps satisfy read-before-write RAM semantics without bypass logic.
// The external interface intentionally matches ntt_core.  The service core,
// UART protocol and FIPS 203 operation schedule therefore remain unchanged.
module ntt_core_stream2 (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        start,
    input  logic        inverse,
    input  logic        load_we,
    input  logic [7:0]  load_address,
    input  logic [11:0] load_data,
    input  logic [7:0]  read_address,
    output logic [11:0] read_data,
    output logic        busy,
    output logic        done,
    output logic [31:0] cycle_count,
    output logic [7:0]  debug_length,
    output logic [7:0]  debug_j,
    output logic [6:0]  debug_zeta_index
);

    localparam integer LANES      = 2;
    localparam integer BANKS      = 4;
    localparam integer MUL_STAGES = 7;

    typedef enum logic [1:0] {S_IDLE, S_ISSUE, S_DRAIN, S_STAGE_GAP} state_t;
    state_t state;
    logic [2:0] gap_left;

    logic       inverse_latched;
    // Capture the transform direction again at the operand boundary.  This
    // register is intentionally not equivalent to inverse_latched (it has a
    // read-valid enable), so Quartus cannot collapse it back into the distant
    // service-core mode register.  Only the arithmetic cones use this copy.
    (* maxfan = 32, preserve, dont_merge *) logic arithmetic_inverse_q;
    logic [2:0] issue_stage, write_stage;
    logic [6:0] issue_base, write_base;
    logic       issue_valid, read_valid, write_valid;
    logic [7:0] issue_length, write_length;
    logic [2:0] issue_address_stage, write_address_stage;

    logic [7:0] issue_addr_a [0:LANES-1];
    logic [7:0] issue_addr_b [0:LANES-1];
    logic [7:0] write_addr_a [0:LANES-1];
    logic [7:0] write_addr_b [0:LANES-1];

    logic [5:0]  bank_read_address  [0:BANKS-1];
    logic [11:0] bank_read_data     [0:BANKS-1];
    logic [5:0]  bank_write_address [0:BANKS-1];
    logic [11:0] bank_write_data    [0:BANKS-1];
    logic        bank_write_enable  [0:BANKS-1];
    logic [5:0]  transform_write_address [0:BANKS-1];
    logic [11:0] transform_write_data    [0:BANKS-1];
    logic        issue_a_upper [0:LANES-1];
    logic        issue_length_two;
    logic        write_a_upper [0:LANES-1];
    logic        write_length_two;

    logic [1:0] external_read_bank_q;
    logic [11:0] external_read_data_q;
    logic [1:0] read_bank_a [0:LANES-1];
    logic [2:0] read_address_stage_q;
    logic [11:0] coefficient_a [0:LANES-1];
    logic [11:0] coefficient_b [0:LANES-1];
    logic        operand_valid_q;
    logic [11:0] operand_a_q    [0:LANES-1];
    logic [11:0] operand_b_q    [0:LANES-1];
    logic [11:0] operand_zeta_q [0:LANES-1];

    logic [6:0]  zeta_index_pair [0:0];
    logic [11:0] zeta_value_pair [0:0];
    logic [11:0] read_zeta [0:LANES-1];

    logic [11:0] inverse_sum        [0:LANES-1];
    logic [11:0] inverse_difference [0:LANES-1];
    logic [11:0] launch_side        [0:LANES-1];
    logic [11:0] launch_value       [0:LANES-1];
    logic [11:0] launch_zeta        [0:LANES-1];
    logic        launch_valid_q;
    logic [11:0] launch_side_q  [0:LANES-1];
    logic [11:0] launch_value_q [0:LANES-1];
    logic [11:0] launch_zeta_q  [0:LANES-1];

    logic        product_valid [0:LANES-1];
    logic [11:0] product       [0:LANES-1];
    logic [11:0] side_delay [0:LANES-1][0:MUL_STAGES-1];
    logic [11:0] forward_sum        [0:LANES-1];
    logic [11:0] forward_difference [0:LANES-1];
    logic [11:0] result_a [0:LANES-1];
    logic [11:0] result_b [0:LANES-1];

    // This boundary is deliberately retained for Cyclone V.  It isolates the
    // four arithmetic cones from the eight M10K write-data inputs.
    logic        writeback_valid_q;
    logic [11:0] result_a_q [0:LANES-1];
    logic [11:0] result_b_q [0:LANES-1];

    // The board reset net is shared by the complete ML-KEM channel.  Feeding
    // it directly into every NTT control/data register produced a measured
    // 4863-fanout reset path.  Keep one local, preserved reset token at the
    // NTT boundary; payload registers below are validity protected and do not
    // need reset values.
    (* maxfan = 32, preserve, dont_merge *) logic ntt_reset_n_q;

    integer route_bank;
    integer reset_lane;
    integer reset_stage;

    function automatic [1:0] bank_of(input logic [7:0] address);
        bank_of = {^address[7:1], address[0:0]};
    endfunction

    function automatic [5:0] row_of(input logic [7:0] address);
        row_of = address[7:2];
    endfunction

    // stage 0 describes length 128, stage 6 describes length 2.  Inserting
    // one zero between group and offset bits implements
    // j = group*(2*length) + offset without a divider or barrel shifter.
    function automatic [7:0] butterfly_j(
        input logic [6:0] butterfly_index,
        input logic [2:0] address_stage
    );
        begin
            case (address_stage)
                3'd0: butterfly_j = {1'b0, butterfly_index};
                3'd1: butterfly_j = {butterfly_index[6], 1'b0,
                                     butterfly_index[5:0]};
                3'd2: butterfly_j = {butterfly_index[6:5], 1'b0,
                                     butterfly_index[4:0]};
                3'd3: butterfly_j = {butterfly_index[6:4], 1'b0,
                                     butterfly_index[3:0]};
                3'd4: butterfly_j = {butterfly_index[6:3], 1'b0,
                                     butterfly_index[2:0]};
                3'd5: butterfly_j = {butterfly_index[6:2], 1'b0,
                                     butterfly_index[1:0]};
                default:
                      butterfly_j = {butterfly_index[6:1], 1'b0,
                                     butterfly_index[0]};
            endcase
        end
    endfunction

    function automatic [6:0] zeta_for(
        input logic [6:0] butterfly_index,
        input logic [2:0] operation_stage,
        input logic       operation_inverse
    );
        begin
            if (!operation_inverse) begin
                case (operation_stage)
                    3'd0: zeta_for = 7'd1;
                    3'd1: zeta_for = 7'd2  + butterfly_index[6];
                    3'd2: zeta_for = 7'd4  + butterfly_index[6:5];
                    3'd3: zeta_for = 7'd8  + butterfly_index[6:4];
                    3'd4: zeta_for = 7'd16 + butterfly_index[6:3];
                    3'd5: zeta_for = 7'd32 + butterfly_index[6:2];
                    default:
                          zeta_for = 7'd64 + butterfly_index[6:1];
                endcase
            end else begin
                case (operation_stage)
                    3'd0: zeta_for = 7'd127 - butterfly_index[6:1];
                    3'd1: zeta_for = 7'd63  - butterfly_index[6:2];
                    3'd2: zeta_for = 7'd31  - butterfly_index[6:3];
                    3'd3: zeta_for = 7'd15  - butterfly_index[6:4];
                    3'd4: zeta_for = 7'd7   - butterfly_index[6:5];
                    3'd5: zeta_for = 7'd3   - butterfly_index[6];
                    default: zeta_for = 7'd1;
                endcase
            end
        end
    endfunction

    function automatic [11:0] half_mod(input logic [11:0] value);
        logic [12:0] even_value;
        begin
            even_value = {1'b0, value} + (value[0] ? 13'd3329 : 13'd0);
            half_mod = even_value[12:1];
        end
    endfunction

    assign issue_valid = state == S_ISSUE;
    assign write_valid = writeback_valid_q && busy;

    assign issue_address_stage = inverse_latched ?
                                 (3'd6 - issue_stage) : issue_stage;
    assign write_address_stage = inverse_latched ?
                                 (3'd6 - write_stage) : write_stage;
    assign issue_length = inverse_latched ?
                          (8'd2 << issue_stage) : (8'd128 >> issue_stage);
    assign write_length = inverse_latched ?
                           (8'd2 << write_stage) : (8'd128 >> write_stage);

    assign issue_length_two = issue_address_stage == 3'd6;
    assign write_length_two = write_address_stage == 3'd6;

    genvar zeta_pair;
    generate for(zeta_pair=0;zeta_pair<LANES/2;zeta_pair=zeta_pair+1) begin : g_zetas
        assign zeta_index_pair[zeta_pair] = zeta_for(issue_base + 2*zeta_pair,
                                                    issue_stage,inverse_latched);
        zetas_rom u_rom(.address(zeta_index_pair[zeta_pair]),.zeta(zeta_value_pair[zeta_pair]));
    end endgenerate
    assign debug_length = issue_length;
    assign debug_j = issue_addr_a[0];
    assign debug_zeta_index = zeta_index_pair[0];

    genvar address_lane;
    generate
        for (address_lane = 0; address_lane < LANES;
             address_lane = address_lane + 1) begin : g_addresses
            assign issue_addr_a[address_lane] =
                butterfly_j(issue_base + address_lane, issue_address_stage);
            assign issue_addr_b[address_lane] =
                issue_addr_a[address_lane] + issue_length;
            assign write_addr_a[address_lane] =
                butterfly_j(write_base + address_lane, write_address_stage);
            assign write_addr_b[address_lane] =
                write_addr_a[address_lane] + write_length;
        end
    endgenerate

    always_comb begin : p_transform_write_mapping
        case(write_address_stage)
            3'd0: begin
                transform_write_address[0] = ((^write_addr_a[0][7:1]) == 1'b0) ? row_of(write_addr_a[0]) : row_of(write_addr_b[0]);
                transform_write_data[0] = ((^write_addr_a[0][7:1]) == 1'b0) ? result_a_q[0] : result_b_q[0];
                transform_write_address[1] = ((^write_addr_a[1][7:1]) == 1'b0) ? row_of(write_addr_a[1]) : row_of(write_addr_b[1]);
                transform_write_data[1] = ((^write_addr_a[1][7:1]) == 1'b0) ? result_a_q[1] : result_b_q[1];
                transform_write_address[2] = ((^write_addr_a[0][7:1]) == 1'b1) ? row_of(write_addr_a[0]) : row_of(write_addr_b[0]);
                transform_write_data[2] = ((^write_addr_a[0][7:1]) == 1'b1) ? result_a_q[0] : result_b_q[0];
                transform_write_address[3] = ((^write_addr_a[1][7:1]) == 1'b1) ? row_of(write_addr_a[1]) : row_of(write_addr_b[1]);
                transform_write_data[3] = ((^write_addr_a[1][7:1]) == 1'b1) ? result_a_q[1] : result_b_q[1];
            end
            3'd1: begin
                transform_write_address[0] = ((^write_addr_a[0][7:1]) == 1'b0) ? row_of(write_addr_a[0]) : row_of(write_addr_b[0]);
                transform_write_data[0] = ((^write_addr_a[0][7:1]) == 1'b0) ? result_a_q[0] : result_b_q[0];
                transform_write_address[1] = ((^write_addr_a[1][7:1]) == 1'b0) ? row_of(write_addr_a[1]) : row_of(write_addr_b[1]);
                transform_write_data[1] = ((^write_addr_a[1][7:1]) == 1'b0) ? result_a_q[1] : result_b_q[1];
                transform_write_address[2] = ((^write_addr_a[0][7:1]) == 1'b1) ? row_of(write_addr_a[0]) : row_of(write_addr_b[0]);
                transform_write_data[2] = ((^write_addr_a[0][7:1]) == 1'b1) ? result_a_q[0] : result_b_q[0];
                transform_write_address[3] = ((^write_addr_a[1][7:1]) == 1'b1) ? row_of(write_addr_a[1]) : row_of(write_addr_b[1]);
                transform_write_data[3] = ((^write_addr_a[1][7:1]) == 1'b1) ? result_a_q[1] : result_b_q[1];
            end
            3'd2: begin
                transform_write_address[0] = ((^write_addr_a[0][7:1]) == 1'b0) ? row_of(write_addr_a[0]) : row_of(write_addr_b[0]);
                transform_write_data[0] = ((^write_addr_a[0][7:1]) == 1'b0) ? result_a_q[0] : result_b_q[0];
                transform_write_address[1] = ((^write_addr_a[1][7:1]) == 1'b0) ? row_of(write_addr_a[1]) : row_of(write_addr_b[1]);
                transform_write_data[1] = ((^write_addr_a[1][7:1]) == 1'b0) ? result_a_q[1] : result_b_q[1];
                transform_write_address[2] = ((^write_addr_a[0][7:1]) == 1'b1) ? row_of(write_addr_a[0]) : row_of(write_addr_b[0]);
                transform_write_data[2] = ((^write_addr_a[0][7:1]) == 1'b1) ? result_a_q[0] : result_b_q[0];
                transform_write_address[3] = ((^write_addr_a[1][7:1]) == 1'b1) ? row_of(write_addr_a[1]) : row_of(write_addr_b[1]);
                transform_write_data[3] = ((^write_addr_a[1][7:1]) == 1'b1) ? result_a_q[1] : result_b_q[1];
            end
            3'd3: begin
                transform_write_address[0] = ((^write_addr_a[0][7:1]) == 1'b0) ? row_of(write_addr_a[0]) : row_of(write_addr_b[0]);
                transform_write_data[0] = ((^write_addr_a[0][7:1]) == 1'b0) ? result_a_q[0] : result_b_q[0];
                transform_write_address[1] = ((^write_addr_a[1][7:1]) == 1'b0) ? row_of(write_addr_a[1]) : row_of(write_addr_b[1]);
                transform_write_data[1] = ((^write_addr_a[1][7:1]) == 1'b0) ? result_a_q[1] : result_b_q[1];
                transform_write_address[2] = ((^write_addr_a[0][7:1]) == 1'b1) ? row_of(write_addr_a[0]) : row_of(write_addr_b[0]);
                transform_write_data[2] = ((^write_addr_a[0][7:1]) == 1'b1) ? result_a_q[0] : result_b_q[0];
                transform_write_address[3] = ((^write_addr_a[1][7:1]) == 1'b1) ? row_of(write_addr_a[1]) : row_of(write_addr_b[1]);
                transform_write_data[3] = ((^write_addr_a[1][7:1]) == 1'b1) ? result_a_q[1] : result_b_q[1];
            end
            3'd4: begin
                transform_write_address[0] = ((^write_addr_a[0][7:1]) == 1'b0) ? row_of(write_addr_a[0]) : row_of(write_addr_b[0]);
                transform_write_data[0] = ((^write_addr_a[0][7:1]) == 1'b0) ? result_a_q[0] : result_b_q[0];
                transform_write_address[1] = ((^write_addr_a[1][7:1]) == 1'b0) ? row_of(write_addr_a[1]) : row_of(write_addr_b[1]);
                transform_write_data[1] = ((^write_addr_a[1][7:1]) == 1'b0) ? result_a_q[1] : result_b_q[1];
                transform_write_address[2] = ((^write_addr_a[0][7:1]) == 1'b1) ? row_of(write_addr_a[0]) : row_of(write_addr_b[0]);
                transform_write_data[2] = ((^write_addr_a[0][7:1]) == 1'b1) ? result_a_q[0] : result_b_q[0];
                transform_write_address[3] = ((^write_addr_a[1][7:1]) == 1'b1) ? row_of(write_addr_a[1]) : row_of(write_addr_b[1]);
                transform_write_data[3] = ((^write_addr_a[1][7:1]) == 1'b1) ? result_a_q[1] : result_b_q[1];
            end
            3'd5: begin
                transform_write_address[0] = ((^write_addr_a[0][7:1]) == 1'b0) ? row_of(write_addr_a[0]) : row_of(write_addr_b[0]);
                transform_write_data[0] = ((^write_addr_a[0][7:1]) == 1'b0) ? result_a_q[0] : result_b_q[0];
                transform_write_address[1] = ((^write_addr_a[1][7:1]) == 1'b0) ? row_of(write_addr_a[1]) : row_of(write_addr_b[1]);
                transform_write_data[1] = ((^write_addr_a[1][7:1]) == 1'b0) ? result_a_q[1] : result_b_q[1];
                transform_write_address[2] = ((^write_addr_a[0][7:1]) == 1'b1) ? row_of(write_addr_a[0]) : row_of(write_addr_b[0]);
                transform_write_data[2] = ((^write_addr_a[0][7:1]) == 1'b1) ? result_a_q[0] : result_b_q[0];
                transform_write_address[3] = ((^write_addr_a[1][7:1]) == 1'b1) ? row_of(write_addr_a[1]) : row_of(write_addr_b[1]);
                transform_write_data[3] = ((^write_addr_a[1][7:1]) == 1'b1) ? result_a_q[1] : result_b_q[1];
            end
            3'd6: begin
                transform_write_address[0] = ((^write_addr_a[0][7:1]) == 1'b0) ? row_of(write_addr_a[0]) : row_of(write_addr_b[0]);
                transform_write_data[0] = ((^write_addr_a[0][7:1]) == 1'b0) ? result_a_q[0] : result_b_q[0];
                transform_write_address[1] = ((^write_addr_a[1][7:1]) == 1'b0) ? row_of(write_addr_a[1]) : row_of(write_addr_b[1]);
                transform_write_data[1] = ((^write_addr_a[1][7:1]) == 1'b0) ? result_a_q[1] : result_b_q[1];
                transform_write_address[2] = ((^write_addr_a[0][7:1]) == 1'b1) ? row_of(write_addr_a[0]) : row_of(write_addr_b[0]);
                transform_write_data[2] = ((^write_addr_a[0][7:1]) == 1'b1) ? result_a_q[0] : result_b_q[0];
                transform_write_address[3] = ((^write_addr_a[1][7:1]) == 1'b1) ? row_of(write_addr_a[1]) : row_of(write_addr_b[1]);
                transform_write_data[3] = ((^write_addr_a[1][7:1]) == 1'b1) ? result_a_q[1] : result_b_q[1];
            end
            default: begin
                transform_write_address[0]='0; transform_write_data[0]='0;
                transform_write_address[1]='0; transform_write_data[1]='0;
                transform_write_address[2]='0; transform_write_data[2]='0;
                transform_write_address[3]='0; transform_write_data[3]='0;
            end
        endcase
    end

    always_comb begin : p_bank_routing
        for(route_bank=0;route_bank<BANKS;route_bank=route_bank+1) begin
            bank_read_address[route_bank]=row_of(read_address);
            bank_write_address[route_bank]=write_valid ? transform_write_address[route_bank] : row_of(load_address);
            bank_write_data[route_bank]=write_valid ? transform_write_data[route_bank] : load_data;
            bank_write_enable[route_bank]=write_valid || ((state==S_IDLE && load_we) && bank_of(load_address)==route_bank);
        end
        if(issue_valid) begin
            case(issue_address_stage)
                3'd0: begin
                    bank_read_address[0] = ((^issue_addr_a[0][7:1]) == 1'b0) ? row_of(issue_addr_a[0]) : row_of(issue_addr_b[0]);
                    bank_read_address[1] = ((^issue_addr_a[1][7:1]) == 1'b0) ? row_of(issue_addr_a[1]) : row_of(issue_addr_b[1]);
                    bank_read_address[2] = ((^issue_addr_a[0][7:1]) == 1'b1) ? row_of(issue_addr_a[0]) : row_of(issue_addr_b[0]);
                    bank_read_address[3] = ((^issue_addr_a[1][7:1]) == 1'b1) ? row_of(issue_addr_a[1]) : row_of(issue_addr_b[1]);
                end
                3'd1: begin
                    bank_read_address[0] = ((^issue_addr_a[0][7:1]) == 1'b0) ? row_of(issue_addr_a[0]) : row_of(issue_addr_b[0]);
                    bank_read_address[1] = ((^issue_addr_a[1][7:1]) == 1'b0) ? row_of(issue_addr_a[1]) : row_of(issue_addr_b[1]);
                    bank_read_address[2] = ((^issue_addr_a[0][7:1]) == 1'b1) ? row_of(issue_addr_a[0]) : row_of(issue_addr_b[0]);
                    bank_read_address[3] = ((^issue_addr_a[1][7:1]) == 1'b1) ? row_of(issue_addr_a[1]) : row_of(issue_addr_b[1]);
                end
                3'd2: begin
                    bank_read_address[0] = ((^issue_addr_a[0][7:1]) == 1'b0) ? row_of(issue_addr_a[0]) : row_of(issue_addr_b[0]);
                    bank_read_address[1] = ((^issue_addr_a[1][7:1]) == 1'b0) ? row_of(issue_addr_a[1]) : row_of(issue_addr_b[1]);
                    bank_read_address[2] = ((^issue_addr_a[0][7:1]) == 1'b1) ? row_of(issue_addr_a[0]) : row_of(issue_addr_b[0]);
                    bank_read_address[3] = ((^issue_addr_a[1][7:1]) == 1'b1) ? row_of(issue_addr_a[1]) : row_of(issue_addr_b[1]);
                end
                3'd3: begin
                    bank_read_address[0] = ((^issue_addr_a[0][7:1]) == 1'b0) ? row_of(issue_addr_a[0]) : row_of(issue_addr_b[0]);
                    bank_read_address[1] = ((^issue_addr_a[1][7:1]) == 1'b0) ? row_of(issue_addr_a[1]) : row_of(issue_addr_b[1]);
                    bank_read_address[2] = ((^issue_addr_a[0][7:1]) == 1'b1) ? row_of(issue_addr_a[0]) : row_of(issue_addr_b[0]);
                    bank_read_address[3] = ((^issue_addr_a[1][7:1]) == 1'b1) ? row_of(issue_addr_a[1]) : row_of(issue_addr_b[1]);
                end
                3'd4: begin
                    bank_read_address[0] = ((^issue_addr_a[0][7:1]) == 1'b0) ? row_of(issue_addr_a[0]) : row_of(issue_addr_b[0]);
                    bank_read_address[1] = ((^issue_addr_a[1][7:1]) == 1'b0) ? row_of(issue_addr_a[1]) : row_of(issue_addr_b[1]);
                    bank_read_address[2] = ((^issue_addr_a[0][7:1]) == 1'b1) ? row_of(issue_addr_a[0]) : row_of(issue_addr_b[0]);
                    bank_read_address[3] = ((^issue_addr_a[1][7:1]) == 1'b1) ? row_of(issue_addr_a[1]) : row_of(issue_addr_b[1]);
                end
                3'd5: begin
                    bank_read_address[0] = ((^issue_addr_a[0][7:1]) == 1'b0) ? row_of(issue_addr_a[0]) : row_of(issue_addr_b[0]);
                    bank_read_address[1] = ((^issue_addr_a[1][7:1]) == 1'b0) ? row_of(issue_addr_a[1]) : row_of(issue_addr_b[1]);
                    bank_read_address[2] = ((^issue_addr_a[0][7:1]) == 1'b1) ? row_of(issue_addr_a[0]) : row_of(issue_addr_b[0]);
                    bank_read_address[3] = ((^issue_addr_a[1][7:1]) == 1'b1) ? row_of(issue_addr_a[1]) : row_of(issue_addr_b[1]);
                end
                3'd6: begin
                    bank_read_address[0] = ((^issue_addr_a[0][7:1]) == 1'b0) ? row_of(issue_addr_a[0]) : row_of(issue_addr_b[0]);
                    bank_read_address[1] = ((^issue_addr_a[1][7:1]) == 1'b0) ? row_of(issue_addr_a[1]) : row_of(issue_addr_b[1]);
                    bank_read_address[2] = ((^issue_addr_a[0][7:1]) == 1'b1) ? row_of(issue_addr_a[0]) : row_of(issue_addr_b[0]);
                    bank_read_address[3] = ((^issue_addr_a[1][7:1]) == 1'b1) ? row_of(issue_addr_a[1]) : row_of(issue_addr_b[1]);
                end
                default: begin
                    bank_read_address[0]='0;
                    bank_read_address[1]='0;
                    bank_read_address[2]='0;
                    bank_read_address[3]='0;
                end
            endcase
        end
    end

    genvar bank_number;
    generate
        for (bank_number = 0; bank_number < BANKS;
             bank_number = bank_number + 1) begin : g_banks
            poly_bank_64_sdp u_bank (
                .clk          (clk),
                .read_address (bank_read_address[bank_number]),
                .read_data    (bank_read_data[bank_number]),
                .write_enable (bank_write_enable[bank_number]),
                .write_address(bank_write_address[bank_number]),
                .write_data   (bank_write_data[bank_number])
            );
        end
    endgenerate

    // Register the bank-selection result before it leaves the NTT.  The
    // service controller prefetches coefficient 0 while waiting for done and
    // stays at one coefficient per clock after this added boundary.
    assign read_data = external_read_data_q;

    always_ff @(posedge clk) begin
        if (!rst_n)
            ntt_reset_n_q <= 1'b0;
        else
            ntt_reset_n_q <= 1'b1;
    end

    // Constant low-bank candidates; only the registered XOR parity selects.
    always_comb begin : p_read_lane_mapping
        case(read_address_stage_q)
            3'd0: begin
                coefficient_a[0] = read_bank_a[0][1] ? bank_read_data[2] : bank_read_data[0];
                coefficient_b[0] = !read_bank_a[0][1] ? bank_read_data[2] : bank_read_data[0];
                coefficient_a[1] = read_bank_a[1][1] ? bank_read_data[3] : bank_read_data[1];
                coefficient_b[1] = !read_bank_a[1][1] ? bank_read_data[3] : bank_read_data[1];
            end
            3'd1: begin
                coefficient_a[0] = read_bank_a[0][1] ? bank_read_data[2] : bank_read_data[0];
                coefficient_b[0] = !read_bank_a[0][1] ? bank_read_data[2] : bank_read_data[0];
                coefficient_a[1] = read_bank_a[1][1] ? bank_read_data[3] : bank_read_data[1];
                coefficient_b[1] = !read_bank_a[1][1] ? bank_read_data[3] : bank_read_data[1];
            end
            3'd2: begin
                coefficient_a[0] = read_bank_a[0][1] ? bank_read_data[2] : bank_read_data[0];
                coefficient_b[0] = !read_bank_a[0][1] ? bank_read_data[2] : bank_read_data[0];
                coefficient_a[1] = read_bank_a[1][1] ? bank_read_data[3] : bank_read_data[1];
                coefficient_b[1] = !read_bank_a[1][1] ? bank_read_data[3] : bank_read_data[1];
            end
            3'd3: begin
                coefficient_a[0] = read_bank_a[0][1] ? bank_read_data[2] : bank_read_data[0];
                coefficient_b[0] = !read_bank_a[0][1] ? bank_read_data[2] : bank_read_data[0];
                coefficient_a[1] = read_bank_a[1][1] ? bank_read_data[3] : bank_read_data[1];
                coefficient_b[1] = !read_bank_a[1][1] ? bank_read_data[3] : bank_read_data[1];
            end
            3'd4: begin
                coefficient_a[0] = read_bank_a[0][1] ? bank_read_data[2] : bank_read_data[0];
                coefficient_b[0] = !read_bank_a[0][1] ? bank_read_data[2] : bank_read_data[0];
                coefficient_a[1] = read_bank_a[1][1] ? bank_read_data[3] : bank_read_data[1];
                coefficient_b[1] = !read_bank_a[1][1] ? bank_read_data[3] : bank_read_data[1];
            end
            3'd5: begin
                coefficient_a[0] = read_bank_a[0][1] ? bank_read_data[2] : bank_read_data[0];
                coefficient_b[0] = !read_bank_a[0][1] ? bank_read_data[2] : bank_read_data[0];
                coefficient_a[1] = read_bank_a[1][1] ? bank_read_data[3] : bank_read_data[1];
                coefficient_b[1] = !read_bank_a[1][1] ? bank_read_data[3] : bank_read_data[1];
            end
            3'd6: begin
                coefficient_a[0] = read_bank_a[0][1] ? bank_read_data[2] : bank_read_data[0];
                coefficient_b[0] = !read_bank_a[0][1] ? bank_read_data[2] : bank_read_data[0];
                coefficient_a[1] = read_bank_a[1][1] ? bank_read_data[3] : bank_read_data[1];
                coefficient_b[1] = !read_bank_a[1][1] ? bank_read_data[3] : bank_read_data[1];
            end
            default: begin
                coefficient_a[0]='0;coefficient_b[0]='0;
                coefficient_a[1]='0;coefficient_b[1]='0;
            end
        endcase
    end

    genvar arithmetic_lane;
    generate
        for (arithmetic_lane = 0; arithmetic_lane < LANES;
             arithmetic_lane = arithmetic_lane + 1) begin : g_arithmetic
            mod_add u_inverse_add (
                .a(operand_a_q[arithmetic_lane]),
                .b(operand_b_q[arithmetic_lane]),
                .r(inverse_sum[arithmetic_lane])
            );

            mod_sub u_inverse_sub (
                .a(operand_b_q[arithmetic_lane]),
                .b(operand_a_q[arithmetic_lane]),
                .r(inverse_difference[arithmetic_lane])
            );

            assign launch_value[arithmetic_lane] = arithmetic_inverse_q ?
                inverse_difference[arithmetic_lane] :
                operand_b_q[arithmetic_lane];
            assign launch_zeta[arithmetic_lane] = arithmetic_inverse_q ?
                half_mod(operand_zeta_q[arithmetic_lane]) :
                operand_zeta_q[arithmetic_lane];
            assign launch_side[arithmetic_lane] = arithmetic_inverse_q ?
                half_mod(inverse_sum[arithmetic_lane]) :
                operand_a_q[arithmetic_lane];

            mod_mul_pipe u_multiply (
                .clk       (clk),
                .rst_n     (ntt_reset_n_q),
                .in_valid  (launch_valid_q),
                .a         (launch_value_q[arithmetic_lane]),
                .b         (launch_zeta_q[arithmetic_lane]),
                .out_valid (product_valid[arithmetic_lane]),
                .r         (product[arithmetic_lane])
            );

            mod_add u_forward_add (
                .a(side_delay[arithmetic_lane][MUL_STAGES-1]),
                .b(product[arithmetic_lane]),
                .r(forward_sum[arithmetic_lane])
            );

            mod_sub u_forward_sub (
                .a(side_delay[arithmetic_lane][MUL_STAGES-1]),
                .b(product[arithmetic_lane]),
                .r(forward_difference[arithmetic_lane])
            );

            assign result_a[arithmetic_lane] = arithmetic_inverse_q ?
                side_delay[arithmetic_lane][MUL_STAGES-1] :
                forward_sum[arithmetic_lane];
            assign result_b[arithmetic_lane] = arithmetic_inverse_q ?
                product[arithmetic_lane] :
                forward_difference[arithmetic_lane];
        end
    endgenerate

    always_ff @(posedge clk) begin
        if (!ntt_reset_n_q) begin
            state                <= S_IDLE;
            gap_left             <= 3'd0;
            inverse_latched      <= 1'b0;
            arithmetic_inverse_q <= 1'b0;
            issue_stage          <= 3'd0;
            write_stage          <= 3'd0;
            issue_base           <= 7'd0;
            write_base           <= 7'd0;
            read_valid           <= 1'b0;
            operand_valid_q      <= 1'b0;
            launch_valid_q       <= 1'b0;
            writeback_valid_q    <= 1'b0;
            busy                 <= 1'b0;
            done                 <= 1'b0;
            cycle_count          <= 32'd0;
            // Datapath registers intentionally retain don't-care values
            // through reset.  The cleared valid pipeline prevents any of
            // them from being committed or externally observed.
        end else begin
            done                 <= 1'b0;
            external_read_bank_q <= bank_of(read_address);
            external_read_data_q <= bank_read_data[external_read_bank_q];
            read_valid           <= issue_valid;
            operand_valid_q      <= read_valid;
            launch_valid_q       <= operand_valid_q;
            writeback_valid_q    <= product_valid[0] && busy;

            if (issue_valid) begin
                for (reset_lane = 0; reset_lane < LANES;
                     reset_lane = reset_lane + 1) begin
                    read_bank_a[reset_lane] <=
                        bank_of(issue_addr_a[reset_lane]);
                end
                read_address_stage_q <= issue_address_stage;
                for(reset_lane=0;reset_lane<LANES;reset_lane=reset_lane+1)
                    read_zeta[reset_lane] <= zeta_value_pair[reset_lane/2];
            end

            if (read_valid) begin
                arithmetic_inverse_q <= inverse_latched;
                for (reset_lane = 0; reset_lane < LANES;
                     reset_lane = reset_lane + 1) begin
                    operand_a_q[reset_lane]    <= coefficient_a[reset_lane];
                    operand_b_q[reset_lane]    <= coefficient_b[reset_lane];
                    operand_zeta_q[reset_lane] <= read_zeta[reset_lane];
                end
            end

            if (operand_valid_q) begin
                for (reset_lane = 0; reset_lane < LANES;
                     reset_lane = reset_lane + 1) begin
                    launch_side_q[reset_lane]  <= launch_side[reset_lane];
                    launch_value_q[reset_lane] <= launch_value[reset_lane];
                    launch_zeta_q[reset_lane]  <= launch_zeta[reset_lane];
                end
            end

            for (reset_lane = 0; reset_lane < LANES;
                 reset_lane = reset_lane + 1) begin
                side_delay[reset_lane][0] <= launch_side_q[reset_lane];
                for (reset_stage = 1; reset_stage < MUL_STAGES;
                     reset_stage = reset_stage + 1)
                    side_delay[reset_lane][reset_stage] <=
                        side_delay[reset_lane][reset_stage-1];
            end

            if (product_valid[0] && busy) begin
                for (reset_lane = 0; reset_lane < LANES;
                     reset_lane = reset_lane + 1) begin
                    result_a_q[reset_lane] <= result_a[reset_lane];
                    result_b_q[reset_lane] <= result_b[reset_lane];
                end
            end

            if (busy)
                cycle_count <= cycle_count + 32'd1;

            case (state)
                S_IDLE: begin
                    if (start) begin
                        inverse_latched   <= inverse;
                        issue_stage       <= 3'd0;
                        write_stage       <= 3'd0;
                        issue_base        <= 7'd0;
                        write_base        <= 7'd0;
                        read_valid        <= 1'b0;
                        operand_valid_q   <= 1'b0;
                        launch_valid_q    <= 1'b0;
                        writeback_valid_q <= 1'b0;
                        gap_left          <= 3'd0;
                        cycle_count       <= 32'd0;
                        busy              <= 1'b1;
                        state             <= S_ISSUE;
                    end
                end

                S_ISSUE: begin
                    if (issue_base == 7'd126) begin
                        issue_base <= 7'd0;
                        if (issue_stage == 3'd6)
                            state <= S_DRAIN;
                        else begin
                            issue_stage <= issue_stage + 3'd1;
                            if (LANES==8 && ((!inverse_latched && issue_stage==3'd0) ||
                                             (inverse_latched && issue_stage==3'd5))) begin
                                gap_left <= 3'd4;
                                state <= S_STAGE_GAP;
                            end
                        end
                    end else begin
                        issue_base <= issue_base + 7'd2;
                    end
                end

                S_STAGE_GAP: begin
                    if (gap_left==3'd1) begin gap_left<=0;state<=S_ISSUE;end
                    else gap_left<=gap_left-3'd1;
                end

                S_DRAIN: begin
                    // Wait for the fixed-latency arithmetic pipelines.
                end

                default: state <= S_IDLE;
            endcase

            if (write_valid) begin
                if (write_base == 7'd126) begin
                    write_base <= 7'd0;
                    if (write_stage == 3'd6) begin
                        busy  <= 1'b0;
                        done  <= 1'b1;
                        state <= S_IDLE;
                    end else begin
                        write_stage <= write_stage + 3'd1;
                    end
                end else begin
                    write_base <= write_base + 7'd2;
                end
            end
        end
    end

`ifndef SYNTHESIS
    // The bank hash is the architectural invariant.  A collision would turn
    // one of the eight simultaneous accesses into silent data corruption.
    integer assert_fill_i;
    integer assert_i;
    integer assert_j;
    logic [7:0] asserted_address [0:3];
    always_comb begin
        for (assert_fill_i = 0; assert_fill_i < LANES;
             assert_fill_i = assert_fill_i + 1) begin
            asserted_address[2*assert_fill_i] = issue_addr_a[assert_fill_i];
            asserted_address[2*assert_fill_i+1] =
                issue_addr_b[assert_fill_i];
        end
    end

    always_ff @(posedge clk) begin
        if (rst_n && issue_valid) begin
            for (assert_i = 0; assert_i < BANKS; assert_i = assert_i + 1)
                for (assert_j = assert_i + 1; assert_j < BANKS;
                     assert_j = assert_j + 1)
                    if (bank_of(asserted_address[assert_i]) ==
                        bank_of(asserted_address[assert_j]))
                        $fatal(1, "stream2 NTT read-bank collision");
        end
    end
`endif

endmodule
