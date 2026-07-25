// =========================================================================
// h8_sdram -- single-byte random-access SDRAM controller for the DE0-Nano
//
// Implements STABILITY-REVIEW.md Tier 4: move the 64K of Z80 RAM off the M9K
// blocks and into the onboard SDRAM, so a 4K ROM and a full 64K of RAM can
// coexist (66 M9K blocks cannot hold both -- see 4.2).
//
// TARGET DEVICE
//   ISSI IS42S16160 family, 32 MB, 16-bit, 4 banks.
//     13 row address bits (8192 rows), 9 column bits (512 words), 2 bank bits.
//     Refresh: 8192 rows / 64 ms = one AUTO REFRESH every 7.8125 us.
//
//   CONFIRM the exact part and speed grade for your board revision -- some
//   DE0-Nano builds use IS42S16320. The timing parameters below are
//   deliberately generous for a -7 grade at 50 MHz; if your part is slower,
//   raise them (they are all parameters).
//
// WHY THIS AND NOT AN EXISTING CONTROLLER
//   Terasic's Sdram_Control from the DE0-Nano CD is FIFO/streaming oriented,
//   and MiSTer's sdram.sv is tuned for 100+ MHz video access patterns. This
//   access pattern is the easiest possible case: one random byte at a time,
//   latency tolerant, very low bandwidth. A purpose-built controller is both
//   smaller and easier to reason about.
//
// CLOCKING
//   Runs at 50 MHz in the SAME domain as the CPU (review 4.3). One byte per
//   ~1.5 us Z80 M-cycle against a ~100 MB/s interface is not a bandwidth
//   problem, and a single domain means no CDC and no dual-clock FIFO.
//
// ADDRESS MAP
//   64 KB = 32K 16-bit words = 15 word-address bits.
//     bank = 0            (the whole 64K lives in one bank, so a row can stay
//     row  = word[14:9]    open across sequential fetches)
//     col  = word[8:0]
//   A[0] selects the byte within the word: DQM masking on writes, half
//   selection on reads.
//
// ROW CACHING
//   512 words = 1 KB per row, so sequential Z80 code fetches usually hit the
//   already-open row. A hit costs READ + CL = 4 clocks (80 ns) instead of
//   ACTIVATE + tRCD + READ + CL + PRECHARGE + tRP = 9 clocks (180 ns).
//   At 2.083 MHz neither matters; it is what makes 8 MHz+ comfortable.
// =========================================================================

module h8_sdram #(
    // Timing in 50 MHz clocks (20 ns each). One clock already covers a 15-20 ns
    // spec, but these are rounded up because the margin is free at this speed.
    parameter T_RP        = 2,      // precharge -> activate
    parameter T_RCD       = 2,      // activate  -> read/write
    parameter T_RC        = 4,      // activate  -> activate, same bank
    parameter T_WR        = 2,      // write recovery
    parameter T_MRD       = 2,      // mode register set
    parameter CAS_LATENCY = 2,      // must match the mode register below
    parameter T_INIT      = 5200,   // >= 100 us at 50 MHz
    parameter T_REFRESH   = 384,    // 7.68 us; spec allows 7.8125 us

    // Clocks to wait after issuing READ before latching the captured word.
    //
    // BRING-UP KNOB. DRAM_CLK is the inverted system clock, so the SDRAM's
    // edges sit mid-period and the controller's sampling edge should land in
    // the centre of the data window -- about 10 ns of margin each side at
    // 50 MHz. CAS_LATENCY is correct under that assumption and is what the
    // simulation verifies.
    //
    // If the bench disagrees (reads return 0xFF/0x00 or garbage while writes
    // clearly work), this is the first thing to adjust: try CAS_LATENCY+1.
    // Simulation pins the logic, not the electrical capture point -- see the
    // phase note in SIM/sdram_model.v.
    parameter T_RD_WAIT   = CAS_LATENCY
) (
    input             clk,          // 50 MHz, same domain as the CPU
    input             rst_n,

    // ---- CPU side ----
    input      [15:0] addr,         // Z80 A[15:0]
    input       [7:0] wdata,
    input             rd,           // level strobe, held for the M-cycle
    input             wr,
    output      [7:0] rdata,
    output            busy,         // gates h8_clkgen.stall
    output            ready,        // init complete; gates h8_reset.ready

    // ---- SDRAM pins ----
    output reg [12:0] DRAM_ADDR,
    output reg  [1:0] DRAM_BA,
    output reg  [1:0] DRAM_DQM,
    output reg        DRAM_CAS_N,
    output reg        DRAM_RAS_N,
    output reg        DRAM_WE_N,
    output reg        DRAM_CS_N,
    output reg        DRAM_CKE,
    inout      [15:0] DRAM_DQ
);

    // ---------------------------------------------------------------------
    // Command encoding: {CS_N, RAS_N, CAS_N, WE_N}
    // ---------------------------------------------------------------------
    localparam CMD_NOP      = 4'b0111,
               CMD_ACTIVE   = 4'b0011,
               CMD_READ     = 4'b0101,
               CMD_WRITE    = 4'b0100,
               CMD_PRECHARGE= 4'b0010,
               CMD_REFRESH  = 4'b0001,
               CMD_LOADMODE = 4'b0000,
               CMD_INHIBIT  = 4'b1111;

    // Mode register: burst length 1, sequential, CAS latency 2, standard op.
    //   A2:A0 = 000  burst length 1
    //   A3    = 0    sequential
    //   A6:A4 = 010  CAS latency 2
    //   A8:A7 = 00   standard operating mode
    //   A9    = 0    programmed burst length for writes
    localparam [12:0] MODE_REG = 13'b000_0_00_010_0_000;   // = 13'h020

    // ---------------------------------------------------------------------
    // Address decomposition
    // ---------------------------------------------------------------------
    wire [14:0] word_addr = addr[15:1];
    wire  [8:0] col       = word_addr[8:0];
    wire  [5:0] row       = word_addr[14:9];
    wire        byte_hi   = addr[0];

    // ---------------------------------------------------------------------
    // States
    // ---------------------------------------------------------------------
    localparam S_INIT_WAIT = 5'd0,
               S_INIT_PRE  = 5'd1,
               S_INIT_REF1 = 5'd2,
               S_INIT_REF2 = 5'd3,
               S_INIT_MRS  = 5'd4,
               S_IDLE      = 5'd5,
               S_ACT       = 5'd6,
               S_ACT_WAIT  = 5'd7,
               S_READ      = 5'd8,
               S_READ_WAIT = 5'd9,
               S_WRITE     = 5'd10,
               S_WRITE_WAIT= 5'd11,
               S_PRE       = 5'd12,
               S_PRE_WAIT  = 5'd13,
               S_REF_PRE   = 5'd14,
               S_REF_PREW  = 5'd15,
               S_REF       = 5'd16,
               S_REF_WAIT  = 5'd17,
               S_DONE      = 5'd18;

    reg  [4:0] state;
    reg [13:0] wait_cnt;
    reg  [4:0] wait_next;      // state to enter when wait_cnt expires

    // Open-row tracking
    reg        row_valid;
    reg  [5:0] open_row;

    // Latched request
    reg        req_active;     // a transaction is in flight
    reg        req_is_write;
    reg  [8:0] req_col;
    reg  [5:0] req_row;
    reg        req_byte_hi;
    reg  [7:0] req_wdata;
    reg        req_served;     // this strobe has been satisfied already

    // Refresh
    reg [9:0]  ref_cnt;
    reg        ref_req;

    reg [7:0]  rdata_r;
    reg [15:0] dq_out;
    reg        dq_oe;
    reg        ready_r;

    wire       cpu_req = rd | wr;

    assign rdata = rdata_r;
    assign ready = ready_r;

    // Stall the CPU while a transaction is outstanding, or while a request is
    // pending but not yet served.
    assign busy = (cpu_req & ~req_served) | req_active;

    assign DRAM_DQ = dq_oe ? dq_out : 16'bz;

    // Read capture pipeline: data appears CAS_LATENCY clocks after the READ
    // command, plus one for the input register.
    reg [15:0] dq_in_r;
    always @(posedge clk) dq_in_r <= DRAM_DQ;

    task issue(input [3:0] cmd);
        begin
            DRAM_CS_N  <= cmd[3];
            DRAM_RAS_N <= cmd[2];
            DRAM_CAS_N <= cmd[1];
            DRAM_WE_N  <= cmd[0];
        end
    endtask

    // ---------------------------------------------------------------------
    // Refresh interval counter. Runs independently of the main FSM so a long
    // burst of CPU accesses cannot starve refresh.
    // ---------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ref_cnt <= 10'd0;
            ref_req <= 1'b0;
        end else begin
            if (ref_cnt >= T_REFRESH - 1) begin
                ref_cnt <= 10'd0;
                ref_req <= 1'b1;
            end else begin
                ref_cnt <= ref_cnt + 10'd1;
            end
            // Cleared by the FSM when the refresh is actually issued.
            if (state == S_REF) ref_req <= 1'b0;
        end
    end

    // ---------------------------------------------------------------------
    // Main FSM
    // ---------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_INIT_WAIT;
            wait_cnt     <= T_INIT;
            wait_next    <= S_INIT_PRE;
            DRAM_CKE     <= 1'b0;
            DRAM_ADDR    <= 13'd0;
            DRAM_BA      <= 2'd0;
            DRAM_DQM     <= 2'b11;
            issue(CMD_INHIBIT);
            dq_oe        <= 1'b0;
            dq_out       <= 16'd0;
            row_valid    <= 1'b0;
            open_row     <= 6'd0;
            req_active   <= 1'b0;
            req_served   <= 1'b0;
            req_is_write <= 1'b0;
            rdata_r      <= 8'hFF;
            ready_r      <= 1'b0;
        end else begin
            // Defaults every clock -- commands are single-cycle.
            issue(CMD_NOP);
            dq_oe <= 1'b0;

            // Clear the served flag once the CPU drops its strobe, so the next
            // cycle starts a fresh transaction.
            if (!cpu_req) req_served <= 1'b0;

            case (state)
            // ---- initialization -------------------------------------------
            S_INIT_WAIT: begin
                DRAM_CKE <= 1'b1;          // CKE high, NOP, for >= 100 us
                DRAM_DQM <= 2'b11;
                if (wait_cnt == 0) state <= wait_next;
                else               wait_cnt <= wait_cnt - 14'd1;
            end

            S_INIT_PRE: begin
                issue(CMD_PRECHARGE);
                DRAM_ADDR[10] <= 1'b1;     // A10 = 1 -> precharge ALL banks
                wait_cnt  <= T_RP;
                wait_next <= S_INIT_REF1;
                state     <= S_INIT_WAIT;
            end

            S_INIT_REF1: begin
                issue(CMD_REFRESH);
                wait_cnt  <= T_RC;
                wait_next <= S_INIT_REF2;
                state     <= S_INIT_WAIT;
            end

            S_INIT_REF2: begin
                issue(CMD_REFRESH);
                wait_cnt  <= T_RC;
                wait_next <= S_INIT_MRS;
                state     <= S_INIT_WAIT;
            end

            S_INIT_MRS: begin
                issue(CMD_LOADMODE);
                DRAM_BA   <= 2'b00;
                DRAM_ADDR <= MODE_REG;
                wait_cnt  <= T_MRD;
                wait_next <= S_IDLE;
                state     <= S_INIT_WAIT;
            end

            // ---- idle -----------------------------------------------------
            S_IDLE: begin
                ready_r  <= 1'b1;
                DRAM_DQM <= 2'b11;

                if (ref_req) begin
                    // Refresh takes priority. It requires all banks
                    // precharged, so the open row is closed here.
                    state <= row_valid ? S_REF_PRE : S_REF;
                end else if (cpu_req && !req_served && !req_active) begin
                    // Latch the request so it cannot change under us if the
                    // CPU's address settles late.
                    req_is_write <= wr;
                    req_col      <= col;
                    req_row      <= row;
                    req_byte_hi  <= byte_hi;
                    req_wdata    <= wdata;
                    req_active   <= 1'b1;

                    if (row_valid && open_row == row)
                        state <= wr ? S_WRITE : S_READ;   // row hit
                    else if (row_valid)
                        state <= S_PRE;                   // wrong row open
                    else
                        state <= S_ACT;
                end
            end

            // ---- row management -------------------------------------------
            S_PRE: begin
                issue(CMD_PRECHARGE);
                DRAM_BA       <= 2'b00;
                DRAM_ADDR[10] <= 1'b0;     // single bank
                row_valid     <= 1'b0;
                wait_cnt      <= T_RP;
                wait_next     <= S_ACT;
                state         <= S_INIT_WAIT;
            end

            S_ACT: begin
                issue(CMD_ACTIVE);
                DRAM_BA   <= 2'b00;
                DRAM_ADDR <= {7'd0, req_row};
                open_row  <= req_row;
                row_valid <= 1'b1;
                wait_cnt  <= T_RCD;
                wait_next <= req_is_write ? S_WRITE : S_READ;
                state     <= S_INIT_WAIT;
            end

            // ---- read -----------------------------------------------------
            S_READ: begin
                issue(CMD_READ);
                DRAM_BA   <= 2'b00;
                DRAM_ADDR <= {4'd0, req_col};
                DRAM_DQM  <= 2'b00;        // both bytes enabled for reads
                wait_cnt  <= T_RD_WAIT;
                wait_next <= S_READ_WAIT;
                state     <= S_INIT_WAIT;
            end

            S_READ_WAIT: begin
                // dq_in_r now holds the word; pick the addressed byte.
                rdata_r    <= req_byte_hi ? dq_in_r[15:8] : dq_in_r[7:0];
                req_active <= 1'b0;
                req_served <= 1'b1;
                state      <= S_IDLE;
            end

            // ---- write ----------------------------------------------------
            S_WRITE: begin
                issue(CMD_WRITE);
                DRAM_BA   <= 2'b00;
                DRAM_ADDR <= {4'd0, req_col};
                // Byte on both halves, then mask the one we do not want.
                // DQM is active HIGH: 1 masks that byte.
                dq_out    <= {req_wdata, req_wdata};
                dq_oe     <= 1'b1;
                DRAM_DQM  <= req_byte_hi ? 2'b01 : 2'b10;
                wait_cnt  <= T_WR;
                wait_next <= S_WRITE_WAIT;
                state     <= S_INIT_WAIT;
            end

            S_WRITE_WAIT: begin
                req_active <= 1'b0;
                req_served <= 1'b1;
                state      <= S_IDLE;
            end

            // ---- refresh --------------------------------------------------
            S_REF_PRE: begin
                issue(CMD_PRECHARGE);
                DRAM_ADDR[10] <= 1'b1;     // all banks
                row_valid     <= 1'b0;
                wait_cnt      <= T_RP;
                wait_next     <= S_REF;
                state         <= S_INIT_WAIT;
            end

            S_REF: begin
                issue(CMD_REFRESH);
                wait_cnt  <= T_RC;
                wait_next <= S_IDLE;
                state     <= S_INIT_WAIT;
            end

            default: state <= S_IDLE;
            endcase
        end
    end

endmodule
