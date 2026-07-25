// =========================================================================
// h8_busif -- bidirectional data transceiver turnaround control
//
// Replaces NAND2/inst24 (-DATAO) and NAND2/inst25 (-DATAI), and addresses
// STABILITY-REVIEW.md 2.2 and 2.5.
//
// THE HARDWARE
//   GPIO_1[12..19] is the bidirectional data byte, buffered by one 74LVC245
//   whose DIR pin is driven from GPIO_0[26]. Per README.md: DIR low = '245
//   inputs from the H8 bus, DIR high = '245 outputs to the H8 bus.
//
//   The FPGA's own output enable on those eight pins is separate, and was
//   74540/inst9's GN input.
//
// WHAT WAS WRONG -- 2.5, the serious one
//   DIR came from -DATAI = NAND(IOR, -ORG0SEL), asserted low only during a
//   non-ORG-0 I/O READ. So GPIO_0[26] sat HIGH -- transceiver pointing at the
//   backplane -- during every memory cycle and every idle cycle.
//
//   During those same cycles 74540/inst9 was disabled, so GPIO_1[12..19] were
//   floating FPGA inputs, and the '245 dutifully amplified those floating
//   levels onto the H8 data bus. The board was injecting indeterminate levels
//   onto the backplane the large majority of the time. It only worked because
//   nothing else was contending.
//
// WHAT WAS WRONG -- 2.2
//   DIR and the FPGA output enable came from two DIFFERENT gates (inst25 and
//   inst24) with different propagation delays and no enforced non-overlap, so
//   every turnaround had an uncontrolled overlap window.
//
// WHAT THIS DOES
//   Resting state is DIR = inward. The FPGA sources the bus only while
//   drive_req is high, and the transition is sequenced through a registered
//   FSM with a parameterized guard band.
//
// -------------------------------------------------------------------------
// A HONEST LIMITATION
//
//   A truly clean turnaround needs the '245's /OE, giving a state where
//   NEITHER side drives. The V1.5 PCB appears to hardwire /OE active (README
//   describes only a DIR jumper), so the transceiver is always driving one
//   way or the other and no such state exists.
//
//   Given that, there are only two possible overlap conditions and both are
//   imperfect:
//
//     DIR=out + OE=0 -> the '245 amplifies a floating FPGA pin onto the H8
//                       backplane. Garbage reaches every other card.
//     DIR=in  + OE=1 -> the FPGA and the '245 both drive the short trace
//                       between them. A real but brief, current-limited
//                       fight confined to this board.
//
//   This FSM deliberately chooses the second: it asserts the FPGA output
//   enable FIRST, holds for DEAD_CLKS, then flips DIR outward; and on the way
//   back it returns DIR inward first, holds, then releases the FPGA. Keeping
//   indeterminate levels off the shared backplane is worth accepting a
//   bounded overlap on one local trace.
//
//   RECOMMENDED PCB CHANGE (V1.6): route the bidirectional '245's /OE to a
//   spare GPIO_0 pin. GPIO_0[28..33] are unassigned in the design today. That
//   would allow a true high-impedance guard band and make this module's
//   compromise unnecessary. The d245_oe_n output below is provided ready for
//   it; it is safe to leave unconnected.
// =========================================================================

module h8_busif #(
    // Guard band in 50 MHz clocks on each side of the turnaround.
    // 2 clocks = 40 ns, comfortably longer than the 74LVC245's ~5-8 ns
    // direction switching time, and negligible against a ~500 ns I/O strobe.
    parameter DEAD_CLKS = 2
) (
    input        clk,
    input        rst_n,

    // High for the duration of a cycle in which the FPGA must source the H8
    // data bus -- i.e. an I/O write to any port other than 0362.
    input        drive_req,

    output       d245_dir_out,   // -> GPIO_0[26]. 1 = '245 drives the bus.
    output       fpga_oe,        // FPGA output enable for GPIO_1[12..19]
    output       d245_oe_n       // for a future V1.6 /OE line; low = enabled
);

    localparam ST_IN      = 2'd0,   // rest: DIR inward, FPGA released
               ST_TO_OUT  = 2'd1,   // FPGA driving, DIR still inward
               ST_OUT     = 2'd2,   // DIR outward, FPGA driving
               ST_TO_IN   = 2'd3;   // DIR back inward, FPGA still driving

    reg [1:0] state;
    reg [7:0] cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IN;
            cnt   <= 8'd0;
        end else begin
            case (state)
                ST_IN: begin
                    cnt <= 8'd0;
                    if (drive_req) state <= ST_TO_OUT;
                end

                ST_TO_OUT: begin
                    // Let the FPGA pins reach a valid level before the '245
                    // starts sourcing from them.
                    if (!drive_req)            state <= ST_IN;
                    else if (cnt >= DEAD_CLKS-1) begin
                        state <= ST_OUT;
                        cnt   <= 8'd0;
                    end else cnt <= cnt + 8'd1;
                end

                ST_OUT: begin
                    cnt <= 8'd0;
                    if (!drive_req) state <= ST_TO_IN;
                end

                ST_TO_IN: begin
                    // DIR is already back inward here; hold the FPGA on a
                    // moment longer so the '245 never sources from a released
                    // pin.
                    if (cnt >= DEAD_CLKS-1) begin
                        state <= ST_IN;
                        cnt   <= 8'd0;
                    end else cnt <= cnt + 8'd1;
                end

                default: state <= ST_IN;
            endcase
        end
    end

    // DIR points at the backplane in ST_OUT only. Every other state -- and
    // critically, reset and idle -- rests inward. This is the 2.5 fix.
    assign d245_dir_out = (state == ST_OUT);

    // FPGA drives through the whole turnaround, so the '245 always has a
    // valid level to source once DIR flips.
    assign fpga_oe = (state == ST_TO_OUT) || (state == ST_OUT) ||
                     (state == ST_TO_IN);

    // Future V1.6 /OE: disable the transceiver during both guard bands to get
    // a genuine dead state. Harmless on V1.5 where the pin goes nowhere.
    assign d245_oe_n = (state == ST_TO_OUT) || (state == ST_TO_IN);

endmodule
