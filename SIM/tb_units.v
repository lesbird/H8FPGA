// =========================================================================
// tb_units -- unit tests for the stability-rework modules
//
// Run:  iverilog -g2005 -o tb_units.vvp SIM/tb_units.v RTL/*.v && vvp tb_units.vvp
// =========================================================================

`timescale 1ns/1ps

module tb_units;

    integer errors = 0;
    integer checks = 0;

    task chk(input cond, input [8*60:1] name);
        begin
            checks = checks + 1;
            if (!cond) begin
                errors = errors + 1;
                $display("  FAIL: %0s   (t=%0t)", name, $time);
            end
        end
    endtask

    // 50 MHz
    reg clk = 0;
    always #10 clk = ~clk;

    // =====================================================================
    // h8_reset
    // =====================================================================
    reg  resin_n = 1'b0;
    wire rst_n_dut;

    h8_reset #(.STRETCH_BITS(4)) u_reset (   // 16 clocks, for sim speed
        .clk(clk), .resin_n(resin_n), .ready(1'b1), .rst_n_out(rst_n_dut));

    // =====================================================================
    // h8_clkgen
    // =====================================================================
    reg        cg_rst_n = 1'b0;
    reg  [2:0] speed_sel = 3'd0;
    reg        stall = 1'b0;
    wire       cen_p, cen_n, phi, stall_seen;

    h8_clkgen u_clkgen (
        .clk(clk), .rst_n(cg_rst_n), .speed_sel(speed_sel), .stall(stall),
        .cen_p(cen_p), .cen_n(cen_n), .phi(phi), .stall_seen(stall_seen));

    integer cen_p_count = 0, cen_n_count = 0;
    integer phi_edges = 0;
    reg     phi_d = 0;
    always @(posedge clk) begin
        if (cen_p) cen_p_count = cen_p_count + 1;
        if (cen_n) cen_n_count = cen_n_count + 1;
        if (phi !== phi_d) phi_edges = phi_edges + 1;
        phi_d <= phi;
    end

    // cen_p and cen_n must never coincide
    always @(posedge clk)
        if (cen_p && cen_n) begin
            $display("  FAIL: cen_p and cen_n asserted together (t=%0t)", $time);
            errors = errors + 1;
        end

    // =====================================================================
    // h8_intctl
    // =====================================================================
    reg  [7:1] int_n_async = 7'h7F;
    reg        intack = 1'b0;
    wire       int_n_o, int_pending_o;
    wire [7:0] vector_o;

    h8_intctl u_intctl (
        .clk(clk), .rst_n(cg_rst_n), .int_n_async(int_n_async),
        .intack(intack), .int_n(int_n_o), .vector(vector_o),
        .int_pending(int_pending_o));

    // =====================================================================
    // h8_busif
    // =====================================================================
    reg  drive_req = 1'b0;
    wire dir_out, fpga_oe, d245_oe_n;

    h8_busif #(.DEAD_CLKS(2)) u_busif (
        .clk(clk), .rst_n(cg_rst_n), .drive_req(drive_req),
        .d245_dir_out(dir_out), .fpga_oe(fpga_oe), .d245_oe_n(d245_oe_n));

    // THE 2.5 INVARIANT: the '245 must never point at the backplane while the
    // FPGA has released its pins, or it amplifies a floating input onto the bus.
    always @(posedge clk)
        if (dir_out && !fpga_oe) begin
            $display("  FAIL: DIR outward while FPGA released (t=%0t)", $time);
            errors = errors + 1;
        end

    // =====================================================================
    // h8_memmap
    // =====================================================================
    reg [15:0] a = 16'h0000;
    reg memr=0, memw=0, ior=0, iow=0, mm_intack=0;
    reg rom_dis=0, org0_sel=0, org0_rd=0;
    reg [7:0] rom_q=8'hA0, ram_q=8'h5A, org0_status=8'h3C,
              bus_d=8'h99, int_vector=8'hCF;
    wire rom_rd, ram_rd, ram_wr, io_bus_rd, io_bus_wr;
    wire [7:0] cpu_di;

    h8_memmap #(.RAM_FULL_64K(0)) u_memmap (
        .a(a), .memr(memr), .memw(memw), .ior(ior), .iow(iow),
        .intack(mm_intack), .rom_dis(rom_dis), .org0_sel(org0_sel),
        .org0_rd(org0_rd), .rom_q(rom_q), .ram_q(ram_q),
        .org0_status(org0_status), .bus_d(bus_d), .int_vector(int_vector),
        .rom_rd(rom_rd), .ram_rd(ram_rd), .ram_wr(ram_wr),
        .io_bus_rd(io_bus_rd), .io_bus_wr(io_bus_wr), .cpu_di(cpu_di));

    task mm_clear;
        begin memr=0; memw=0; ior=0; iow=0; mm_intack=0; org0_sel=0;
              org0_rd=0; #1; end
    endtask

    // =====================================================================
    // Test sequence
    // =====================================================================
    integer t0;

    initial begin
        $display("");
        $display("=== h8_reset ===");
        resin_n = 0; #200;
        chk(rst_n_dut === 1'b0, "reset asserted while resin_n low");
        resin_n = 1;
        #100;   // 5 clocks -- less than the 16-clock stretch
        chk(rst_n_dut === 1'b0, "reset still held during stretch window");
        #400;   // well past 16 clocks
        chk(rst_n_dut === 1'b1, "reset released after stretch");

        // Bounce: a glitch low must restart the whole window.
        resin_n = 0; #5; resin_n = 1;
        #60;
        chk(rst_n_dut === 1'b0, "bounce restarts the stretch (debounce)");
        #400;
        chk(rst_n_dut === 1'b1, "reset released again after bounce settles");

        // ------------------------------------------------------------------
        $display("=== h8_clkgen ===");
        cg_rst_n = 0; #100; cg_rst_n = 1; #40;

        // speed_sel 0 -> DIV 12 -> phi period = 24 clocks = 480 ns
        speed_sel = 3'd0; #100;
        phi_edges = 0; t0 = $time;
        #4800;   // 10 phi periods
        chk(phi_edges == 20, "speed 0: phi toggles 20x in 4800 ns (2.083 MHz)");

        cen_p_count = 0; cen_n_count = 0;
        #4800;
        chk(cen_p_count == 10, "speed 0: 10 cen_p pulses per 10 phi periods");
        chk(cen_n_count == 10, "speed 0: 10 cen_n pulses per 10 phi periods");

        // speed_sel 2 -> DIV 3 -> phi period = 6 clocks = 120 ns
        speed_sel = 3'd2; #600;
        phi_edges = 0;
        #1200;
        chk(phi_edges == 20, "speed 2: phi toggles 20x in 1200 ns (8.33 MHz)");

        // speed_sel 3 -> DIV 1 -> phi period = 2 clocks = 40 ns (25 MHz).
        // This is the ceiling for a two-phase CEN scheme; see h8_clkgen.
        speed_sel = 3'd3; #600;
        phi_edges = 0;
        #400;
        chk(phi_edges == 20, "speed 3: phi toggles 20x in 400 ns (25 MHz)");

        // THE 1.1 FIX: codes 5/6/7 were unconnected mux inputs and stopped the
        // CPU dead. They must now fall back to the safe 2.083 MHz divisor.
        speed_sel = 3'd5; #1000;
        phi_edges = 0;
        #4800;
        chk(phi_edges == 20, "speed 5 (was dangling D5) defaults to 2.083 MHz");

        speed_sel = 3'd7; #1000;
        phi_edges = 0;
        #4800;
        chk(phi_edges == 20, "speed 7 (was dangling D7) defaults to 2.083 MHz");

        // Stall must FREEZE, not drop pulses.
        speed_sel = 3'd0; #1000;
        chk(stall_seen === 1'b0, "stall_seen clear before any stall");
        stall = 1;
        cen_p_count = 0; cen_n_count = 0; phi_edges = 0;
        #4800;
        chk(cen_p_count == 0 && cen_n_count == 0, "stall suppresses all enables");
        chk(phi_edges == 0, "stall freezes phi");
        chk(stall_seen === 1'b1, "stall_seen latches");
        stall = 0;
        #1000;
        chk(cen_p_count > 0, "enables resume after stall clears");

        // ------------------------------------------------------------------
        $display("=== h8_intctl ===");
        int_n_async = 7'h7F; #100;
        chk(int_n_o === 1'b1, "int_n high with no interrupts");
        chk(int_pending_o === 1'b0, "int_pending low with no interrupts");

        // Level 1 -> RST 1 -> 0xCF
        int_n_async = 7'b111_1110; #100;
        chk(int_n_o === 1'b0, "int_n low on level 1");
        intack = 1; #40;
        chk(vector_o === 8'hCF, "level 1 vector = RST 1 = 0xCF");
        intack = 0; #40;

        // Level 7 -> RST 7 -> 0xFF
        int_n_async = 7'b011_1111; #100;
        intack = 1; #40;
        chk(vector_o === 8'hFF, "level 7 vector = RST 7 = 0xFF");
        intack = 0; #40;

        // Priority: 7 must win over 1 (matches the 74148)
        int_n_async = 7'b011_1110; #100;
        intack = 1; #40;
        chk(vector_o === 8'hFF, "level 7 outranks level 1");

        // Vector must NOT change mid-acknowledge, even if a new level appears.
        int_n_async = 7'b111_1110; #100;
        chk(vector_o === 8'hFF, "vector latched for the whole ack cycle");
        intack = 0; #40;
        intack = 1; #60;
        chk(vector_o === 8'hCF, "vector updates on the next ack cycle");
        intack = 0; #40;

        // ------------------------------------------------------------------
        $display("=== h8_busif ===");
        #100;
        chk(dir_out === 1'b0, "DIR rests INWARD at idle (the 2.5 fix)");
        chk(fpga_oe === 1'b0, "FPGA released at idle");

        drive_req = 1; #20;
        chk(fpga_oe === 1'b1, "FPGA asserts before DIR flips");
        chk(dir_out === 1'b0, "DIR still inward during the guard band");
        #60;
        chk(dir_out === 1'b1, "DIR outward after the guard band");
        chk(fpga_oe === 1'b1, "FPGA still driving while DIR outward");

        drive_req = 0; #20;
        chk(dir_out === 1'b0, "DIR returns inward first");
        chk(fpga_oe === 1'b1, "FPGA held through the return guard band");
        #80;
        chk(fpga_oe === 1'b0, "FPGA released last");
        chk(dir_out === 1'b0, "DIR back at rest");

        // ------------------------------------------------------------------
        $display("=== h8_memmap ===");
        mm_clear;

        // Unclaimed read returns FF, like a real backplane with pull-ups.
        a = 16'hC000; mm_clear;
        chk(cpu_di === 8'hFF, "idle/unclaimed read returns 0xFF");

        // Above 0x8000 nothing answered in the original design either --
        // but now it is a DEFINED 0xFF rather than a tri-state collapse.
        a = 16'h9000; memr = 1; #1;
        chk(ram_rd === 1'b0, "no RAM above 0x8000 with RAM_FULL_64K=0");
        chk(cpu_di === 8'hFF, "read above 0x8000 returns 0xFF");

        // ROM window
        a = 16'h0000; mm_clear; memr = 1; #1;
        chk(rom_rd === 1'b1, "ROM selected at 0x0000 on memr");
        chk(ram_rd === 1'b0, "RAM masked while ROM answers");
        chk(cpu_di === 8'hA0, "read at 0x0000 returns ROM data");

        a = 16'h0FFF; #1;
        chk(rom_rd === 1'b1, "ROM window extends to 0x0FFF");
        a = 16'h1000; #1;
        chk(rom_rd === 1'b0, "ROM window ends at 0x1000");
        chk(ram_rd === 1'b1, "RAM answers at 0x1000");
        chk(cpu_di === 8'h5A, "read at 0x1000 returns RAM data");

        // ---- THE ORG-0 ROM-DISABLE FIX ----
        // In the original, rom_dis only dropped altsyncram's rden, which
        // merely froze its output register while 74541/inst13 kept driving
        // Z80IN and MEMOK kept RAM locked out. Reads returned stale ROM.
        a = 16'h0000; mm_clear; memr = 1; rom_dis = 1; #1;
        chk(rom_rd === 1'b0, "rom_dis removes ROM from the read path");
        chk(ram_rd === 1'b1, "RAM now answers underneath the ROM window");
        chk(cpu_di === 8'h5A, "rom_dis: 0x0000 reads RAM, not stale ROM");
        rom_dis = 0;

        // RAM writes were always allowed under the ROM window.
        a = 16'h0000; mm_clear; memw = 1; #1;
        chk(ram_wr === 1'b1, "RAM writes pass through the ROM window");

        a = 16'h8000; mm_clear; memw = 1; #1;
        chk(ram_wr === 1'b0, "no RAM write above 0x7FFF");

        // I/O routing
        a = 16'h00F2; mm_clear; ior = 1; org0_sel = 1; org0_rd = 1; #1;
        chk(io_bus_rd === 1'b0, "port 0362 read is NOT sent to the bus");
        chk(cpu_di === 8'h3C, "port 0362 read returns the ORG-0 status byte");

        a = 16'h00E8; mm_clear; ior = 1; #1;
        chk(io_bus_rd === 1'b1, "other I/O reads go to the bus");
        chk(cpu_di === 8'h99, "bus I/O read returns backplane data");

        a = 16'h00F2; mm_clear; iow = 1; org0_sel = 1; #1;
        chk(io_bus_wr === 1'b0, "port 0362 write is NOT sent to the bus");
        a = 16'h00E8; mm_clear; iow = 1; #1;
        chk(io_bus_wr === 1'b1, "other I/O writes go to the bus");

        // Interrupt acknowledge outranks everything.
        a = 16'h0000; mm_clear; mm_intack = 1; memr = 1; #1;
        chk(cpu_di === 8'hCF, "intack takes priority over ROM");

        // ------------------------------------------------------------------
        $display("");
        if (errors == 0)
            $display("PASS: all %0d checks passed", checks);
        else
            $display("FAIL: %0d of %0d checks failed", errors, checks);
        $display("");
        $finish;
    end

endmodule
