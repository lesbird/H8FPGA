// =========================================================================
// h8_clkgen -- Z80 clock-enable generator
//
// Replaces the combinational clock mux 81mux/inst41 (STABILITY-REVIEW.md 1.1).
//
// WHAT WAS WRONG
//   81mux/inst41 combinationally selected one of five PLL outputs onto net
//   CLKOUT, which clocked Z80pa/inst1.CLKIN, H8FPGAROM/inst11.clock and
//   H8FPGARAM/inst12.clock. The select lines came straight off GPIO_1[21..23]
//   through 74541/inst35 with no synchronization or debounce, so:
//     - the mux glitched whenever the DIP switch was touched, and could glitch
//       even when it was not, since the PLL outputs are unrelated phases
//     - the CPU clock sat on general routing, not a global clock buffer
//     - mux inputs D5/D6/D7 were UNCONNECTED, so DIP positions 5/6/7 produced
//       an undefined clock and the CPU simply stopped
//
// WHAT THIS DOES INSTEAD
//   Everything runs on the raw 50 MHz oscillator, on a real global clock
//   buffer, in ONE clock domain. The Z80 rate is set by clock enables, which
//   is what T80pa was designed for -- see T80pa.vhd v2.0: "support for both
//   CEN_n and CEN_p set to 1. Effective clock will be CLK/2."
//
//   Changing speed now changes a divisor. The clock itself never glitches, so
//   there is nothing to go wrong when the switch is thrown mid-instruction.
//
// FREQUENCIES
//   One cen_p and one cen_n pulse per Z80 period; phi toggles every DIV
//   master clocks, so the Z80 clock is 50 MHz / (2 * DIV):
//
//     DIV = 12  ->  2.083 MHz   (matches the old PLL c0, /24)
//     DIV =  6  ->  4.17  MHz   (matches c1, /12)
//     DIV =  3  ->  8.33  MHz   (matches c2, /6)
//
// =========================================================================

module h8_clkgen (
    input            clk,        // 50 MHz oscillator, straight off CLOCK_50
    input            rst_n,      // from h8_reset

    // Speed select. MUST already be synchronized and debounced -- feeding raw
    // DIP switch pins in here reintroduces the original bug in a new place.
    input      [2:0] speed_sel,

    // Stall request. Hold high while an SDRAM access (or anything else with
    // latency) is outstanding. The counter FREEZES rather than dropping a
    // pulse, so the CPU cycle is stretched, not skipped -- see note below.
    input            stall,

    output reg       cen_p,      // -> T80pa CEN_p, coincides with phi rising
    output reg       cen_n,      // -> T80pa CEN_n, coincides with phi falling
    output reg       phi,        // emulated Z80 clock, for BUSSCLK

    // Debug: latches high if a stall was ever needed. At 2 MHz an SDRAM
    // access (~140 ns) completes well inside a half period (~240 ns), so this
    // should stay LOW at the default speed. If it lights up at 2 MHz,
    // something in the memory path is slower than expected. Wire it to a
    // spare LED -- LED[0..7] are unused today (review 0.1).
    output reg       stall_seen
);

    // ---------------------------------------------------------------------
    // Divisor select.
    //
    // The default case matters: 81mux/inst41 left D5/D6/D7 dangling, so the
    // three unused DIP codes produced an undefined clock. Here every one of
    // the eight codes resolves to a real, safe divisor.
    // ---------------------------------------------------------------------
    reg [4:0] div_sel;
    always @(*) begin
        case (speed_sel)
            3'd0:    div_sel = 5'd12;   // ~2.083 MHz -- authentic H8 rate
            3'd1:    div_sel = 5'd6;    // ~4.17  MHz
            3'd2:    div_sel = 5'd3;    // ~8.33  MHz
            3'd3:    div_sel = 5'd1;    // 25 MHz -- the fastest CEN can reach
            default: div_sel = 5'd12;   // never undefined
        endcase
    end

    // NOTE ON THE MISSING 50 MHz SETTING
    //
    // The original 81mux offered a CLK50MHZ tap. That rate is not reachable
    // with clock enables and is not a regression that can be fixed here: the
    // CEN_p/CEN_n scheme is inherently two-phase, needing one master clock for
    // each half of the emulated Z80 cycle, so the ceiling is clk/2 = 25 MHz.
    //
    // Little is lost. A 50 MHz setting would leave the SDRAM controller no
    // clocks at all between CPU accesses, and the old 50 MHz tap fed the CPU
    // through a LUT-routed clock in a design with no timing constraints, so
    // whether it ever really ran is doubtful. If 50 MHz is genuinely wanted,
    // it needs a faster master clock from the PLL, not a smaller divisor.

    // ---------------------------------------------------------------------
    // The divisor is latched at a phi boundary rather than used directly, so
    // that throwing the DIP switch mid-count cannot produce a runt half
    // cycle. Speed changes are therefore clean at the phi level as well as
    // glitch-free at the clock level.
    // ---------------------------------------------------------------------
    reg [4:0] div_active;
    reg [4:0] cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt        <= 5'd0;
            div_active <= 5'd12;
            phi        <= 1'b0;
            cen_p      <= 1'b0;
            cen_n      <= 1'b0;
            stall_seen <= 1'b0;
        end else begin
            // Enables are single-cycle pulses; default them off every clock.
            cen_p <= 1'b0;
            cen_n <= 1'b0;

            if (stall) begin
                // FREEZE. Do not advance cnt and do not emit a pulse.
                //
                // Freezing rather than masking is the important part: if the
                // counter kept running we would DROP a half cycle instead of
                // DELAYING it, which desynchronizes the CPU from phi and from
                // the H8 bus. Stretching is what a real CPU card effectively
                // does when a slow access is in progress.
                stall_seen <= 1'b1;
            end else if (cnt >= div_active - 1'b1) begin
                cnt        <= 5'd0;
                div_active <= div_sel;      // apply speed change here only
                phi        <= ~phi;
                // phi on the RHS is the pre-toggle value, so cen_p lands on
                // the rising edge of the emulated clock and cen_n on falling.
                if (!phi) cen_p <= 1'b1;
                else      cen_n <= 1'b1;
            end else begin
                cnt <= cnt + 1'b1;
            end
        end
    end

    // ---------------------------------------------------------------------
    // NOTE ON STRETCHING AND THE H8 2 ms CLOCK INTERRUPT
    //
    // Stretching phi makes the bus clock momentarily slower, which would
    // drift any H8 timing derived from it. This is a non-issue at the default
    // 2.083 MHz because stall should never assert there (see stall_seen).
    // At 8 MHz and above, stalls can occur and the bus clock will drift
    // slightly -- but H8 timing is already non-authentic at those speeds.
    //
    // NOTE ON phi POLARITY
    //
    // The existing design inverts the bus clock on the way out
    // (BUSSCLK -> NOT/inst60 -> GPIO_0[22]). Preserve whatever polarity the
    // H8 backplane expects when wiring phi to that pin.
    // ---------------------------------------------------------------------

endmodule
