// Streaming radix-2 CT/GS NTT, n=256, q=3329.
// One butterfly per clock, two true dual-port M10K planes with stage barriers.
// INTT divides each stage by 2 in Z_q, absorbing the final factor 1/128.
// FIPS 203 coefficient order, canonical residues and external ports unchanged.
module ntt_core (
    input logic clk, rst_n, start, inverse,
    input logic load_we,
    input logic [7:0] load_address,
    input logic [11:0] load_data,
    input logic [7:0] read_address,
    output logic [11:0] read_data,
    output logic busy, done,
    output logic [31:0] cycle_count,
    output logic [7:0] debug_length, debug_j,
    output logic [6:0] debug_zeta_index
);
    // Seven registered stages, matching mod_mul_pipe; shift tags over bubbles.
    localparam integer MUL_STAGES = 7;
    typedef enum logic [2:0] {S_IDLE,S_ISSUE,S_DRAIN,S_FINISH} state_t;
    state_t state;
    logic inverse_latched, source_bank;
    logic [7:0] length_reg, j_index, group_offset;
    logic [6:0] zeta_index, issued_count, written_count;
    logic issue_valid;
    logic [7:0] issue_b;
    logic [11:0] zeta_value;
    logic [11:0] bank0_a, bank0_b, bank1_a, bank1_b;
    logic [7:0] b0_addr_a,b0_addr_b,b1_addr_a,b1_addr_b;
    logic b0_we_a,b0_we_b,b1_we_a,b1_we_b;
    logic [11:0] b0_data_a,b1_data_a;
    logic read_valid, operand_valid, prepare_valid, launch_valid;
    logic [7:0] read_addr_a,read_addr_b,operand_addr_a,operand_addr_b;
    logic [7:0] prepare_addr_a,prepare_addr_b,launch_addr_a,launch_addr_b;
    logic [11:0] read_zeta,zeta_reg,coefficient_a_reg,coefficient_b_reg;
    logic [11:0] prepare_a,prepare_b,prepare_sum,prepare_diff,prepare_zeta;
    logic [11:0] inverse_sum,inverse_difference;
    logic [11:0] launch_x,launch_zeta,launch_side;
    logic [7:0] tag_a[0:MUL_STAGES-1],tag_b[0:MUL_STAGES-1];
    logic [11:0] side_delay[0:MUL_STAGES-1];
    logic product_valid;
    logic [11:0] product,forward_sum,forward_difference;
    logic write_valid;
    logic [7:0] write_addr_a,write_addr_b;
    logic [11:0] butterfly_a_reg,butterfly_b_reg;
    integer p;
    function automatic [11:0] half_mod(input logic [11:0] value);
        logic [12:0] even_value;
        begin
            even_value = {1'b0,value} + (value[0] ? 13'd3329 : 13'd0);
            half_mod = even_value[12:1];
        end
    endfunction
    assign issue_valid = state == S_ISSUE;
    assign issue_b = j_index + length_reg;
    assign debug_length = length_reg;
    assign debug_j = j_index;
    assign debug_zeta_index = zeta_index;
    assign read_data = source_bank ? bank1_a : bank0_a;
    zetas_rom u_zetas(.address(zeta_index),.zeta(zeta_value));
    mod_add u_inverse_add(.a(coefficient_a_reg),.b(coefficient_b_reg),.r(inverse_sum));
    mod_sub u_inverse_sub(.a(coefficient_b_reg),.b(coefficient_a_reg),.r(inverse_difference));
    mod_mul_pipe u_multiply(.clk(clk),.rst_n(rst_n),.in_valid(launch_valid),
        .a(launch_x),.b(launch_zeta),.out_valid(product_valid),.r(product));
    mod_add u_forward_add(.a(side_delay[MUL_STAGES-1]),.b(product),.r(forward_sum));
    mod_sub u_forward_sub(.a(side_delay[MUL_STAGES-1]),.b(product),.r(forward_difference));
    // Source: two reads/clock. Destination: two writes/clock.
    // Never consume a mixed-port read-during-write result.
    always_comb begin
        b0_addr_a=0; b0_addr_b=0; b1_addr_a=0; b1_addr_b=0;
        b0_we_a=0; b0_we_b=0; b1_we_a=0; b1_we_b=0;
        b0_data_a=butterfly_a_reg; b1_data_a=butterfly_a_reg;
        if (state==S_IDLE) begin
            if (source_bank) begin
                b1_addr_a=load_we ? load_address : read_address;
                b1_we_a=load_we; b1_data_a=load_data;
            end else begin
                b0_addr_a=load_we ? load_address : read_address;
                b0_we_a=load_we; b0_data_a=load_data;
            end
        end else if (source_bank) begin
            b1_addr_a=j_index; b1_addr_b=issue_b;
            b0_addr_a=write_addr_a; b0_addr_b=write_addr_b;
            b0_we_a=write_valid; b0_we_b=write_valid;
        end else begin
            b0_addr_a=j_index; b0_addr_b=issue_b;
            b1_addr_a=write_addr_a; b1_addr_b=write_addr_b;
            b1_we_a=write_valid; b1_we_b=write_valid;
        end
    end
    poly_ram_dp u_bank0(.clk(clk),.we_a(b0_we_a),.addr_a(b0_addr_a),
        .data_a(b0_data_a),.q_a(bank0_a),.we_b(b0_we_b),.addr_b(b0_addr_b),
        .data_b(butterfly_b_reg),.q_b(bank0_b));
    poly_ram_dp u_bank1(.clk(clk),.we_a(b1_we_a),.addr_a(b1_addr_a),
        .data_a(b1_data_a),.q_a(bank1_a),.we_b(b1_we_b),.addr_b(b1_addr_b),
        .data_b(butterfly_b_reg),.q_b(bank1_b));
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state<=S_IDLE; inverse_latched<=0; source_bank<=0;
            length_reg<=0; j_index<=0; group_offset<=0; zeta_index<=0;
            issued_count<=0; written_count<=0;
            busy<=0; done<=0; cycle_count<=0;
            read_valid<=0; operand_valid<=0; prepare_valid<=0; launch_valid<=0;
            read_addr_a<=0; read_addr_b<=0; read_zeta<=0;
            operand_addr_a<=0; operand_addr_b<=0;
            coefficient_a_reg<=0; coefficient_b_reg<=0; zeta_reg<=0;
            prepare_addr_a<=0; prepare_addr_b<=0;
            prepare_a<=0; prepare_b<=0; prepare_sum<=0; prepare_diff<=0; prepare_zeta<=0;
            launch_addr_a<=0; launch_addr_b<=0;
            launch_x<=0; launch_zeta<=0; launch_side<=0;
            write_valid<=0; write_addr_a<=0; write_addr_b<=0;
            butterfly_a_reg<=0; butterfly_b_reg<=0;
            for(p=0;p<MUL_STAGES;p=p+1) begin
                tag_a[p]<=0; tag_b[p]<=0; side_delay[p]<=0;
            end
        end else begin
            done<=0;
            if(busy) cycle_count<=cycle_count+32'd1;
            // Address/twiddle tag accompanies the synchronous RAM read.
            read_valid<=issue_valid;
            read_addr_a<=j_index; read_addr_b<=issue_b; read_zeta<=zeta_value;
            operand_valid<=read_valid;
            coefficient_a_reg<=read_valid ? (source_bank ? bank1_a : bank0_a) : 12'd0;
            coefficient_b_reg<=read_valid ? (source_bank ? bank1_b : bank0_b) : 12'd0;
            operand_addr_a<=read_addr_a; operand_addr_b<=read_addr_b; zeta_reg<=read_zeta;
            // Isolate RAM Tco, modular add/sub and division-by-two mux.
            prepare_valid<=operand_valid;
            prepare_a<=coefficient_a_reg; prepare_b<=coefficient_b_reg;
            prepare_sum<=inverse_sum; prepare_diff<=inverse_difference;
            prepare_zeta<=zeta_reg;
            prepare_addr_a<=operand_addr_a; prepare_addr_b<=operand_addr_b;
            launch_valid<=prepare_valid;
            launch_x<=inverse_latched ? prepare_diff : prepare_b;
            launch_zeta<=inverse_latched ? half_mod(prepare_zeta) : prepare_zeta;
            launch_side<=inverse_latched ? half_mod(prepare_sum) : prepare_a;
            launch_addr_a<=prepare_addr_a; launch_addr_b<=prepare_addr_b;
            tag_a[0]<=launch_addr_a; tag_b[0]<=launch_addr_b;
            side_delay[0]<=launch_valid ? launch_side : 12'd0;
            for(p=1;p<MUL_STAGES;p=p+1) begin
                tag_a[p]<=tag_a[p-1]; tag_b[p]<=tag_b[p-1];
                side_delay[p]<=side_delay[p-1];
            end
            write_valid<=product_valid;
            write_addr_a<=tag_a[MUL_STAGES-1]; write_addr_b<=tag_b[MUL_STAGES-1];
            butterfly_a_reg<=inverse_latched ? side_delay[MUL_STAGES-1] : forward_sum;
            butterfly_b_reg<=inverse_latched ? product : forward_difference;
            case(state)
                S_IDLE: if(start) begin
                    inverse_latched<=inverse; length_reg<=inverse ? 8'd2 : 8'd128;
                    j_index<=0; group_offset<=0; zeta_index<=inverse ? 7'd127 : 7'd1;
                    issued_count<=0; written_count<=0; cycle_count<=0;
                    busy<=1; state<=S_ISSUE;
                end
                S_ISSUE: begin
                    issued_count<=issued_count+7'd1;
                    if(group_offset==length_reg-8'd1) begin
                        group_offset<=0; j_index<=j_index+length_reg+8'd1;
                        zeta_index<=inverse_latched ? zeta_index-7'd1 : zeta_index+7'd1;
                    end else begin
                        group_offset<=group_offset+8'd1; j_index<=j_index+8'd1;
                    end
                    if(issued_count==7'd127) state<=S_DRAIN;
                end
                S_DRAIN: begin end
                S_FINISH: begin busy<=0; done<=1; state<=S_IDLE; end
                default: begin busy<=0; state<=S_IDLE; end
            endcase
            // Last commit is the barrier: next stage only reads completed data.
            if(write_valid && busy) begin
                written_count<=written_count+7'd1;
                if(written_count==7'd127) begin
                    source_bank<=!source_bank;
                    if((!inverse_latched && length_reg==8'd2) ||
                       (inverse_latched && length_reg==8'd128))
                        state<=S_FINISH;
                    else begin
                        length_reg<=inverse_latched ? length_reg<<1 : length_reg>>1;
                        issued_count<=0; written_count<=0; group_offset<=0; j_index<=0;
                        state<=S_ISSUE;
                    end
                end
            end
        end
    end
endmodule
