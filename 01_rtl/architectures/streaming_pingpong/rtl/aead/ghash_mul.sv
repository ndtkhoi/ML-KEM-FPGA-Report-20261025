// Nhan GF(2^128) theo SP 800-38D Algorithm 1, 128 clock, bit MSB truoc.
module ghash_mul (
    input logic clk, rst_n, zeroize, start,
    input logic [127:0] x,h,
    output logic [127:0] result,
    output logic busy,done
);
    logic [127:0] a,v,z;
    logic [6:0] count;
    wire [127:0] next_z=z^(a[127]?v:128'd0);
    always_ff @(posedge clk) begin
        if(!rst_n) begin a<=0;v<=0;z<=0;count<=0;result<=0;busy<=0;done<=0;end
        else if(zeroize) begin a<=0;v<=0;z<=0;count<=0;result<=0;busy<=0;done<=0;end
        else begin
            done<=0;
            if(!busy && start) begin a<=x;v<=h;z<=0;count<=0;busy<=1;result<=0;end
            else if(busy) begin
                z<=next_z; a<={a[126:0],1'b0};
                v<=(v>>1)^(v[0]?128'he1000000000000000000000000000000:128'd0);
                if(count==127) begin result<=next_z;busy<=0;done<=1;end
                else count<=count+1'b1;
            end
        end
    end
endmodule
