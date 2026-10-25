// FIPS 203 BaseCaseMultiply stream: one coefficient pair issued per clock.
// Reuses the existing five Barrett pipelines: four independent products,
// followed by the gamma product. Separate input/result RAMs permit overlap.
module multiply_ntts_core (
    input logic clk,rst_n,start,
    input logic load_a_we,load_b_we,
    input logic [7:0] load_address,
    input logic [11:0] load_a_data,load_b_data,
    input logic [7:0] read_address,
    output logic [11:0] read_data,
    output logic busy,done,
    output logic [31:0] cycle_count,
    output logic [6:0] debug_pair_index
);
    localparam integer MUL_STAGES=7; // registered stages in mod_mul_pipe
    typedef enum logic [1:0] {S_IDLE,S_ISSUE,S_DRAIN,S_FINISH} state_t;
    state_t state;
    logic [6:0] pair_index,written_count,read_pair;
    logic issue_valid,read_valid,write_valid;
    logic [7:0] a_addr_a,a_addr_b,b_addr_a,b_addr_b;
    logic [7:0] c_addr_a,c_addr_b;
    logic [11:0] a_q_a,a_q_b,b_q_a,b_q_b,c_q_a,c_q_b;
    logic [11:0] gamma,read_gamma;
    logic [3:0] products_valid;
    logic gamma_valid;
    logic [11:0] a0_b0_pipe,a1_b1_pipe,a0_b1_pipe,a1_b0_pipe;
    logic [11:0] gamma_product,base_c0,base_c1,c0_reg,c1_reg;
    logic [11:0] gamma_delay[0:MUL_STAGES-1];
    logic [11:0] a0b0_delay[0:MUL_STAGES-1],c1_delay[0:MUL_STAGES-1];
    logic [6:0] pair_first[0:MUL_STAGES-1],pair_second[0:MUL_STAGES-1];
    logic [6:0] write_pair;
    integer p;
    assign debug_pair_index=pair_index;
    assign issue_valid=state==S_ISSUE;
    assign read_data=c_q_a;
    assign a_addr_a=(state==S_IDLE) ? load_address : {pair_index,1'b0};
    assign a_addr_b={pair_index,1'b1};
    assign b_addr_a=a_addr_a;
    assign b_addr_b=a_addr_b;
    assign c_addr_a=(state==S_IDLE) ? read_address : {write_pair,1'b0};
    assign c_addr_b={write_pair,1'b1};
    poly_ram_dp u_input_a(.clk(clk),.we_a(load_a_we && state==S_IDLE),
        .addr_a(a_addr_a),.data_a(load_a_data),.q_a(a_q_a),
        .we_b(1'b0),.addr_b(a_addr_b),.data_b(12'd0),.q_b(a_q_b));
    poly_ram_dp u_input_b(.clk(clk),.we_a(load_b_we && state==S_IDLE),
        .addr_a(b_addr_a),.data_a(load_b_data),.q_a(b_q_a),
        .we_b(1'b0),.addr_b(b_addr_b),.data_b(12'd0),.q_b(b_q_b));
    poly_ram_dp u_result(.clk(clk),.we_a(write_valid && busy),
        .addr_a(c_addr_a),.data_a(c0_reg),.q_a(c_q_a),
        .we_b(write_valid && busy),.addr_b(c_addr_b),.data_b(c1_reg),.q_b(c_q_b));
    gammas_rom u_gammas(.pair_index(pair_index),.gamma(gamma));
    mod_mul_pipe u_mul_a0_b0(.clk(clk),.rst_n(rst_n),.in_valid(read_valid),
        .a(a_q_a),.b(b_q_a),.out_valid(products_valid[0]),.r(a0_b0_pipe));
    mod_mul_pipe u_mul_a1_b1(.clk(clk),.rst_n(rst_n),.in_valid(read_valid),
        .a(a_q_b),.b(b_q_b),.out_valid(products_valid[1]),.r(a1_b1_pipe));
    mod_mul_pipe u_mul_a0_b1(.clk(clk),.rst_n(rst_n),.in_valid(read_valid),
        .a(a_q_a),.b(b_q_b),.out_valid(products_valid[2]),.r(a0_b1_pipe));
    mod_mul_pipe u_mul_a1_b0(.clk(clk),.rst_n(rst_n),.in_valid(read_valid),
        .a(a_q_b),.b(b_q_a),.out_valid(products_valid[3]),.r(a1_b0_pipe));
    mod_mul_pipe u_mul_gamma(.clk(clk),.rst_n(rst_n),.in_valid(products_valid[1]),
        .a(a1_b1_pipe),.b(gamma_delay[MUL_STAGES-1]),
        .out_valid(gamma_valid),.r(gamma_product));
    mod_add u_add_c0(.a(a0b0_delay[MUL_STAGES-1]),.b(gamma_product),.r(base_c0));
    mod_add u_add_c1(.a(a0_b1_pipe),.b(a1_b0_pipe),.r(base_c1));
    always_ff @(posedge clk) begin
        if(!rst_n) begin
            state<=S_IDLE; pair_index<=0; written_count<=0;
            busy<=0; done<=0; cycle_count<=0; read_valid<=0;
            read_pair<=0; read_gamma<=0;
            write_valid<=0; write_pair<=0; c0_reg<=0; c1_reg<=0;
            for(p=0;p<MUL_STAGES;p=p+1) begin
                gamma_delay[p]<=0; a0b0_delay[p]<=0; c1_delay[p]<=0;
                pair_first[p]<=0; pair_second[p]<=0;
            end
        end else begin
            done<=0;
            if(busy) cycle_count<=cycle_count+32'd1;
            read_valid<=issue_valid; read_pair<=pair_index; read_gamma<=gamma;
            gamma_delay[0]<=read_gamma; pair_first[0]<=read_pair;
            a0b0_delay[0]<=products_valid[0] ? a0_b0_pipe : 12'd0;
            c1_delay[0]<=products_valid[0] ? base_c1 : 12'd0;
            pair_second[0]<=pair_first[MUL_STAGES-1];
            for(p=1;p<MUL_STAGES;p=p+1) begin
                gamma_delay[p]<=gamma_delay[p-1]; pair_first[p]<=pair_first[p-1];
                a0b0_delay[p]<=a0b0_delay[p-1]; c1_delay[p]<=c1_delay[p-1];
                pair_second[p]<=pair_second[p-1];
            end
            write_valid<=gamma_valid;
            write_pair<=pair_second[MUL_STAGES-1];
            c0_reg<=base_c0; c1_reg<=c1_delay[MUL_STAGES-1];
            case(state)
                S_IDLE: if(start) begin
                    busy<=1; cycle_count<=0; pair_index<=0;
                    written_count<=0; state<=S_ISSUE;
                end
                S_ISSUE: begin
                    if(pair_index==7'd127) state<=S_DRAIN;
                    else pair_index<=pair_index+7'd1;
                end
                S_DRAIN: begin end
                S_FINISH: begin busy<=0; done<=1; state<=S_IDLE; end
                default: begin busy<=0; state<=S_IDLE; end
            endcase
            if(write_valid && busy) begin
                written_count<=written_count+7'd1;
                if(written_count==7'd127) state<=S_FINISH;
            end
        end
    end
endmodule
