// =========================================================================
// tb_sdram -- h8_sdram against the protocol-checking model
//
// Run: make sdram
// =========================================================================

`timescale 1ns/1ps

module tb_sdram;

    integer errors = 0, checks = 0;

    task chk(input cond, input [8*64:1] name);
        begin
            checks = checks + 1;
            if (!cond) begin
                errors = errors + 1;
                $display("  FAIL: %0s   (t=%0t)", name, $time);
            end
        end
    endtask

    reg clk = 0;
    always #10 clk = ~clk;              // 50 MHz

    // DRAM_CLK is the inverted system clock -- see the note in h8fpga_top.
    wire dram_clk = ~clk;

    reg         rst_n = 0;
    reg  [15:0] addr  = 0;
    reg   [7:0] wdata = 0;
    reg         rd = 0, wr = 0;
    wire  [7:0] rdata;
    wire        busy, ready;

    wire [12:0] DRAM_ADDR;
    wire  [1:0] DRAM_BA, DRAM_DQM;
    wire        DRAM_CAS_N, DRAM_RAS_N, DRAM_WE_N, DRAM_CS_N, DRAM_CKE;
    wire [15:0] DRAM_DQ;

    // Shorter init so the test runs in reasonable time. The model's INIT_NS is
    // scaled to match, so the "no command before the init wait" check stays
    // meaningful.
    h8_sdram #(.T_INIT(260), .T_REFRESH(384)) u_dut (
        .clk(clk), .rst_n(rst_n),
        .addr(addr), .wdata(wdata), .rd(rd), .wr(wr),
        .rdata(rdata), .busy(busy), .ready(ready),
        .DRAM_ADDR(DRAM_ADDR), .DRAM_BA(DRAM_BA), .DRAM_DQM(DRAM_DQM),
        .DRAM_CAS_N(DRAM_CAS_N), .DRAM_RAS_N(DRAM_RAS_N),
        .DRAM_WE_N(DRAM_WE_N), .DRAM_CS_N(DRAM_CS_N), .DRAM_CKE(DRAM_CKE),
        .DRAM_DQ(DRAM_DQ)
    );

    sdram_model #(.INIT_NS(5000)) u_model (
        .dram_clk(dram_clk), .cke(DRAM_CKE), .cs_n(DRAM_CS_N),
        .ras_n(DRAM_RAS_N), .cas_n(DRAM_CAS_N), .we_n(DRAM_WE_N),
        .addr(DRAM_ADDR), .ba(DRAM_BA), .dqm(DRAM_DQM), .dq(DRAM_DQ)
    );

    // ---------------------------------------------------------------------
    // Bus tasks. rd/wr are level strobes held until busy clears, mirroring
    // how the CPU holds MEMR/MEMW for a whole M-cycle.
    // ---------------------------------------------------------------------
    task do_write(input [15:0] a, input [7:0] d);
        begin
            @(posedge clk);
            addr = a; wdata = d; wr = 1;
            @(posedge clk);
            while (busy) @(posedge clk);
            wr = 0;
            @(posedge clk);
        end
    endtask

    task do_read(input [15:0] a, output [7:0] d);
        begin
            @(posedge clk);
            addr = a; rd = 1;
            @(posedge clk);
            while (busy) @(posedge clk);
            d = rdata;
            rd = 0;
            @(posedge clk);
        end
    endtask

    reg [7:0] got;
    integer   n;

    initial begin
        $display("");
        $display("=== h8_sdram ===");
        rst_n = 0;
        #200;
        chk(ready === 1'b0, "not ready during reset");
        rst_n = 1;

        // Init must complete on its own.
        n = 0;
        while (!ready && n < 20000) begin @(posedge clk); n = n + 1; end
        chk(ready === 1'b1, "initialization completes and asserts ready");

        // ---- byte lanes within one 16-bit word ----
        do_write(16'h0000, 8'h11);
        do_write(16'h0001, 8'h22);
        do_read (16'h0000, got);
        chk(got === 8'h11, "low byte of word 0 reads back 0x11");
        do_read (16'h0001, got);
        chk(got === 8'h22, "high byte of word 0 reads back 0x22");

        // Writing one byte must not disturb its neighbour (DQM masking).
        do_write(16'h0000, 8'hAA);
        do_read (16'h0001, got);
        chk(got === 8'h22, "rewriting the low byte leaves the high byte alone");
        do_read (16'h0000, got);
        chk(got === 8'hAA, "low byte updated to 0xAA");

        // ---- same-row accesses (row hit path) ----
        do_write(16'h0100, 8'h55);
        do_write(16'h0102, 8'h56);
        do_read (16'h0100, got);
        chk(got === 8'h55, "row hit: 0x0100 reads 0x55");
        do_read (16'h0102, got);
        chk(got === 8'h56, "row hit: 0x0102 reads 0x56");

        // ---- cross a row boundary (1 KB per row -> row changes at 0x0400) ----
        do_write(16'h03FF, 8'h77);
        do_write(16'h0400, 8'h88);
        do_read (16'h03FF, got);
        chk(got === 8'h77, "row miss: 0x03FF still reads 0x77");
        do_read (16'h0400, got);
        chk(got === 8'h88, "row miss: 0x0400 reads 0x88");

        // ---- top of the 64K window ----
        do_write(16'hFFFF, 8'h99);
        do_read (16'hFFFF, got);
        chk(got === 8'h99, "top of 64K (0xFFFF) reads 0x99");
        do_read (16'h0000, got);
        chk(got === 8'hAA, "0x0000 unaffected by the 0xFFFF access");

        // ---- walk enough addresses to force many row changes ----
        for (n = 0; n < 40; n = n + 1)
            do_write(n * 16'h0400, n[7:0] ^ 8'h5A);
        for (n = 0; n < 40; n = n + 1) begin
            do_read(n * 16'h0400, got);
            if (got !== (n[7:0] ^ 8'h5A)) begin
                $display("  FAIL: row walk %0d: got %h expected %h",
                         n, got, n[7:0] ^ 8'h5A);
                errors = errors + 1;
            end
        end
        checks = checks + 1;
        $display("  (row walk over 40 rows complete)");

        // ---- idle long enough to require several refreshes ----
        //
        // The model's watchdog reports an error if the AUTO REFRESH interval
        // is ever exceeded, so "0 protocol errors" is the real refresh check.
        // This read only confirms the refresh machinery does not corrupt the
        // array or wedge the FSM -- the model does not simulate DRAM decay.
        //
        // Sentinel at 0x0003: deliberately an address the 40-row walk does not
        // touch (it writes only multiples of 0x0400, and n=0 lands on 0x0000).
        do_write(16'h0003, 8'hC3);
        #50000;
        do_read(16'h0003, got);
        chk(got === 8'hC3, "data intact across an idle period with refreshes");

        // And confirm the row walk really did land on 0x0000.
        do_read(16'h0000, got);
        chk(got === 8'h5A, "0x0000 holds the row-walk value (n=0 -> 0x5A)");

        // ---- busy behaviour ----
        @(posedge clk);
        addr = 16'h0800; rd = 1;
        @(posedge clk);
        chk(busy === 1'b1, "busy asserts while a transaction is outstanding");
        while (busy) @(posedge clk);
        rd = 0;
        @(posedge clk); @(posedge clk);
        chk(busy === 1'b0, "busy clears when idle");

        // ------------------------------------------------------------------
        $display("");
        if (errors == 0 && u_model.errors == 0)
            $display("PASS: all %0d checks passed, 0 protocol errors", checks);
        else
            $display("FAIL: %0d test failures, %0d protocol errors",
                     errors, u_model.errors);
        $display("");
        $finish;
    end

    initial begin
        #4000000;
        $display("FAIL: timeout");
        $finish;
    end

endmodule
