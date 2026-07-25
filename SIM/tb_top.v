// =========================================================================
// tb_top -- top-level integration test for h8fpga_top
//
// Uses the scripted T80pa stub in SIM/stubs.v, so this proves WIRING, not
// Z80 correctness: pin mapping, bus polarity, memory-map routing, ORG-0
// behaviour and transceiver turnaround.
//
// Run: iverilog -g2005 -o tb_top.vvp SIM/tb_top.v SIM/stubs.v RTL/*.v
//      vvp tb_top.vvp
// =========================================================================

`timescale 1ns/1ps

module tb_top;

    // Which RAM backend to exercise. Override from the command line:
    //   iverilog -Ptb_top.USE_SDRAM_TB=0 ...
    // so both the SDRAM path and the M9K fallback get tested.
    parameter USE_SDRAM_TB = 1;

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
    always #10 clk = ~clk;

    // ---------------------------------------------------------------------
    // GPIO_1 drive from the testbench side.
    // Everything the FPGA reads is an input here; the data byte is shared.
    // ---------------------------------------------------------------------
    reg        resin_n   = 1'b0;
    reg  [2:0] dip4      = 3'd0;      // speed select, code 0 = 2.083 MHz
    reg  [7:0] dip8      = 8'h3C;     // ORG-0 status byte
    reg  [7:0] bus_data_n = 8'hFF;    // inverted backplane data
    reg        bus_drives = 1'b0;     // TB sources the data byte
    reg  [7:1] int_n     = 7'h7F;

    wire [33:0] GPIO_1;
    wire [27:0] GPIO_0;
    wire  [8:0] GPIO_2;
    wire  [7:0] LED;

    // Interrupts and reset
    assign GPIO_1[0]  = int_n[3];
    assign GPIO_1[1]  = int_n[4];
    assign GPIO_1[2]  = int_n[5];
    assign GPIO_1[3]  = int_n[6];
    assign GPIO_1[4]  = int_n[7];
    assign GPIO_1[5]  = 1'b1;
    assign GPIO_1[6]  = int_n[1];
    assign GPIO_1[7]  = int_n[2];
    assign GPIO_1[8]  = resin_n;
    assign GPIO_1[11:9] = 3'b111;

    // Shared data byte: only one side drives at a time.
    assign GPIO_1[19:12] = bus_drives ? bus_data_n : 8'bz;

    assign GPIO_1[20]    = 1'b1;      // DIP4-1, now an input (was shorted to GND)
    assign GPIO_1[21]    = dip4[2];
    assign GPIO_1[22]    = dip4[1];
    assign GPIO_1[23]    = dip4[0];
    assign GPIO_1[25:24] = 2'b11;
    assign GPIO_1[33:26] = dip8;

    wire [12:0] DRAM_ADDR;
    wire  [1:0] DRAM_BA, DRAM_DQM;
    wire        DRAM_CAS_N, DRAM_RAS_N, DRAM_WE_N, DRAM_CS_N, DRAM_CKE, DRAM_CLK;
    wire [15:0] DRAM_DQ;

    h8fpga_top #(
        .RESET_STRETCH_BITS (4),
        .DEBOUNCE_BITS      (4),
        .USE_SDRAM          (USE_SDRAM_TB)
    ) u_dut (
        .CLOCK_50   (clk),
        .GPIO_0     (GPIO_0),
        .GPIO_1     (GPIO_1),
        .GPIO_2     (GPIO_2),
        .LED        (LED),
        .DRAM_ADDR  (DRAM_ADDR),
        .DRAM_BA    (DRAM_BA),
        .DRAM_DQM   (DRAM_DQM),
        .DRAM_CAS_N (DRAM_CAS_N),
        .DRAM_RAS_N (DRAM_RAS_N),
        .DRAM_WE_N  (DRAM_WE_N),
        .DRAM_CS_N  (DRAM_CS_N),
        .DRAM_CKE   (DRAM_CKE),
        .DRAM_CLK   (DRAM_CLK),
        .DRAM_DQ    (DRAM_DQ)
    );

    // The model is always present. With USE_SDRAM=0 the top deselects the
    // part (CS_N high, CKE low), so it should see no commands and report no
    // errors -- which is itself worth checking.
    sdram_model u_model (
        .dram_clk (DRAM_CLK), .cke(DRAM_CKE), .cs_n(DRAM_CS_N),
        .ras_n    (DRAM_RAS_N), .cas_n(DRAM_CAS_N), .we_n(DRAM_WE_N),
        .addr     (DRAM_ADDR), .ba(DRAM_BA), .dqm(DRAM_DQM), .dq(DRAM_DQ)
    );

    // Convenient aliases for the recovered pin map
    wire [15:0] bus_addr_n = GPIO_0[15:0];
    wire        bus_memr   = GPIO_0[17];
    wire        bus_ior    = GPIO_0[18];
    wire        bus_memw   = GPIO_0[21];
    wire        bus_clk_n  = GPIO_0[22];
    wire        bus_iow    = GPIO_0[23];
    wire        bus_dir    = GPIO_0[26];

    // =====================================================================
    // CONTINUOUS INVARIANT -- the 2.5 fix, checked over the whole run.
    //
    // The transceiver must never point at the backplane unless the FPGA is
    // actually driving the data pins. In the original design GPIO_0[26] sat
    // high during every memory and idle cycle while the FPGA's pins floated.
    // =====================================================================
    integer dir_violations = 0;
    always @(posedge clk)
        if (u_dut.rst_n && bus_dir === 1'b1 && u_dut.fpga_oe === 1'b0)
            dir_violations = dir_violations + 1;

    // The FPGA must never drive the data byte while the testbench is.
    integer contention = 0;
    always @(posedge clk)
        if (bus_drives && u_dut.fpga_oe === 1'b1)
            contention = contention + 1;

    // Read data is recorded inside the stub at its T3 sampling point.
    `define SEEN(i) u_dut.u_cpu.seen[i]

    // =====================================================================
    // phi period measurement on the bus clock pin
    // =====================================================================
    integer phi_edges = 0;
    reg     phi_d = 0;
    always @(posedge clk) begin
        if (bus_clk_n !== phi_d) phi_edges = phi_edges + 1;
        phi_d <= bus_clk_n;
    end

    // =====================================================================
    initial begin
        $display("");
        $display("=== reset and idle state ===");
        resin_n = 0;
        #400;
        chk(u_dut.rst_n === 1'b0, "held in reset while -RESIN low");
        chk(bus_dir === 1'b0, "DIR inward during reset");
        chk(GPIO_1[19:12] === 8'bz, "data byte released during reset");

        resin_n = 1;
        #1000;
        chk(u_dut.rst_n === 1'b1, "reset released");
        chk(GPIO_0[20] === 1'b1, "-NC24 tied high");
        chk(GPIO_0[27] === 1'b0, "GPIO_0[27] tied low");

        // ------------------------------------------------------------------
        $display("=== bus clock ===");
        #2000;
        phi_edges = 0;
        #4800;                       // 10 phi periods at 2.083 MHz
        chk(phi_edges == 20, "bus clock runs at 2.083 MHz");

        // ------------------------------------------------------------------
        $display("=== transactions ===");
        // The stub runs its 9-transaction script once, then parks. With SDRAM
        // this waits out the ~104 us initialization first, since the CPU is
        // held in reset until sdram_ready.
        wait (u_dut.u_cpu.done === 1'b1);
        #500;
        $display("  seen = %h %h %h %h %h %h %h %h %h",
                 `SEEN(0), `SEEN(1), `SEEN(2), `SEEN(3), `SEEN(4),
                 `SEEN(5), `SEEN(6), `SEEN(7), `SEEN(8));

        // slot 0: opcode fetch at 0x0000 -> ROM pattern 0xA0
        chk(`SEEN(0) === 8'hA0, "fetch at 0x0000 reads ROM (0xA0)");

        // slot 2: fetch 0x0000 again AFTER writing 0x5A to the RAM underneath.
        // ROM is still enabled, so ROM must win -- this proves the shadow works
        // in the normal direction, not just when disabled.
        chk(`SEEN(2) === 8'hA0, "ROM still shadows RAM at 0x0000 while enabled");

        // slot 4: read back 0x2000 after writing 0x77
        chk(`SEEN(4) === 8'h77, "RAM write then read back returns 0x77");

        // ---- ORG-0 ROM disable, end to end ----
        // Slot 5 writes 0x00 to port 0362, so rom_dis = ~DO[5] = 1.
        chk(u_dut.rom_dis === 1'b1, "port 0362 write disabled the ROM");
        chk(LED[1] === 1'b1, "rom_dis reflected on LED[1]");

        // slot 6: read 0x0000 with ROM disabled -> the 0x5A written in slot 1,
        // NOT the stale frozen ROM byte the original design returned.
        chk(`SEEN(6) === 8'h5A, "ROM disabled: 0x0000 reads RAM (0x5A) not ROM");

        // slot 8: I/O read from a bus port -> backplane data
        chk(`SEEN(8) === ~bus_data_n, "bus I/O read returns backplane data");

        // ------------------------------------------------------------------
        $display("=== invariants ===");
        chk(dir_violations == 0, "DIR never outward while FPGA released (2.5)");
        chk(contention == 0, "FPGA never drives against the testbench");

        $display("");
        if (errors == 0 && u_model.errors == 0) $display("PASS: all %0d checks passed, %0d protocol errors", checks, u_model.errors);
        else             $display("FAIL: %0d of %0d checks failed, %0d protocol errors", errors, checks, u_model.errors);
        $display("  dir_violations=%0d  contention=%0d", dir_violations, contention);
        $display("");
        $finish;
    end

    // ---------------------------------------------------------------------
    // Backplane responder: source the data byte during a bus I/O read.
    // ---------------------------------------------------------------------
    always @(posedge clk) begin
        if (u_dut.io_bus_rd && !u_dut.fpga_oe) begin
            bus_data_n <= ~8'h99;      // inverted, like the real bus
            bus_drives <= 1'b1;
        end else if (!u_dut.io_bus_rd) begin
            bus_drives <= 1'b0;
        end
    end

endmodule
