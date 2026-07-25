// =========================================================================
// sdram_model -- behavioural IS42S16160 model with protocol checking
//
// SIMULATION ONLY. Deliberately strict: it is meant to catch controller bugs,
// so it reports an error on anything the datasheet forbids rather than
// quietly doing something reasonable.
//
// Checks:
//   - no command before CKE has been high for the initialization period
//   - PRECHARGE ALL, two AUTO REFRESH, LOAD MODE before any access
//   - READ/WRITE only to a bank with an open row, and to the row that is open
//   - ACTIVATE only on a precharged bank
//   - tRCD, tRP, tRC minimums
//   - AUTO REFRESH at least every 7.8125 us once initialized
//   - CAS latency honoured exactly: DQ is driven for one clock and then
//     released, so a controller that samples a clock late reads X
//
// -------------------------------------------------------------------------
// DRAM_CLK PHASE ASSUMPTION -- read this before trusting the read timing
//
//   The design drives DRAM_CLK as the INVERTED system clock, so the SDRAM's
//   edges fall in the middle of the controller's clock periods. With this
//   model driving read data across the interval (T+cl, T+cl+1) in SDRAM-clock
//   terms, the controller's own sampling edge lands in the CENTRE of that
//   window -- roughly 10 ns of setup and 10 ns of hold at 50 MHz.
//
//   That is the intent, and it is why the inverted clock is used at all. But
//   this model treats data as valid for a clean full period, whereas a real
//   part specifies tAC (access time, ~5.4 ns for a -7 grade) and tOH (output
//   hold). So simulation confirms the LOGIC -- address mapping, byte lanes,
//   row management, refresh, init order -- and NOT the electrical capture
//   point. Confirm that against the datasheet and TimeQuest, and treat
//   h8_sdram's T_RD_WAIT as the knob if the bench disagrees.
// -------------------------------------------------------------------------
// =========================================================================

`timescale 1ns/1ps

module sdram_model #(
    parameter T_CK_NS   = 20,      // clock period, for the refresh watchdog
    parameter T_RCD_CK  = 1,
    parameter T_RP_CK   = 1,
    parameter T_RC_CK   = 3,
    parameter INIT_NS   = 100000   // 100 us
) (
    input        dram_clk,
    input        cke,
    input        cs_n,
    input        ras_n,
    input        cas_n,
    input        we_n,
    input [12:0] addr,
    input  [1:0] ba,
    input  [1:0] dqm,
    inout [15:0] dq
);

    integer errors = 0;

    task err(input [8*70:1] msg);
        begin
            errors = errors + 1;
            $display("  SDRAM MODEL ERROR: %0s   (t=%0t)", msg, $time);
        end
    endtask

    // Only the low 64 KB window is modelled -- {row[5:0], col[8:0]}.
    reg [15:0] mem [0:32767];

    reg        initialized = 0;
    reg        mode_loaded = 0;
    reg  [2:0] init_step   = 0;    // 1 = precharge all seen, 2/3 = refreshes
    reg [12:0] mode_reg    = 0;
    integer    cl          = 2;

    reg        bank_active [0:3];
    reg [12:0] bank_row    [0:3];

    time       cke_high_since = 0;
    time       last_refresh   = 0;

    integer    since_act [0:3];    // clocks since ACTIVATE, for tRCD / tRC
    integer    since_pre [0:3];    // clocks since PRECHARGE, for tRP

    // Read return pipeline
    reg [15:0] rpipe_d [0:7];
    reg        rpipe_v [0:7];

    reg [15:0] dq_drive;
    reg        dq_en;
    assign dq = dq_en ? dq_drive : 16'bz;

    integer i;
    initial begin
        for (i = 0; i < 32768; i = i + 1) mem[i] = 16'h0000;
        for (i = 0; i < 4; i = i + 1) begin
            bank_active[i] = 0; bank_row[i] = 0;
            since_act[i] = 1000; since_pre[i] = 1000;
        end
        for (i = 0; i < 8; i = i + 1) begin rpipe_d[i] = 0; rpipe_v[i] = 0; end
        dq_en = 0; dq_drive = 0;
    end

    always @(posedge cke) cke_high_since = $time;

    wire [3:0] cmd = {cs_n, ras_n, cas_n, we_n};
    localparam NOP=4'b0111, ACT=4'b0011, RD=4'b0101, WR=4'b0100,
               PRE=4'b0010, REF=4'b0001, LMR=4'b0000;

    wire [14:0] flat_addr = {bank_row[ba][5:0], addr[8:0]};

    always @(posedge dram_clk) begin
        // ---- shift the read pipeline, stage 0 drives DQ ----
        dq_en    <= rpipe_v[0];
        dq_drive <= rpipe_d[0];
        for (i = 0; i < 7; i = i + 1) begin
            rpipe_d[i] <= rpipe_d[i+1];
            rpipe_v[i] <= rpipe_v[i+1];
        end
        rpipe_v[7] <= 0;

        for (i = 0; i < 4; i = i + 1) begin
            if (since_act[i] < 1000) since_act[i] <= since_act[i] + 1;
            if (since_pre[i] < 1000) since_pre[i] <= since_pre[i] + 1;
        end

        if (cke && cmd !== NOP && cs_n !== 1'b1) begin
            // ---- initialization gating ----
            if (!initialized && ($time - cke_high_since) < INIT_NS)
                err("command issued before the 100 us initialization wait");

            case (cmd)
            PRE: begin
                if (addr[10]) begin
                    for (i = 0; i < 4; i = i + 1) begin
                        bank_active[i] <= 0; since_pre[i] <= 0;
                    end
                    if (init_step == 0) init_step <= 1;
                end else begin
                    bank_active[ba] <= 0;
                    since_pre[ba]   <= 0;
                end
            end

            REF: begin
                if (init_step == 1)      init_step <= 2;
                else if (init_step == 2) init_step <= 3;
                for (i = 0; i < 4; i = i + 1)
                    if (bank_active[i])
                        err("AUTO REFRESH with a bank still active");
                last_refresh <= $time;
            end

            LMR: begin
                if (init_step != 3)
                    err("LOAD MODE before precharge-all and two refreshes");
                mode_reg    <= addr;
                mode_loaded <= 1;
                cl          <= addr[6:4];
                if (addr[2:0] !== 3'b000)
                    err("burst length is not 1 -- controller assumes BL1");
                if (addr[3] !== 1'b0)
                    err("burst type is not sequential");
                initialized <= 1;
                last_refresh <= $time;
            end

            ACT: begin
                if (!initialized) err("ACTIVATE before initialization completed");
                if (bank_active[ba]) err("ACTIVATE on a bank that is already active");
                if (since_pre[ba] < T_RP_CK) err("tRP violated: ACTIVATE too soon after PRECHARGE");
                if (since_act[ba] < T_RC_CK) err("tRC violated: ACTIVATE too soon after ACTIVATE");
                bank_active[ba] <= 1;
                bank_row[ba]    <= addr;
                since_act[ba]   <= 0;
            end

            RD: begin
                if (!initialized)     err("READ before initialization completed");
                if (!bank_active[ba]) err("READ with no open row in that bank");
                if (since_act[ba] < T_RCD_CK) err("tRCD violated: READ too soon after ACTIVATE");
                if (dqm !== 2'b00)    err("READ with DQM masking -- output would be disabled");
                // CAS latency: the READ is latched at edge T, and the data
                // must be VALID AT edge T+cl. Because stage 0 is registered
                // out to dq_en/dq_drive, loading index (cl-1) makes DQ driven
                // across the interval T+cl -> T+cl+1, which straddles the
                // controller's sampling edge (see the DRAM_CLK note below).
                // Loading index cl instead would place the data one full clock
                // late and the controller would sample high-Z.
                rpipe_d[cl-1] <= mem[flat_addr];
                rpipe_v[cl-1] <= 1;
            end

            WR: begin
                if (!initialized)     err("WRITE before initialization completed");
                if (!bank_active[ba]) err("WRITE with no open row in that bank");
                if (since_act[ba] < T_RCD_CK) err("tRCD violated: WRITE too soon after ACTIVATE");
                if (dqm === 2'b11)    err("WRITE with both bytes masked");
                if (^dq === 1'bx)     err("WRITE while DQ is not driven");
                if (!dqm[0]) mem[flat_addr][7:0]  <= dq[7:0];
                if (!dqm[1]) mem[flat_addr][15:8] <= dq[15:8];
            end

            default: ;
            endcase
        end
    end

    // ---- refresh watchdog ----
    // 8192 rows / 64 ms = 7.8125 us. Allow a little slack for the very first
    // interval after LOAD MODE.
    always @(posedge dram_clk)
        if (initialized && last_refresh != 0 &&
            ($time - last_refresh) > 8000)
            begin
                err("AUTO REFRESH interval exceeded 8 us");
                last_refresh <= $time;   // report once per lapse
            end

endmodule
