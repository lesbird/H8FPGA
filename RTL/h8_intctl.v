// =========================================================================
// h8_intctl -- H8 interrupt priority encoder and RST vector generator
//
// Replaces 74148/inst15 + 74540/inst17 (STABILITY-REVIEW.md 2.1).
//
// WHAT THE ORIGINAL DID
//   74541/inst33 buffered seven backplane interrupt lines, 74148/inst15
//   priority-encoded them, GSN went straight to Z80pa/inst1.INT_n, and
//   74540/inst17 (an INVERTING buffer, enabled by -INTA) placed the vector on
//   the Z80IN tri-state bus.
//
//   The vector byte was formed as follows -- GND/inst28 drove inst17 inputs
//   A1, A2, A3, A7 and A8, and the 74148's active-low code outputs A0N/A1N/A2N
//   drove A4/A5/A6. Because the 540 inverts:
//
//     Z80IN[2:0] = ~0     = 111
//     Z80IN[5:3] = ~AnN   = the true priority code
//     Z80IN[7:6] = ~0     = 11
//
//   giving 8'hC7 | (level << 3) -- an RST n instruction. That is the classic
//   Heath 8080/H8 scheme: interrupt level n vectors through RST n, so level 1
//   (the 2 ms clock) lands at 0x0008.
//
// WHAT WAS WRONG
//   Nothing was synchronized, and the priority encode happened BEFORE any
//   registration. A backplane interrupt line changing while the encoder was
//   settling produced a transient wrong code, and during an -INTA cycle that
//   transient was what the CPU fetched as its instruction.
//
// WHAT THIS DOES
//   Synchronize all seven lines FIRST, then encode. And latch the level when
//   the acknowledge cycle begins, so a higher-priority interrupt arriving
//   mid-fetch cannot change the vector out from under the CPU.
// =========================================================================

module h8_intctl (
    input            clk,
    input            rst_n,

    // -INT1..-INT7 straight off the backplane buffers, active low, async.
    // Bit index == H8 interrupt level.
    input      [7:1] int_n_async,

    // Asserted for the duration of the interrupt acknowledge cycle
    // (M1_n low and IORQ_n low -- OR2/inst29 in the original).
    input            intack,

    output           int_n,        // -> T80pa INT_n, active low
    output     [7:0] vector,       // RST n instruction for the ack cycle
    output           int_pending   // debug / LED
);

    // ---------------------------------------------------------------------
    // Synchronize first. Idle state is all-ones because these are active low,
    // so a reset cannot manufacture a phantom interrupt.
    // ---------------------------------------------------------------------
    wire [7:1] int_n_s;
    h8_sync #(.WIDTH(7)) u_sync (
        .clk      (clk),
        .rst_n    (rst_n),
        .async_in (int_n_async),
        .sync_out (int_n_s)
    );

    // ---------------------------------------------------------------------
    // Priority encode, level 7 highest -- matches the 74148, whose input 7
    // has top priority. The original tied 0N to VCC (level 0 unused) and EIN
    // to GND (permanently enabled); both are folded in here.
    // ---------------------------------------------------------------------
    reg [2:0] level;
    always @(*) begin
        if      (!int_n_s[7]) level = 3'd7;
        else if (!int_n_s[6]) level = 3'd6;
        else if (!int_n_s[5]) level = 3'd5;
        else if (!int_n_s[4]) level = 3'd4;
        else if (!int_n_s[3]) level = 3'd3;
        else if (!int_n_s[2]) level = 3'd2;
        else if (!int_n_s[1]) level = 3'd1;
        else                  level = 3'd0;
    end

    assign int_pending = ~(&int_n_s);   // any line low
    assign int_n       =   &int_n_s;    // 74148 GSN equivalent

    // ---------------------------------------------------------------------
    // Latch the level at the START of the acknowledge cycle.
    //
    // This is a deliberate improvement over the original, which fed the live
    // encoder output through inst17 for the whole cycle. If a higher-priority
    // interrupt asserted partway through the fetch, the vector changed and the
    // CPU could execute an RST for a level that was never acknowledged.
    // ---------------------------------------------------------------------
    reg [2:0] level_held;
    reg       intack_d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            level_held <= 3'd0;
            intack_d   <= 1'b0;
        end else begin
            intack_d <= intack;
            if (intack && !intack_d)   // rising edge of the ack cycle
                level_held <= level;
        end
    end

    // 8'hC7 = 11000111. OR in the level at bits [5:3] to form RST n.
    assign vector = 8'hC7 | {2'b00, level_held, 3'b000};

endmodule
