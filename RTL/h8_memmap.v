// =========================================================================
// h8_memmap -- address decode and CPU read-data priority mux
//
// Replaces 7430/inst16 (-ROMEN), NAND3/inst55 (-RAMWREN), NAND3/inst56
// (-RAMRDEN), NAND3/inst64 (-MEMOK), NOT/inst18, NOT/inst22, NOT/inst23,
// NOT/inst65, and -- most importantly -- the five-driver internal tri-state
// bus on Z80IN.
//
// Addresses STABILITY-REVIEW.md 1.2, 2.1 (the MEMOK interlock), 5.2, and the
// ROM-disable bug documented in h8_org0.v.
//
// -------------------------------------------------------------------------
// WHAT WAS WRONG -- 1.2, the internal tri-state bus
//
//   Z80IN[7:0] had FIVE tri-state drivers wired together:
//
//     74540/inst10  enabled by -DATAI     H8 bus data
//     74540/inst17  enabled by -INTA      interrupt vector
//     74541/inst13  enabled by -ROMEN     ROM
//     74541/inst14  enabled by -RAMRDEN   RAM
//     74541/inst47  enabled by -IOR362    ORG-0 status
//
//   Cyclone IV has no internal tri-state resources, so Quartus flattens this
//   into a mux -- but nothing enforced one-hot, and nothing defined the value
//   when all five enables were inactive. All five enables were also deep
//   combinational decodes (7430/inst16 is an 8-input NAND; 7430/inst46 another)
//   which glitch on every address transition.
//
//   Mutual exclusion was maintained only indirectly, by the MEMOK interlock:
//
//     MEMOK = (-ROMEN) & (-DATAO) & (-DATAI)
//
//   i.e. "not a ROM cycle and not an I/O data cycle, so RAM may answer".
//   An emergent property of unequal-delay combinational paths, feeding a
//   SYNCHRONOUS RAM write enable.
//
// WHAT THIS DOES
//   One explicit priority mux with a defined default. Mutual exclusion is now
//   structural rather than emergent, so MEMOK disappears entirely.
//
//   The 8'hFF default matters: on a real H8 backplane an unclaimed read
//   returns FF from the bus pull-ups. Previously an unclaimed read -- notably
//   anything at or above 0x8000, where nothing drove Z80IN at all -- returned
//   whatever the tri-state collapse produced, which was neither FF nor
//   reproducible between builds.
// =========================================================================

module h8_memmap #(
    // 0 = RAM answers 0x0000-0x7FFF, matching the -A15 term in NAND3/inst55
    //     and inst56 and the 32K on-chip limit (66 M9K blocks cannot hold
    //     4K ROM + 64K RAM; see STABILITY-REVIEW.md 4.2).
    // 1 = RAM answers the full 64K. Set this when Tier 4 moves RAM to SDRAM.
    parameter RAM_FULL_64K = 0
) (
    input      [15:0] a,

    // Active-high cycle strobes, decoded from the CPU's active-low outputs
    // exactly as OR2/inst5..inst8 and inst29 did.
    input             memr,
    input             memw,
    input             ior,
    input             iow,
    input             intack,

    input             rom_dis,       // from h8_org0
    input             org0_sel,      // from h8_org0
    input             org0_rd,

    // Read sources
    input      [7:0]  rom_q,
    input      [7:0]  ram_q,
    input      [7:0]  org0_status,
    input      [7:0]  bus_d,         // synchronized, de-inverted backplane data
    input      [7:0]  int_vector,

    // Memory control
    output            rom_rd,
    output            ram_rd,
    output            ram_wr,

    // I/O routed to the backplane (everything except port 0362)
    output            io_bus_rd,
    output            io_bus_wr,

    output reg [7:0]  cpu_di
);

    // ---------------------------------------------------------------------
    // Windows
    // ---------------------------------------------------------------------
    wire rom_window = (a[15:12] == 4'h0);            // 0x0000-0x0FFF, 4K
    wire ram_window = RAM_FULL_64K ? 1'b1 : ~a[15];  // 32K today, 64K later

    // ---------------------------------------------------------------------
    // Selects
    //
    // THE ROM-DISABLE FIX: rom_rd now includes ~rom_dis, so when the ORG-0
    // board disables the ROM the read falls through to ram_rd and the CPU
    // actually sees the RAM underneath. In the original, ROM stayed in the
    // data path (74541/inst13 was enabled by -ROMEN alone) while RAM was
    // simultaneously locked out by MEMOK -- so a "disabled" ROM returned
    // frozen stale data and RAM at low addresses was unreachable. That is what
    // blocks HDOS and CP/M.
    // ---------------------------------------------------------------------
    assign rom_rd = memr & rom_window & ~rom_dis;
    assign ram_rd = memr & ram_window & ~rom_rd;

    // RAM writes were always allowed under the ROM window in the original,
    // because -ROMEN only asserts on MEMR, so MEMOK was high during MEMW.
    // Preserved: RAM underlies ROM for writes.
    assign ram_wr = memw & ram_window;

    assign io_bus_rd = ior & ~org0_sel;
    assign io_bus_wr = iow & ~org0_sel;

    // ---------------------------------------------------------------------
    // Read priority mux
    //
    // Ordered most-specific first. These are mutually exclusive in practice,
    // but the priority makes that structural instead of relying on decode
    // timing -- if two ever did overlap, the outcome is defined rather than
    // being whatever the fitter produced.
    // ---------------------------------------------------------------------
    always @(*) begin
        if      (intack)    cpu_di = int_vector;   // was 74540/inst17
        else if (org0_rd)   cpu_di = org0_status;  // was 74541/inst47
        else if (io_bus_rd) cpu_di = bus_d;        // was 74540/inst10
        else if (rom_rd)    cpu_di = rom_q;        // was 74541/inst13
        else if (ram_rd)    cpu_di = ram_q;        // was 74541/inst14
        else                cpu_di = 8'hFF;        // idle bus reads FF
    end

endmodule
