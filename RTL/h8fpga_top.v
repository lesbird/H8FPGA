// =========================================================================
// h8fpga_top -- Heathkit H8 Z80 CPU card, Verilog top level
//
// Replaces H8FPGA.bdf. Functionally equivalent to the original schematic
// except where STABILITY-REVIEW.md says otherwise; every deviation is marked
// with a FIX comment and a section number.
//
// -------------------------------------------------------------------------
// H8 BACKPLANE POLARITY -- important, and easy to get backwards
//
//   The H8 bus carries INVERTED address and data. The original drove
//   GPIO_0[0..15] from 74540/inst30 and inst3, which are INVERTING octal
//   buffers, and the data byte likewise through 74540/inst9 and inst10.
//   Control signals are the opposite: MEMR/MEMW/IOR/IOW/M1 were produced by
//   inverting the Z80's active-low strobes, so they are ACTIVE HIGH on the
//   bus.
//
//   All of that is preserved verbatim below. Do not "clean it up".
//
// -------------------------------------------------------------------------
// PIN MAP (recovered from H8FPGA.bdf; see STABILITY-REVIEW.md)
//
//   GPIO_0[0..15]  out  ~A[0..15]          inverted address
//   GPIO_0[16]     out  reset out          was raw -RESIN, now synchronized
//   GPIO_0[17]     out  MEMR               active high
//   GPIO_0[18]     out  IOR
//   GPIO_0[19]     out  BUSAK_n
//   GPIO_0[20]     out  -NC24, tied high
//   GPIO_0[21]     out  MEMW
//   GPIO_0[22]     out  -CLK  = ~phi
//   GPIO_0[23]     out  IOW
//   GPIO_0[24]     out  M1
//   GPIO_0[25]     out  -NC18 (ORG-0 latch bit 2)
//   GPIO_0[26]     out  '245 DIR
//   GPIO_0[27]     out  tied low
//
//   GPIO_1[0..4]   in   -INT3,-INT4,-INT5,-INT6,-INT7
//   GPIO_1[6..7]   in   -INT1,-INT2
//   GPIO_1[8]      in   -RESIN
//   GPIO_1[12..19] io   inverted data byte
//   GPIO_1[20]     in   DIP4-1   (was SHORTED TO GND -- see FIX below)
//   GPIO_1[21..23] in   DIP4 speed select C,B,A
//   GPIO_1[26..33] in   DIP8, ORG-0 status byte
//   GPIO_1[5,9,10,11,24,25]  unused
//
//   GPIO_2[0..7]   out  A[8..15]  non-inverted copy
//   GPIO_2[8]      out  -NC18
// =========================================================================

module h8fpga_top #(
    // Both default to ~10.5 ms at 50 MHz, which covers front-panel switch
    // bounce. Simulation overrides them to keep run times sane -- there is no
    // reason to simulate 10 ms of debounce.
    parameter RESET_STRETCH_BITS = 19,
    parameter DEBOUNCE_BITS      = 19,

    // 1 = 64K of RAM in the onboard SDRAM (Tier 4)
    // 0 = the original 32K of M9K on-chip RAM
    //
    // Keep 0 available as a bring-up fallback: if the SDRAM misbehaves on
    // hardware you still have a working machine to debug from, and it isolates
    // "is it the SDRAM or is it the rest of the rework?"
    parameter USE_SDRAM          = 1
) (
    input             CLOCK_50,
    output     [27:0] GPIO_0,
    inout      [33:0] GPIO_1,
    output      [8:0] GPIO_2,
    output      [7:0] LED,       // was unused; now debug (review 0.1)

    // ---- SDRAM (Tier 4). Unused when USE_SDRAM = 0. ----
    output     [12:0] DRAM_ADDR,
    output      [1:0] DRAM_BA,
    output      [1:0] DRAM_DQM,
    output            DRAM_CAS_N,
    output            DRAM_RAS_N,
    output            DRAM_WE_N,
    output            DRAM_CS_N,
    output            DRAM_CKE,
    output            DRAM_CLK,
    inout      [15:0] DRAM_DQ
);

    wire clk = CLOCK_50;

    // =====================================================================
    // Reset -- FIX 1.3
    // Was: -RESIN straight into Z80pa RESET_n and both 7474 clears.
    // =====================================================================
    wire resin_n_raw = GPIO_1[8];
    wire rst_n;                  // system reset: everything except the CPU
    wire sdram_ready;

    // NOTE ON h8_reset's `ready` INPUT -- deliberately tied high here.
    //
    // The obvious wiring is .ready(sdram_ready), but that deadlocks: the SDRAM
    // controller needs a reset to run its initialization, and if its own reset
    // is gated by the ready it produces, initialization never starts.
    //
    // So the system reset is ungated, and the CPU gets a separate reset that
    // additionally waits for SDRAM initialization (100 us + mode register).
    h8_reset #(.STRETCH_BITS(RESET_STRETCH_BITS)) u_reset (
        .clk       (clk),
        .resin_n   (resin_n_raw),
        .ready     (1'b1),
        .rst_n_out (rst_n)
    );

    // The CPU stays in reset until the SDRAM is initialized, so it cannot
    // fetch its first instruction out of an uninitialized array.
    wire rst_n_cpu = rst_n & (USE_SDRAM ? sdram_ready : 1'b1);

    // =====================================================================
    // Backplane input synchronizers -- FIX 2.1
    // =====================================================================

    // DIP4 speed select. 81mux select was {C,B,A} with A as LSB, and
    // A=DIP41O=GPIO_1[23], B=DIP42O=GPIO_1[22], C=DIP43O=GPIO_1[21].
    //
    // FIX 1.1: these fed the clock mux with no synchronization OR debounce,
    // so every contact bounce glitched the CPU clock. Now both.
    wire [2:0] dip4_raw = {GPIO_1[21], GPIO_1[22], GPIO_1[23]};
    wire [2:0] dip4_sync, speed_sel;

    h8_sync #(.WIDTH(3)) u_sync_dip4 (
        .clk(clk), .rst_n(rst_n), .async_in(dip4_raw), .sync_out(dip4_sync));
    h8_debounce #(.WIDTH(3), .BITS(DEBOUNCE_BITS)) u_deb_dip4 (
        .clk(clk), .rst_n(rst_n), .noisy_in(dip4_sync), .stable_out(speed_sel));

    // DIP8 ORG-0 status byte, GPIO_1[26..33] -> bits 0..7 (74541/inst47).
    wire [7:0] dip8_raw = {GPIO_1[33], GPIO_1[32], GPIO_1[31], GPIO_1[30],
                           GPIO_1[29], GPIO_1[28], GPIO_1[27], GPIO_1[26]};
    wire [7:0] dip8_sync;

    h8_sync #(.WIDTH(8)) u_sync_dip8 (
        .clk(clk), .rst_n(rst_n), .async_in(dip8_raw), .sync_out(dip8_sync));

    // Backplane data in. GPIO_1[12+i] carries -D[i], hence the inversion.
    wire [7:0] bus_d_raw_n = {GPIO_1[19], GPIO_1[18], GPIO_1[17], GPIO_1[16],
                              GPIO_1[15], GPIO_1[14], GPIO_1[13], GPIO_1[12]};
    wire [7:0] bus_d_sync_n;
    h8_sync #(.WIDTH(8)) u_sync_busd (
        .clk(clk), .rst_n(rst_n), .async_in(bus_d_raw_n), .sync_out(bus_d_sync_n));
    wire [7:0] bus_d = ~bus_d_sync_n;

    // Interrupt lines. Mapping from 74541/inst33's scrambled Y outputs.
    wire [7:1] int_n_raw = {GPIO_1[4],   // -INT7
                            GPIO_1[3],   // -INT6
                            GPIO_1[2],   // -INT5
                            GPIO_1[1],   // -INT4
                            GPIO_1[0],   // -INT3
                            GPIO_1[7],   // -INT2
                            GPIO_1[6]};  // -INT1

    // =====================================================================
    // Clock enables -- FIX 1.1
    // =====================================================================
    wire cen_p_raw, cen_n_raw, phi, stall_seen;
    wire sdram_busy;

    // Freeze the CPU while an SDRAM access is outstanding (review 4.5). At
    // 2.083 MHz a full activate/read/precharge (~180 ns) completes inside a
    // half period (~240 ns), so this should never actually fire at the default
    // speed -- watch LED[0] (stall_seen) to confirm on hardware.
    wire mem_stall = USE_SDRAM ? sdram_busy : 1'b0;

    h8_clkgen u_clkgen (
        .clk        (clk),
        .rst_n      (rst_n),
        .speed_sel  (speed_sel),
        .stall      (mem_stall),
        .cen_p      (cen_p_raw),
        .cen_n      (cen_n_raw),
        .phi        (phi),
        .stall_seen (stall_seen)
    );

    // =====================================================================
    // CPU
    // =====================================================================
    wire        m1_n, mreq_n, iorq_n, rd_n, wr_n, rfsh_n, halt_n, busak_n;
    wire [15:0] cpu_a;
    wire  [7:0] cpu_do;
    wire  [7:0] cpu_di;
    wire        int_n;

    // WAIT_n is tied high for now.
    //
    // NOT A FIX -- review 2.3 remains OPEN. T80pa does implement WAIT_n
    // correctly (it is sampled at T2 and stalls CEN_pol, T80pa.vhd:172), so
    // wiring it is viable. What is missing is knowledge of WHICH backplane pin
    // carries the H8 wait/hold line. GPIO_1[5,9,10,11,24,25] are the unused
    // candidates; identifying the right one needs the PCB schematic. Until
    // then no card can insert wait states, which is why the H8-4 serial and
    // H17 disk controller do not work.
    wire wait_n = 1'b1;

    T80pa u_cpu (
        .RESET_n   (rst_n_cpu),   // held until SDRAM init completes
        .CLK       (clk),          // FIX 1.1: 50 MHz, was the muxed CLKOUT
        .CEN_p     (cen_p_raw),
        .CEN_n     (cen_n_raw),
        .WAIT_n    (wait_n),
        .INT_n     (int_n),
        .NMI_n     (1'b1),
        .BUSRQ_n   (1'b1),
        .M1_n      (m1_n),
        .MREQ_n    (mreq_n),
        .IORQ_n    (iorq_n),
        .RD_n      (rd_n),
        .WR_n      (wr_n),
        .RFSH_n    (rfsh_n),
        .HALT_n    (halt_n),
        .BUSAK_n   (busak_n),
        .OUT0      (1'b0),
        .A         (cpu_a),
        .DI        (cpu_di),
        .DO        (cpu_do),
        .R800_mode (1'b0),
        .DIRSet    (1'b0),
        .DIR       (212'b0)
    );

    // Active-high cycle strobes -- exactly OR2/inst5..8 and inst29.
    wire memr   = ~(mreq_n | rd_n);
    wire memw   = ~(mreq_n | wr_n);
    wire ior    = ~(iorq_n | rd_n);
    wire iow    = ~(iorq_n | wr_n);
    wire intack = ~(m1_n   | iorq_n);

    // =====================================================================
    // Interrupts -- FIX 2.1
    // =====================================================================
    wire [7:0] int_vector;
    wire       int_pending;

    h8_intctl u_intctl (
        .clk         (clk),
        .rst_n       (rst_n),
        .int_n_async (int_n_raw),
        .intack      (intack),
        .int_n       (int_n),
        .vector      (int_vector),
        .int_pending (int_pending)
    );

    // =====================================================================
    // ORG-0 board, port 0362
    // =====================================================================
    wire       org0_sel, org0_rd, org0_wr, rom_dis, nc18;
    wire [7:0] org0_status;

    h8_org0 u_org0 (
        .clk        (clk),
        .rst_n      (rst_n),
        .a          (cpu_a[7:0]),
        .ior        (ior),
        .iow        (iow),
        .cpu_do     (cpu_do),
        .dip8_sync  (dip8_sync),
        .org0_sel   (org0_sel),
        .org0_rd    (org0_rd),
        .org0_wr    (org0_wr),
        .status     (org0_status),
        .rom_dis    (rom_dis),
        .nc18       (nc18)
    );

    // =====================================================================
    // Memory map and read mux -- FIX 1.2, and the ROM-disable fix
    // =====================================================================
    wire       rom_rd, ram_rd, ram_wr, io_bus_rd, io_bus_wr;
    wire [7:0] rom_q;
    wire [7:0] ram_q;

    h8_memmap #(.RAM_FULL_64K(USE_SDRAM)) u_memmap (
        .a           (cpu_a),
        .memr        (memr),
        .memw        (memw),
        .ior         (ior),
        .iow         (iow),
        .intack      (intack),
        .rom_dis     (rom_dis),
        .org0_sel    (org0_sel),
        .org0_rd     (org0_rd),
        .rom_q       (rom_q),
        .ram_q       (ram_q),
        .org0_status (org0_status),
        .bus_d       (bus_d),
        .int_vector  (int_vector),
        .rom_rd      (rom_rd),
        .ram_rd      (ram_rd),
        .ram_wr      (ram_wr),
        .io_bus_rd   (io_bus_rd),
        .io_bus_wr   (io_bus_wr),
        .cpu_di      (cpu_di)
    );

    // ---------------------------------------------------------------------
    // On-chip memories.
    //
    // FIX: clocked on the 50 MHz clock, not the CPU clock. With
    // outdata_reg_a = "CLOCK0" these have two clocks of read latency; on the
    // old 2 MHz CLKOUT that was ~960 ns and worked only by edge-count
    // coincidence. At 50 MHz it is 40 ns, invisible inside a T-state.
    //
    // FIX: rden is tied high. It used to participate in ROM selection
    // (ROMRDEN = ~(ROMEN & 1Q)) which is what broke ORG-0 ROM disable --
    // dropping altsyncram's rden only freezes its output register, it does not
    // remove the ROM from the data path. Selection now lives entirely in
    // h8_memmap's priority mux.
    // ---------------------------------------------------------------------
    H8FPGAROM u_rom (
        .address (cpu_a[11:0]),
        .clock   (clk),
        .rden    (1'b1),
        .q       (rom_q)
    );

    // ---------------------------------------------------------------------
    // RAM backend -- Tier 4.
    //
    // USE_SDRAM = 1: all 64K lives in the onboard SDRAM, and the 32 M9K blocks
    // the old RAM consumed are freed. 66 M9K cannot hold 4K ROM + 64K RAM
    // (68 needed, see review 4.2), which is the whole reason for this tier.
    //
    // The ROM deliberately stays in M9K: SDRAM is volatile, and the CPU fetches
    // from 0x0000 the instant it leaves reset (review 4.1).
    // ---------------------------------------------------------------------
    generate
    if (USE_SDRAM) begin : g_sdram

        h8_sdram u_sdram (
            .clk        (clk),
            .rst_n      (rst_n),        // ungated -- see the reset note above
            .addr       (cpu_a),
            .wdata      (cpu_do),
            .rd         (ram_rd),
            .wr         (ram_wr),
            .rdata      (ram_q),
            .busy       (sdram_busy),
            .ready      (sdram_ready),
            .DRAM_ADDR  (DRAM_ADDR),
            .DRAM_BA    (DRAM_BA),
            .DRAM_DQM   (DRAM_DQM),
            .DRAM_CAS_N (DRAM_CAS_N),
            .DRAM_RAS_N (DRAM_RAS_N),
            .DRAM_WE_N  (DRAM_WE_N),
            .DRAM_CS_N  (DRAM_CS_N),
            .DRAM_CKE   (DRAM_CKE),
            .DRAM_DQ    (DRAM_DQ)
        );

    end else begin : g_m9k

        // Fallback: the original 32K on-chip RAM.
        H8FPGARAM u_ram (
            .address (cpu_a[14:0]),
            .clock   (clk),
            .data    (cpu_do),
            .rden    (1'b1),
            .wren    (ram_wr),
            .q       (ram_q)
        );

        assign sdram_busy  = 1'b0;
        assign sdram_ready = 1'b1;
        assign DRAM_ADDR   = 13'd0;
        assign DRAM_BA     = 2'd0;
        assign DRAM_DQM    = 2'b11;
        assign DRAM_CAS_N  = 1'b1;
        assign DRAM_RAS_N  = 1'b1;
        assign DRAM_WE_N   = 1'b1;
        assign DRAM_CS_N   = 1'b1;   // deselected
        assign DRAM_CKE    = 1'b0;
        assign DRAM_DQ     = 16'bz;

    end
    endgenerate

    // ---------------------------------------------------------------------
    // DRAM_CLK -- the inverted system clock.
    //
    // This places the SDRAM's clock edges in the middle of the controller's
    // clock periods, so read data is valid across our sampling edge with
    // roughly 10 ns of setup and 10 ns of hold at 50 MHz. Both the clock and
    // the data leave through comparable output paths, so the pin delays
    // largely cancel. For a -7 part (tSU ~1.5 ns) that is a very comfortable
    // margin.
    //
    // WHAT THIS IS NOT: a properly phase-compensated DRAM clock. Above roughly
    // 75 MHz you need a PLL output with an explicit phase shift, as Terasic's
    // own DE0-Nano SDRAM demo uses. H8FPGAPLL is still in the project for
    // exactly that. At 50 MHz the inverted clock is sufficient and avoids
    // hand-editing generated megafunction code that cannot be verified here.
    // H8FPGA.sdc constrains this so TimeQuest will tell you if it is wrong.
    // ---------------------------------------------------------------------
    assign DRAM_CLK = ~clk;

    // =====================================================================
    // Data bus transceiver -- FIX 2.2 and 2.5
    // =====================================================================
    wire d245_dir_out, fpga_oe, d245_oe_n;

    h8_busif #(.DEAD_CLKS(2)) u_busif (
        .clk          (clk),
        .rst_n        (rst_n),
        .drive_req    (io_bus_wr),
        .d245_dir_out (d245_dir_out),
        .fpga_oe      (fpga_oe),
        .d245_oe_n    (d245_oe_n)
    );

    // =====================================================================
    // Registered backplane outputs -- FIX 2.4
    //
    // These used to come combinationally off the core, so inter-signal skew
    // was whatever the fitter picked. Registering them in one block gives the
    // backplane an aligned set of transitions and lets FAST_OUTPUT_REGISTER
    // pack them into the I/O cells.
    // =====================================================================
    reg [15:0] a_n_r;
    reg        memr_r, memw_r, ior_r, iow_r, m1_r, phi_r;
    reg        busak_n_r, dir_r, rst_out_n_r, nc18_r;
    reg  [7:0] d_out_n_r;
    reg  [7:0] a_hi_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_n_r       <= 16'hFFFF;   // inverted bus: FFFF = address 0000
            a_hi_r      <= 8'h00;
            memr_r      <= 1'b0;
            memw_r      <= 1'b0;
            ior_r       <= 1'b0;
            iow_r       <= 1'b0;
            m1_r        <= 1'b0;
            phi_r       <= 1'b0;
            busak_n_r   <= 1'b1;
            dir_r       <= 1'b0;       // rest INWARD -- the 2.5 fix
            rst_out_n_r <= 1'b0;
            nc18_r      <= 1'b0;
            d_out_n_r   <= 8'hFF;
        end else begin
            a_n_r       <= ~cpu_a;     // H8 bus address is inverted
            a_hi_r      <= cpu_a[15:8];
            memr_r      <= memr;
            memw_r      <= memw;
            ior_r       <= ior;
            iow_r       <= iow;
            m1_r        <= ~m1_n;
            phi_r       <= phi;
            busak_n_r   <= busak_n;
            dir_r       <= d245_dir_out;
            rst_out_n_r <= rst_n_cpu;
            nc18_r      <= nc18;
            d_out_n_r   <= ~cpu_do;    // H8 bus data is inverted
        end
    end

    assign GPIO_0[15:0] = a_n_r;
    assign GPIO_0[16]   = rst_out_n_r;   // FIX 1.3: was raw -RESIN reflected
    assign GPIO_0[17]   = memr_r;
    assign GPIO_0[18]   = ior_r;
    assign GPIO_0[19]   = busak_n_r;
    assign GPIO_0[20]   = 1'b1;          // -NC24
    assign GPIO_0[21]   = memw_r;
    assign GPIO_0[22]   = ~phi_r;        // -CLK
    assign GPIO_0[23]   = iow_r;
    assign GPIO_0[24]   = m1_r;
    assign GPIO_0[25]   = nc18_r;
    assign GPIO_0[26]   = dir_r;         // '245 DIR
    assign GPIO_0[27]   = 1'b0;

    assign GPIO_2[7:0]  = a_hi_r;
    assign GPIO_2[8]    = nc18_r;

    // ---------------------------------------------------------------------
    // GPIO_1: only the data byte is ever driven.
    //
    // FIX: GPIO_1[20] is now an INPUT. In the original it shared a net with
    // GND/inst40 -- the same node that tied 74541/inst35's GN1/GN2 low -- so
    // the FPGA was driving that pin to 0 against the '245 that drives INTO it.
    // Direct pin contention, and it also jammed 74541/inst35.A1, so DIP44O was
    // stuck at 0 and the bus-clock select never worked.
    // ---------------------------------------------------------------------
    assign GPIO_1[11:0]  = 12'bz;
    assign GPIO_1[19:12] = fpga_oe ? d_out_n_r : 8'bz;
    assign GPIO_1[33:20] = 14'bz;

    // ---------------------------------------------------------------------
    // Debug LEDs -- previously unused pins (review 0.1).
    // LED[0] should stay DARK: a stall at 2 MHz means the memory path is
    // slower than expected.
    // ---------------------------------------------------------------------
    assign LED[0]   = stall_seen;
    assign LED[1]   = rom_dis;
    assign LED[2]   = nc18;
    assign LED[3]   = int_pending;
    assign LED[4]   = ~halt_n;
    assign LED[7:5] = speed_sel;

endmodule
