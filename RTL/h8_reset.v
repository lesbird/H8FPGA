// =========================================================================
// h8_reset -- reset synchronizer / stretcher / debouncer
//
// Addresses STABILITY-REVIEW.md 1.3.
//
// WHAT WAS WRONG
//   Net -RESIN came off the H8 bus through 74541/inst33.Y8 and went DIRECTLY
//   to Z80pa/inst1.RESET_n and to both 7474/inst37 clear inputs, with no
//   synchronizer, no debounce, and no minimum-pulse guarantee.
//
//   T80 is a deep pipelined core. Releasing reset asynchronously lets
//   different pipeline stages leave reset on different clocks, which is the
//   textbook cause of "boots fine most of the time, occasionally comes up
//   dead". A bouncing front-panel RESET button makes it worse: each bounce
//   edge is another chance to release mid-cycle.
//
//   -RESIN was also re-driven straight back out onto GPIO_0[16], reflecting
//   the unsynchronized signal onto the backplane. Drive the bus reset from
//   rst_n_out instead.
//
// WHAT THIS DOES
//   Asynchronous assert, synchronous release, with the release held off until
//   the input has been stably high for STRETCH_BITS worth of clocks.
//
//   The stretch doubles as a debouncer for free: every bounce re-asserts and
//   restarts the counter, so release only happens once the line is genuinely
//   stable. Default 2^19 = 524288 clocks = ~10.5 ms at 50 MHz, comfortably
//   past mechanical bounce on a front-panel switch.
//
//   The `ready` input gates release as well, so Tier 4 can hold the CPU in
//   reset until SDRAM initialization (100 us + mode register load) finishes.
// =========================================================================

module h8_reset #(
    // 2^STRETCH_BITS clocks of stable input required before release.
    //   19 -> ~10.5 ms  @ 50 MHz  (default; covers switch bounce)
    //   13 -> ~164  us  @ 50 MHz  (enough for SDRAM init only)
    parameter STRETCH_BITS = 19
) (
    input      clk,          // 50 MHz
    input      resin_n,      // raw -RESIN off the bus, active low, async
    input      ready,        // hold reset asserted while low (e.g. SDRAM init)
    output     rst_n_out     // synchronized, stretched, debounced
);

    // ---------------------------------------------------------------------
    // Two-flop metastability filter on the release edge. The assert edge goes
    // straight to the asynchronous reset input of these flops, so assertion
    // is immediate and does not depend on the clock running at all -- which
    // matters during power-up before the PLL locks.
    // ---------------------------------------------------------------------
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS ; -name PRESERVE_REGISTER ON" *)
    reg [1:0] meta;

    reg [STRETCH_BITS-1:0] cnt;

    // Release only once the counter has saturated AND the caller is ready.
    wire stretch_done = (cnt == {STRETCH_BITS{1'b1}});
    assign rst_n_out  = stretch_done & ready;

    always @(posedge clk or negedge resin_n) begin
        if (!resin_n) begin
            // Asynchronous assert. Any glitch on the input restarts the whole
            // sequence, which is the safe direction to fail.
            meta <= 2'b00;
            cnt  <= {STRETCH_BITS{1'b0}};
        end else begin
            meta <= {meta[0], 1'b1};
            if (meta[1] && !stretch_done)
                cnt <= cnt + 1'b1;
        end
    end

endmodule
