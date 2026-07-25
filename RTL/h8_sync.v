// =========================================================================
// h8_sync -- parameterized two-flop synchronizer for H8 backplane inputs
//
// Addresses STABILITY-REVIEW.md 2.1.
//
// WHAT WAS WRONG
//   Nothing crossing from the H8 backplane was synchronized. Every one of
//   these went straight into logic:
//
//     -INT1..-INT7   74541/inst33 -> 74148/inst15 priority encoder -> GSN
//                    -> Z80pa/inst1.INT_n, unregistered. A bus interrupt
//                    changing during an M1 cycle can glitch INT_n mid
//                    acknowledge.
//
//     bus data       GPIO_1[12..19] -> 74540/inst10 -> Z80IN -> CPU DI,
//                    unregistered the whole way.
//
//     DIP4 / DIP8    GPIO_1[20..23] and GPIO_1[26..33] -> 74541/inst35 and
//                    74541/inst34 -> straight into the clock mux select and
//                    the ORG-0 status byte.
//
// ORDERING RULE
//   Synchronize FIRST, then combine. For the interrupt lines that means
//   synchronizing all seven inputs and only then priority-encoding them --
//   never the other way round. Encoding first and synchronizing the encoder
//   output lets a single input transition produce a transient wrong code that
//   then gets faithfully captured.
//
// WHY THE FALSE_PATH IN H8FPGA.sdc IS NOT A FIX
//   set_false_path silences the analyzer. This module is what actually makes
//   the crossing safe. Both are needed.
// =========================================================================

module h8_sync #(
    parameter WIDTH  = 1,
    parameter STAGES = 2      // 2 is standard; 3 for very high clock rates
) (
    input                  clk,
    input                  rst_n,
    input      [WIDTH-1:0] async_in,
    output     [WIDTH-1:0] sync_out
);

    // PRESERVE_REGISTER stops Quartus merging or retiming the chain, which
    // would defeat the purpose. SYNCHRONIZER_IDENTIFICATION lets TimeQuest
    // recognize it and report MTBF.
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS ; -name PRESERVE_REGISTER ON" *)
    reg [WIDTH-1:0] chain [STAGES-1:0];

    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < STAGES; i = i + 1)
                chain[i] <= {WIDTH{1'b1}};   // idle-high: these are active-low
        end else begin
            chain[0] <= async_in;
            for (i = 1; i < STAGES; i = i + 1)
                chain[i] <= chain[i-1];
        end
    end

    assign sync_out = chain[STAGES-1];

endmodule


// =========================================================================
// h8_debounce -- for the mechanical DIP switches only
//
// A synchronizer alone is not enough for DIP4 / DIP8. Metastability is
// resolved, but contact bounce still produces a burst of clean transitions.
// That was tolerable for the ORG-0 status byte, which is only sampled when
// the CPU reads the port, but it was NOT tolerable for the clock mux select
// (review 1.1) where every bounce edge glitched the CPU clock.
//
// Feed h8_clkgen.speed_sel from this, not from h8_sync directly.
// =========================================================================

module h8_debounce #(
    parameter WIDTH = 1,
    parameter BITS  = 19          // ~10.5 ms at 50 MHz
) (
    input                  clk,
    input                  rst_n,
    input      [WIDTH-1:0] noisy_in,     // already through h8_sync
    output reg [WIDTH-1:0] stable_out
);

    reg [WIDTH-1:0] last;
    reg [BITS-1:0]  cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            last       <= noisy_in;
            stable_out <= noisy_in;
            cnt        <= {BITS{1'b0}};
        end else if (noisy_in != last) begin
            // Any change restarts the settling window.
            last <= noisy_in;
            cnt  <= {BITS{1'b0}};
        end else if (cnt != {BITS{1'b1}}) begin
            cnt <= cnt + 1'b1;
        end else begin
            // Input has been unchanged for the full window -- accept it.
            stable_out <= last;
        end
    end

endmodule
