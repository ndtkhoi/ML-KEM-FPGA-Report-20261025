`timescale 1ns/1ps
// Baseline-specific white-box checks: uses block_start/global_input_index.
// Scratch RAM is invalidated, NOT physically scrubbed by this interface.
// Abort at EVERY sponge FSM state, both permutation phases, multi-block input
// and multi-block squeeze. RTL functional checks, not post-fit timing proof.
module tb_keccak_sponge_clear;
    logic clk=0; always #3.333 clk=~clk;
    logic rst_n=0,zeroize=0,start=0,input_we=0;
    logic [1:0] mode=0;
    logic [11:0] input_length=0;
    logic [10:0] output_length=0,input_address=0;
    logic [9:0] output_address=0;
    logic [7:0] input_data=0,output_data;
    wire busy,done;
    wire [31:0] cycles;
    wire [3:0] debug_state;
    logic [7:0] msg[0:2047],gold[0:1023];
    integer md,target,checks=0;
    integer reference_cycles;
    keccak_sponge dut(
        .clk(clk),.rst_n(rst_n),.zeroize(zeroize),.start(start),.mode(mode),
        .input_length(input_length),.output_length(output_length),
        .input_we(input_we),.input_address(input_address),.input_data(input_data),
        .output_address(output_address),.output_data(output_data),
        .busy(busy),.done(done),.cycle_count(cycles),.debug_state(debug_state));

    task automatic pulse_start;
        begin
            @(negedge clk);start=1;
            @(negedge clk);start=0;
        end
    endtask
    task automatic cleared;
        begin
            if(debug_state!==0 || busy!==0 || done!==0 || cycles!==0 ||
               dut.result_valid!==0 || output_data!==0 ||
               dut.sponge_state!==0 || dut.squeeze_lane!==0 ||
               dut.absorb_byte_q!==0 || dut.absorb_mask!==0 ||
               dut.perm_load_lane_data!==0 || dut.byte_index!==0 ||
               dut.output_index!==0 || dut.lane_index!==0 ||
               dut.input_length_reg!==0 || dut.block_start!==0 ||
               dut.output_length_reg!==0 || dut.squeezing!==0 ||
               dut.u_permutation.state!==0 || dut.u_permutation.round_mid!==0 ||
               dut.u_permutation.busy!==0 || dut.u_permutation.done!==0 ||
               dut.u_permutation.round_phase!==0 || dut.u_permutation.round_index!==0 ||
               dut.perm_read_lane_data!==0)
                $fatal(1,"clear incomplete mode=%0d target=%0d state=%0d",mode,target,debug_state);
        end
    endtask
    task automatic finish_and_compare;
        integer j;
        begin
            pulse_start();
            wait(done);@(negedge clk);
            if(reference_cycles<0) reference_cycles=cycles;
            else if(cycles!==reference_cycles)
                $fatal(1,"normal hash latency changed across abort/restart");
            for(j=0;j<output_length;j++)begin
                output_address=j;
                @(posedge clk);#1;
                if(output_data!==gold[j])
                    $fatal(1,"restart digest mismatch mode=%0d byte=%0d got=%h expected=%h",mode,j,output_data,gold[j]);
                @(negedge clk);
            end
        end
    endtask
    task automatic abort_and_restart(input integer selected_state,input integer phase_filter);
        integer j,write_index;
        reg [7:0] saved_output_byte;
        begin
            // State 0 is also tested with a completed result still in RAM.
            if(selected_state!=0)begin
                pulse_start();
                while(!(debug_state==selected_state &&
                    (phase_filter==0 ||
                    (phase_filter==1 && dut.perm_busy && !dut.u_permutation.round_phase) ||
                    (phase_filter==2 && dut.perm_busy && dut.u_permutation.round_phase) ||
                    (phase_filter==3 && dut.squeezing && dut.perm_busy) ||
                    (phase_filter==4 &&
                     dut.global_input_index>=dut.rate_bytes)))) @(negedge clk);
            end
            write_index=dut.output_index;
            saved_output_byte=dut.output_memory[write_index];
            zeroize=1;start=1;input_we=1;input_address=2047;input_data=8'ha5;
            #1;if(output_data!==0)$fatal(1,"result not masked during clear");
            // External masking/controller abort is immediate.  The wide
            // permutation datapath intentionally receives the registered
            // clear token one clock later, so inspect the complete internal
            // wipe only after that architectural boundary has advanced.
            @(posedge clk);#1;
            if(debug_state!==0 || busy!==0 || done!==0 || output_data!==0)
                $fatal(1,"controller clear incomplete mode=%0d target=%0d",mode,target);
            @(posedge clk);#1;cleared();
            if(dut.input_memory[2047]!==8'h3c)$fatal(1,"input write won over clear");
            if(dut.output_memory[write_index]!==saved_output_byte)
                $fatal(1,"output RAM write won over clear in state %0d",selected_state);
            // Alternate a two-cycle clear with a held clear, with simultaneous
            // start/load throughout: neither is allowed to win over zeroize.
            for(j=0;j<(selected_state%2)*3;j++)begin
                @(posedge clk);#1;cleared();
            end
            @(negedge clk);zeroize=0;start=0;input_we=0;
            repeat(8)begin @(posedge clk);#1;cleared();end
            // No extra reset and no input reload: rejected write must not have
            // changed the prepared input. Completed output must match oracle.
            finish_and_compare();checks=checks+1;
        end
    endtask
    initial begin
        repeat(4)@(negedge clk);rst_n=1;
        @(negedge clk);input_we=1;input_address=2047;input_data=8'h3c;
        @(negedge clk);input_we=0;
        for(md=0;md<4;md++)begin
            mode=md;reference_cycles=-1;
            case(md)
                0:begin
                    input_length=0;output_length=32;
                    $readmemh("03_vectors/full/sponge/sha3_256_empty_expected.hex",gold,0,31);
                end
                1:begin
                    input_length=3;output_length=64;
                    $readmemh("03_vectors/full/sponge/sha3_512_abc_input.hex",msg,0,2);
                    $readmemh("03_vectors/full/sponge/sha3_512_abc_expected.hex",gold,0,63);
                end
                2:begin
                    input_length=200;output_length=400;
                    $readmemh("03_vectors/full/sponge/shake128_multiblock_input.hex",msg,0,199);
                    $readmemh("03_vectors/full/sponge/shake128_multiblock_expected.hex",gold,0,399);
                end
                3:begin
                    input_length=1600;output_length=512;
                    $readmemh("03_vectors/full/sponge/shake256_long_input.hex",msg,0,1599);
                    $readmemh("03_vectors/full/sponge/shake256_long_expected.hex",gold,0,511);
                end
            endcase
            for(target=0;target<input_length;target++)begin
                @(negedge clk);input_we=1;input_address=target;input_data=msg[target];
            end
            @(negedge clk);input_we=0;
            finish_and_compare();
            for(target=0;target<15;target++)abort_and_restart(target,0);
            target=8;abort_and_restart(8,1);abort_and_restart(8,2);
            if(md>=2)begin
                abort_and_restart(8,3); // second permutation for output
                target=1;abort_and_restart(1,4); // second input block
            end
            $display("SPONGE_CLEAR_MODE: PASS mode=%0d cycles=%0d",md,reference_cycles);
        end
        if(checks!=72)$fatal(1,"incomplete clear coverage %0d",checks);
        $display("KECCAK_SPONGE_CLEAR: ALL TESTS PASS aborts=%0d four_modes all15states both_phases multiblock start_load_priority no_stale_result restart_oracle",checks);
        $finish;
    end
    initial begin #20000000;$fatal(1,"sponge clear watchdog mode=%0d target=%0d",mode,target);end
endmodule
