// =========================================================================
// Simulation-only stubs.
//
// NOT FOR SYNTHESIS. Quartus must never see this file -- it deliberately
// shadows the real T80pa (VHDL) and the two altsyncram megafunction wrappers
// so that Icarus can elaborate h8fpga_top without a VHDL simulator or any
// Altera libraries.
//
// The T80pa stub is NOT a Z80. It is a scripted bus-cycle generator that
// produces representative H8 transactions so the top-level wiring, memory
// map, and transceiver turnaround can be exercised. It says nothing about
// whether the real core behaves correctly.
// =========================================================================

`timescale 1ns/1ps

// -------------------------------------------------------------------------
// H8FPGAROM -- behavioural stand-in for the altsyncram ROM wrapper.
// Matches the real wrapper's ports: address[11:0], clock, rden, q[7:0].
// outdata_reg_a = "CLOCK0" in the real thing, i.e. TWO clocks of latency.
// -------------------------------------------------------------------------
module H8FPGAROM (
    input      [11:0] address,
    input             clock,
    input             rden,
    output      [7:0] q
);
    reg [7:0] mem [0:4095];
    reg [7:0] q_addr_stage, q_out_stage;
    integer i;

    initial begin
        for (i = 0; i < 4096; i = i + 1) mem[i] = 8'h00;
        // Recognizable pattern so read-path tests can tell ROM from RAM.
        mem[0] = 8'hA0; mem[1] = 8'hA1; mem[2] = 8'hA2; mem[3] = 8'hA3;
    end

    always @(posedge clock) begin
        if (rden) q_addr_stage <= mem[address];
        q_out_stage <= q_addr_stage;
    end

    assign q = q_out_stage;
endmodule


// -------------------------------------------------------------------------
// H8FPGARAM -- behavioural stand-in for the altsyncram RAM wrapper.
// Ports: address[14:0], clock, data[7:0], rden, wren, q[7:0].
// read_during_write_mode_port_a = "NEW_DATA_NO_NBE_READ" in the real thing.
// -------------------------------------------------------------------------
module H8FPGARAM (
    input      [14:0] address,
    input             clock,
    input       [7:0] data,
    input             rden,
    input             wren,
    output      [7:0] q
);
    reg [7:0] mem [0:32767];
    reg [7:0] q_addr_stage, q_out_stage;
    integer i;

    initial begin
        for (i = 0; i < 32768; i = i + 1) mem[i] = 8'h00;
        // Deliberately left at zero. The ROM-shadow tests write the values they
        // then check, so this backend and the SDRAM one behave identically and
        // neither test can pass off a preloaded pattern.
    end

    always @(posedge clock) begin
        if (wren) begin
            mem[address] <= data;
            q_addr_stage <= data;          // new-data read-during-write
        end else if (rden) begin
            q_addr_stage <= mem[address];
        end
        q_out_stage <= q_addr_stage;
    end

    assign q = q_out_stage;
endmodule


// -------------------------------------------------------------------------
// T80pa stub -- scripted bus cycles, advancing on CEN_p.
//
// Each transaction takes 3 "T-states" of the emulated clock, which is close
// enough to a Z80 M-cycle for wiring and turnaround checks.
// -------------------------------------------------------------------------
module T80pa (
    input         RESET_n,
    input         CLK,
    input         CEN_p,
    input         CEN_n,
    input         WAIT_n,
    input         INT_n,
    input         NMI_n,
    input         BUSRQ_n,
    output reg    M1_n,
    output reg    MREQ_n,
    output reg    IORQ_n,
    output reg    RD_n,
    output reg    WR_n,
    output reg    RFSH_n,
    output reg    HALT_n,
    output reg    BUSAK_n,
    input         OUT0,
    output reg [15:0] A,
    input      [7:0]  DI,
    output reg [7:0]  DO,
    input         R800_mode,
    input         DIRSet,
    input  [211:0] DIR
);
    // Transaction script: {type, addr[15:0], data[7:0]}
    // type 0 = opcode fetch, 1 = mem read, 2 = mem write,
    //      3 = io read,      4 = io write
    localparam N = 9;
    reg [2:0]  ty   [0:N-1];
    reg [15:0] ad   [0:N-1];
    reg [7:0]  wd   [0:N-1];

    // Captured read data, so the testbench can check what the CPU saw.
    reg [7:0] last_di;
    integer   idx, tstate;

    // The script runs ONCE and then parks idle. Looping made the test
    // non-deterministic: on a second pass the ORG-0 write from transaction 4
    // has already disabled the ROM and RAM retains what transaction 2 wrote,
    // so early slots get overwritten with different-but-correct values.
    reg done;

    // Read data recorded by the stub itself, at the T3 sampling point. Done
    // here rather than in the testbench so there is no read-during-update race
    // on the DUT's internal state.
    reg [7:0] seen [0:N-1];

    initial begin
        for (idx = 0; idx < N; idx = idx + 1) seen[idx] = 8'hXX;
        ty[0]=0; ad[0]=16'h0000; wd[0]=8'h00;  // opcode fetch from ROM
        ty[1]=2; ad[1]=16'h0000; wd[1]=8'h5A;  // write RAM *under* the ROM
        ty[2]=0; ad[2]=16'h0000; wd[2]=8'h00;  // fetch again: ROM must still win
        ty[3]=2; ad[3]=16'h2000; wd[3]=8'h77;  // mem write to plain RAM
        ty[4]=1; ad[4]=16'h2000; wd[4]=8'h00;  // read it back
        ty[5]=4; ad[5]=16'h00F2; wd[5]=8'h00;  // io write port 0362 -> ROM off
        ty[6]=1; ad[6]=16'h0000; wd[6]=8'h00;  // read 0x0000 -> RAM shows through
        ty[7]=4; ad[7]=16'h00E8; wd[7]=8'h3C;  // io write to a bus port
        ty[8]=3; ad[8]=16'h00E8; wd[8]=8'h00;  // io read  from a bus port
    end

    always @(posedge CLK or negedge RESET_n) begin
        if (!RESET_n) begin
            M1_n<=1; MREQ_n<=1; IORQ_n<=1; RD_n<=1; WR_n<=1;
            RFSH_n<=1; HALT_n<=1; BUSAK_n<=1;
            A<=16'h0000; DO<=8'h00; last_di<=8'h00;
            idx<=0; tstate<=0; done<=0;
        end else if (CEN_p && !done) begin
            case (tstate)
                0: begin   // T1: address out, strobes asserted
                    A <= ad[idx];
                    DO <= wd[idx];
                    M1_n   <= (ty[idx] != 0);
                    MREQ_n <= !(ty[idx] <= 2);
                    IORQ_n <= !(ty[idx] >= 3);
                    RD_n   <= !(ty[idx]==0 || ty[idx]==1 || ty[idx]==3);
                    WR_n   <= !(ty[idx]==2 || ty[idx]==4);
                    tstate <= 1;
                end
                1: tstate <= 2;   // T2: data settling
                2: begin          // T3: sample, then release
                    last_di   <= DI;
                    seen[idx] <= DI;
                    M1_n<=1; MREQ_n<=1; IORQ_n<=1; RD_n<=1; WR_n<=1;
                    tstate <= 0;
                    if (idx == N-1) done <= 1'b1;   // park, do not wrap
                    else            idx  <= idx + 1;
                end
            endcase
        end
    end
endmodule
