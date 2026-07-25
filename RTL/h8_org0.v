// =========================================================================
// h8_org0 -- HA8-8 ORG-0 configuration board, port 0362 octal
//
// Replaces 7430/inst46, NAND2/inst42, NAND2/inst43, NAND2/inst44,
// NAND2/inst45, NAND2/inst58, NOT/inst52 and 7474/inst37.
//
// PORT ADDRESS
//   7430/inst46 was an 8-input NAND on A1, A4, A5, A6, A7 and the inverted
//   -A0, -A2, -A3, so -ORG0SEL asserted when
//
//     A7 A6 A5 A4 A3 A2 A1 A0 = 1  1  1  1  0  0  1  0  = 0xF2
//
//   0xF2 = 0362 octal, which is where the HA8-8 ORG-0 board lives. Only the
//   low eight address bits are decoded, matching Z80 I/O convention and the
//   original schematic.
//
// READ  (port 0362): returns the DIP8 status byte, GPIO_1[26..33] -> bits 0..7
//                    via 74541/inst47.
// WRITE (port 0362): 7474/inst37 latched two bits through inverters --
//                    NOT/inst53 gave 1D = ~DO[5], NOT/inst54 gave 2D = ~DO[6].
//                    -RESIN cleared both.
//
//   1Q became -ROMDIS (through NAND2/inst45 wired as an inverter), so
//   rom_dis = ~DO[5] latched.  Writing DO[5]=0 disables the ROM.
//   2Q became -NC18 (through NAND2/inst44), driven out on GPIO_0[25] and
//   GPIO_2[8], so nc18 = ~DO[6] latched.
//
//   Both reset to 0, i.e. ROM enabled.
//
// -------------------------------------------------------------------------
// BUG FIXED HERE (this one blocks HDOS and CP/M)
//
//   In the original, "ROM disabled" did not actually remove the ROM from the
//   CPU's data path. -ROMDIS only fed ROMRDEN (the altsyncram read enable):
//
//     ROMRDEN = ~(ROMEN_active & 1Q)
//
//   Dropping altsyncram's rden merely FREEZES its output register -- it does
//   not tri-state anything. Meanwhile the buffer that actually drove the data
//   onto Z80IN, 74541/inst13, was enabled by -ROMEN alone, with no -ROMDIS
//   term. And RAM could not answer either, because MEMOK excluded any cycle
//   where -ROMEN was active.
//
//   Net result: with the ROM "disabled", reads of 0x0000-0x0FFF returned
//   STALE FROZEN ROM DATA rather than the underlying RAM. Since the entire
//   purpose of the ORG-0 board is to put RAM at low addresses so HDOS and
//   CP/M can boot, that feature never worked.
//
//   The fix lives in h8_memmap: rom_dis now removes ROM from the read
//   priority mux, letting RAM fall through. rden is no longer part of the
//   selection logic at all.
// =========================================================================

module h8_org0 (
    input            clk,
    input            rst_n,

    input      [7:0] a,            // CPU A[7:0]
    input            ior,          // active-high I/O read  strobe
    input            iow,          // active-high I/O write strobe
    input      [7:0] cpu_do,       // CPU data out

    input      [7:0] dip8_sync,    // DIP8, already synchronized

    output           org0_sel,     // port 0362 decoded
    output           org0_rd,
    output           org0_wr,
    output     [7:0] status,       // read data for port 0362

    output reg       rom_dis,      // 1 = ROM removed from the memory map
    output reg       nc18          // -> GPIO_0[25] and GPIO_2[8]
);

    assign org0_sel = (a == 8'hF2);     // 0362 octal
    assign org0_rd  = ior & org0_sel;
    assign org0_wr  = iow & org0_sel;
    assign status   = dip8_sync;

    // ---------------------------------------------------------------------
    // Configuration latch.
    //
    // The original 7474 clocked on the RISING edge of -IOW362, i.e. at the
    // END of the write cycle. Here the value is captured on the first clock
    // where the write strobe is seen instead. The software-visible behaviour
    // is identical -- the CPU holds DO stable across the whole strobe -- and
    // the synchronous form removes a gated clock.
    // ---------------------------------------------------------------------
    reg org0_wr_d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // -RESIN cleared the 7474, so ROM starts ENABLED. Getting this
            // wrong means the machine cannot fetch its first instruction.
            rom_dis   <= 1'b0;
            nc18      <= 1'b0;
            org0_wr_d <= 1'b0;
        end else begin
            org0_wr_d <= org0_wr;
            if (org0_wr && !org0_wr_d) begin
                rom_dis <= ~cpu_do[5];   // NOT/inst53 -> 1D
                nc18    <= ~cpu_do[6];   // NOT/inst54 -> 2D
            end
        end
    end

endmodule
