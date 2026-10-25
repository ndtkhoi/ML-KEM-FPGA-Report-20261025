// Compress/Decompress chinh xac, tach cac phep tinh de nham clock 160 MHz.
// start chi duoc nhan khi !busy. d/value duoc chot; done bao result hop le.
// Khong doi quy tac lam tron FIPS 203, khong dung divider to hop.
module compress_seq (
    input logic clk, rst_n, start, compress,
    input logic [3:0] d,
    input logic [11:0] value,
    output logic [11:0] result,
    output logic valid_d, busy, done
);
    typedef enum logic [3:0] {IDLE,SHIFT,BIAS,RECIP,COMBINE,QPROD,
        REMAINDER,CORRECT,EMIT,DMUL,DBIAS,DSHIFT} state_t;
    state_t state;
    logic [3:0] d_reg;
    logic [11:0] value_reg,mask;
    logic [24:0] numerator;
    logic [32:0] product_lo,product_hi;
    logic [45:0] reciprocal_product;
    logic [13:0] quotient;
    logic [26:0] q_product,residue;
    logic [24:0] decomp_value;
    wire [24:0] decomp_shifted=decomp_value>>d_reg;
    always_ff @(posedge clk) begin
        if(!rst_n) begin
            state<=IDLE;result<=0;valid_d<=0;busy<=0;done<=0;
            d_reg<=0;value_reg<=0;mask<=0;numerator<=0;
            product_lo<=0;product_hi<=0;reciprocal_product<=0;
            quotient<=0;q_product<=0;residue<=0;decomp_value<=0;
        end else begin
            done<=0;
            case(state)
                IDLE:if(start)begin
                    d_reg<=d;value_reg<=value;busy<=1;
                    valid_d<=(d==1||d==4||d==5||d==10||d==11||d==12);
                    mask<=(12'd1<<d)-12'd1;
                    state<=compress?SHIFT:DMUL;
                end
                SHIFT:begin numerator<={13'd0,value_reg}<<d_reg;state<=BIAS;end
                BIAS:begin numerator<=numerator+25'd1664;state<=RECIP;end
                RECIP:begin
                    // Hai tich 12x21 bit; numerator < 2^24 voi value <= 4095.
                    product_lo<=numerator[11:0]*21'd1290167;
                    product_hi<=numerator[23:12]*21'd1290167;
                    state<=COMBINE;
                end
                COMBINE:begin
                    reciprocal_product<={13'd0,product_lo}+{1'b0,product_hi,12'd0};
                    state<=QPROD;
                end
                QPROD:begin
                    quotient<=reciprocal_product[45:32];
                    q_product<=reciprocal_product[45:32]*13'd3329;
                    state<=REMAINDER;
                end
                REMAINDER:begin residue<={2'b0,numerator}-q_product;state<=CORRECT;end
                CORRECT:begin quotient<=quotient+((residue>=27'd3329)?14'd1:14'd0);state<=EMIT;end
                EMIT:begin result<=valid_d?(quotient[11:0]&mask):12'd0;busy<=0;done<=1;state<=IDLE;end
                DMUL:begin decomp_value<=value_reg*13'd3329;state<=DBIAS;end
                DBIAS:begin decomp_value<=decomp_value+((25'd1<<d_reg)>>1);state<=DSHIFT;end
                DSHIFT:begin result<=valid_d?decomp_shifted[11:0]:12'd0;busy<=0;done<=1;state<=IDLE;end
                default:begin state<=IDLE;busy<=0;end
            endcase
        end
    end
endmodule
