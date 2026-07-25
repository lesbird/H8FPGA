# H8FPGA — Stability & Performance Review

Review date: 2026-07-24
Reviewed commit: `4a71156` ("Update for V1.5 PCB")
Target: DE0-Nano, Cyclone IV E `EP4CE22F17C6`, Quartus Prime 22.1 Lite

Findings below are derived from a geometric netlist extraction of `H8FPGA.bdf`
(symbol port coordinates + connector endpoints + net labels), plus `H8FPGA.qsf`,
`Z80pa.vhd`, `H8FPGAROM.v`, and `H8FPGARAM.v`. Net and instance names quoted
here are the actual names in the schematic.

---

## Root cause

The design is a TTL schematic transcribed literally into an FPGA. Every technique
that made it work on a 1978 PCB — asynchronous ripple logic, tri-state buses, a
clock you can mux with a switch — is a reliability hazard on a Cyclone IV. The
instability isn't one bug; it's about a dozen instances of that one mismatch.

---

## Tier 0 — two `.qsf` lines, do these before anything else

### 0.1 82 assigned pins are absent from the top-level design

`H8FPGA.qsf` has 148 `set_location_assignment` entries; the top level of
`H8FPGA.bdf` declares 66 pins. The other 82 are *unused pins*, and Quartus's
default for those is **"as output driving ground."**

That currently includes:

- `GPIO_0[28..33]`, `GPIO_1[5,9,10,11,24,25]`, `GPIO_2[9..12]`,
  `GPIO_0_IN[0..1]`, `GPIO_1_IN[0..1]`, `GPIO_2_IN[0..2]` — 23 GPIO pins
  **actively pulling low through the '245s onto the H8 backplane**
- `EPCS_ASDO`, `EPCS_DATA0`, `EPCS_DCLK`, `EPCS_NCSO` — the configuration
  flash pins, driven as outputs
- all 39 `DRAM_*` pins, `I2C_*`, `LED[0..7]`, `KEY[0..1]`, `SW[0..3]`

Fix:

```tcl
set_global_assignment -name RESERVE_ALL_UNUSED_PINS "AS INPUT TRI-STATED WITH WEAK PULL-UP"
set_global_assignment -name RESERVE_ALL_UNUSED_PINS_NO_OUTPUT_GND "AS INPUT TRI-STATED WITH WEAK PULL-UP"
```

Given the PCB routes all 66 GPIO through level shifters onto the bus, this one
alone could account for a lot of flakiness.

### 0.2 There is no `.sdc` file in the project

The design is completely unconstrained. TimeQuest analyzes nothing, the fitter
optimizes for nothing, and every recompile produces a differently-timed machine.
There is no report that would tell you whether any path meets setup.

Create `H8FPGA.sdc`:

```tcl
create_clock -name CLOCK_50 -period 20.000 [get_ports CLOCK_50]
derive_pll_clocks
derive_clock_uncertainty

# H8 bus round-trip through the '245s is asynchronous — cut it, then handle
# it properly with synchronizers (see Tier 2)
set_false_path -from [get_ports {GPIO_1[*]}]
set_output_delay -clock CLOCK_50 -max 8 [get_ports {GPIO_0[*] GPIO_2[*]}]
set_output_delay -clock CLOCK_50 -min 0 [get_ports {GPIO_0[*] GPIO_2[*]}]
```

and register it:

```tcl
set_global_assignment -name SDC_FILE H8FPGA.sdc
```

---

## Tier 1 — the three architectural defects

### 1.1 The CPU clock is a combinational LUT mux driven by a raw DIP switch

`81mux/inst41` selects among the five PLL outputs; its `Y` output is net
`CLKOUT`, which feeds:

- `Z80pa/inst1.CLKIN`
- `H8FPGAROM/inst11.clock`
- `H8FPGARAM/inst12.clock`

Select lines `DIP41O`/`DIP42O`/`DIP43O` come straight off `GPIO_1[21..23]`
through `74541/inst35` — **no synchronization, no debounce**.

PLL outputs (`H8FPGAPLL`, inclk 20000 ps = 50 MHz):

| Output | Divide | Freq | Net |
|---|---|---|---|
| `c0` | 24 | 2.083 MHz | `CLK2MHZ` |
| `c1` | 12 | 4.17 MHz | `CLK4MHZ` |
| `c2` | 6 | 8.33 MHz | `CLK8MHZ` |
| `c3` | 2 | 25 MHz | `CLK25MHZ` |
| `c4` | 1 | 50 MHz | `CLK50MHZ` |

Consequences:

- The mux glitches whenever the switch is touched, and can glitch even when it
  isn't, since the PLL outputs are unrelated phases.
- The CPU clock is on general routing, not a global clock buffer, so skew across
  the ROM / RAM / core is unmanaged.
- **`D5`, `D6`, `D7` of the mux are unconnected.** Set the DIP to 5, 6, or 7 and
  the clock is undefined and the CPU dies.

**Fix — the reason to use T80pa in the first place.** T80pa is designed for
`CLK` = fast free-running clock plus `CEN_p` / `CEN_n` enable pulses; that's how
MiSTer drives it. `Z80pa.vhd:38-58` does not connect those ports at all (they
default to `'1'`, giving CLK/2) and passes no generic map, so a slow gated clock
is being driven into a core built specifically to avoid that.

Run everything at 50 MHz and generate enables instead:

```verilog
// h8_clkgen.v — one clock domain, no clock muxing, glitch-free speed change
module h8_clkgen (
    input        clk50,          // CLOCK_50 direct, on a global buffer
    input        rst_n,
    input  [2:0] speed_sel,      // already synchronized + debounced
    output reg   cen_p,          // T80pa CEN_p
    output reg   cen_n,          // T80pa CEN_n
    output reg   phi             // bus clock, phase-locked to the T-states
);
    // divisor for a 2.048 MHz Z80: 50e6 / (2.048e6 * 2) ~= 12
    reg [4:0] div, cnt;
    always @(*) case (speed_sel)
        3'd0: div = 5'd12;   // ~2.08 MHz
        3'd1: div = 5'd6;    // ~4.17 MHz
        3'd2: div = 5'd3;    // ~8.33 MHz
        default: div = 5'd12; // never undefined — unlike 81mux D5..D7
    endcase

    always @(posedge clk50 or negedge rst_n)
        if (!rst_n) begin cnt <= 0; phi <= 0; cen_p <= 0; cen_n <= 0; end
        else begin
            cen_p <= 1'b0; cen_n <= 1'b0;
            if (cnt >= div - 1) begin
                cnt <= 0;
                phi <= ~phi;
                if (!phi) cen_p <= 1'b1; else cen_n <= 1'b1;
            end else cnt <= cnt + 1'b1;
        end
endmodule
```

`Z80pa.vhd` then passes `CEN_p`/`CEN_n` through, `CLK` becomes `clk50`, and `phi`
drives `BUSSCLK`. Changing speed becomes a divisor change — the clock never
glitches, ROM/RAM/CPU are permanently in one domain, and `derive_pll_clocks` can
actually constrain it.

This also removes the **second** combinational clock mux: `21mux/inst36`
(select = `DIP44O`) currently picks between `CLK2MHZ` and `CLKOUT` for the bus
clock (`BUSSCLK` → `NOT/inst60` → `GPIO_0[22]`), so the backplane clock and the
CPU clock can be unrelated free-running signals. With the above, `phi` derives
from the same counter as the T-states — genuinely phase-coherent, which is what a
real CPU card provides.

> **Verify on the schematic:** `74541/inst35.A1` appears to share a node with the
> `GND` symbol that drives `GN1`/`GN2`, and `A1` produces `DIP44O` (Y1). If that's
> a real short rather than an extraction artifact, DIP4-1 is stuck and the
> bus-clock select never works.

### 1.2 `Z80IN[7:0]` is an internal tri-state bus with five drivers

Cyclone IV has no internal tri-state resources. Quartus flattens this to a mux,
but nothing enforces one-hot and nothing defines the value when all five enables
are inactive.

| Driver | Enable net | Source |
|---|---|---|
| `74540/inst10` | `-DATAI` | H8 bus data |
| `74540/inst17` | `-INTA` | interrupt vector |
| `74541/inst13` | `-ROMEN` | ROM |
| `74541/inst14` | `-RAMRDEN` | RAM |
| `74541/inst47` | `-IOR362` | ORG-0 port |

All five enables are deep combinational decodes — `7430/inst16` is an 8-input
NAND on `-A12..-A15` + `MEMR`; `7430/inst46` is an 8-input NAND on `-A0..Z80ADR[7]`.
They glitch on every address transition, and overlap windows during decode are
unavoidable.

**Fix — one explicit priority mux with a defined default:**

```verilog
always @(*) begin
    if      (!intack_n) z80_di = int_vector;
    else if (!rom_en)   z80_di = rom_q;
    else if (!ram_rd)   z80_di = ram_q;
    else if (!org0_rd)  z80_di = org0_status;
    else if (!data_in)  z80_di = bus_d_sync;
    else                z80_di = 8'hFF;   // idle bus reads FF, like real hardware
end
```

The `8'hFF` default matters: on a real H8 backplane an unclaimed read returns
`FF` from the bus pull-ups. Today an unclaimed read returns whatever Quartus's
tri-state conversion produced — neither `FF` nor reproducible between builds.

### 1.4 The ORG-0 ROM disable never worked

Found while porting the schematic to Verilog. This is the one that blocks HDOS
and CP/M.

Writing port 0362 latched `7474/inst37`, and `1Q` became `-ROMDIS` (via
`NAND2/inst45` wired as an inverter). But `-ROMDIS` only fed `ROMRDEN`:

```
ROMRDEN = ~(ROMEN_active & 1Q)      -> H8FPGAROM/inst11.rden
```

Dropping `altsyncram`'s `rden` merely **freezes its output register** — it does
not tri-state anything. Meanwhile the buffer that actually drove data onto
`Z80IN`, `74541/inst13`, was enabled by `-ROMEN` alone, with no `-ROMDIS` term.
And RAM could not answer either, because `MEMOK` excluded any cycle where
`-ROMEN` was active.

So with the ROM "disabled", reads of `0x0000-0x0FFF` returned **stale frozen ROM
data**, and the RAM underneath was unreachable. Since the entire purpose of the
HA8-8 ORG-0 board is to put RAM at low addresses so HDOS and CP/M can boot, the
feature never functioned.

Fix: `rom_dis` now removes ROM from the read priority mux so RAM falls through;
`rden` is tied high and plays no part in selection. See `RTL/h8_memmap.v` and
the `tb_units` check *"rom_dis: 0x0000 reads RAM, not stale ROM"*.

## 1.5 GPIO_1[20] is shorted to an internal GND

`74541/inst35.A1`, its `GN1`/`GN2` enables, `GND/inst40` and the pin
`GPIO_1[20]` all share one net. Two consequences:

- `GPIO_1[20]` is a bidir pin driven low by the FPGA, against the '245 that
  drives *into* it from the DIP4 switch. **Direct pin contention.**
- `DIP44O` (= `Y1` = `A1`) is stuck at 0, so `21mux/inst36` always selected
  `CLK2MHZ` and the DIP4-1 "send selected speed to the bus" function never
  worked.

This looks like a dropped wire in the schematic — the GND intended for the
buffer's enables landed on the switch input net as well. Fixed by making
`GPIO_1[20]` a plain input in the Verilog top.

## 1.3 Reset is asynchronous and unsynchronized

`-RESIN` arrives from the bus via `74541/inst33.Y8` and goes **directly** to
`Z80pa/inst1.RESET_n` and to both `7474/inst37` clear inputs (`1CLRN`, `2CLRN`),
with no synchronizer, no debounce, and no minimum-pulse stretch.

T80 is a deep pipelined core; releasing reset asynchronously mid-cycle lets
different stages exit reset on different clocks. Textbook cause of "boots fine
most of the time, occasionally comes up dead."

```verilog
// async assert, synchronous release, stretched to cover the slowest CEN period
reg [1:0] rst_meta;
reg [7:0] rst_cnt;
wire      rst_n_out = (rst_cnt == 8'hFF);
always @(posedge clk50 or negedge resin_n) begin
    if (!resin_n) begin rst_meta <= 2'b00; rst_cnt <= 8'h00; end
    else begin
        rst_meta <= {rst_meta[0], 1'b1};
        if (rst_meta[1] && rst_cnt != 8'hFF) rst_cnt <= rst_cnt + 1'b1;
    end
end
```

Note also that `-RESIN` is re-driven back out on `GPIO_0[16]` — reflecting an
unsynchronized reset onto the backplane. Drive the bus reset from the
synchronized version instead.

---

## Tier 2 — the H8 bus interface

### 2.1 No synchronizers on any bus input

Every signal crossing from the backplane goes straight into logic:

- `-INT1..-INT7` (from `74541/inst33`) → `74148/inst15` priority encoder →
  `GSN` → `Z80pa/inst1.INT_n`, unregistered. A bus interrupt changing during an
  M1 cycle can glitch `INT_n` mid-acknowledge.
- Bus data `GPIO_1[12..19]` → `74540/inst10` → `Z80IN` → CPU `DI`, unregistered
  the whole way.

> **Correction to an earlier draft of this document:** `MEMOK` was described here
> as an asynchronous backplane signal gating the RAM write enable. That is wrong.
> `NAND3/inst64` has inputs `-ROMEN`, `-DATAO`, `-DATAI` — all internally
> generated — so `MEMOK = -ROMEN AND -DATAO AND -DATAI` and it never touches a
> pin. It is a local interlock meaning "not a ROM cycle and not an I/O cycle, so
> the RAM may respond," and it is what stops ROM and RAM both enabling onto
> `Z80IN` in `0x0000-0x0FFF`. It is still a defect — a combinational interlock
> built from unequal-delay paths feeding the synchronous
> `H8FPGARAM/inst12.wren` — but the failure mode is glitch susceptibility on
> decode transitions, not metastability. The Tier 1.2 priority mux removes it
> entirely. See also 5.2.

Every one of these needs a two-flop synchronizer on `clk50` before it touches
anything. For the interrupt lines, synchronize the seven inputs **then**
priority-encode — never the other way around.

### 2.2 The '245 direction and the FPGA output enable have no dead time

- `-DATAI` (`GPIO_0[26]`, drives the external transceiver DIR) ← `NAND2/inst25`,
  fed by `IOR` and `-ORG0SEL`
- `-DATAO` (the FPGA's internal OE, `74540/inst9.GN1/GN2`) ← `NAND2/inst24`,
  fed by `IOW` and `-ORG0SEL`

Two different gates, two different propagation delays, no guaranteed
non-overlap. On every data-bus turnaround there is a window where the FPGA and
the H8 card both drive the same 3.3 V node through the transceiver. Intermittent
corruption at best.

**Fix:** register both from a small turnaround FSM in the `clk50` domain, with at
least 2–3 clocks of dead time where the FPGA OE is off *and* DIR points inward
before either direction asserts. At 50 MHz that's 40–60 ns of guard band — free,
and it makes the turnaround deterministic.

See also 2.5 — the direction signal has the wrong *default*, which is a separate
and more serious problem than the missing dead time.

## 2.5 The '245 direction defaults to driving the H8 data bus

`-DATAI` drives `GPIO_0[26]` directly, and per `README.md` that pin sets the
bidirectional '245's direction: **low = input from bus, high = output to bus**.

`-DATAI` = `NAND2/inst25(IOR, -ORG0SEL)`, so it is asserted low **only during
non-ORG-0 I/O reads**. Therefore `GPIO_0[26]` is high — transceiver pointing
outward, driving the backplane — during every memory cycle and every idle cycle.

During those same cycles `74540/inst9` (the FPGA's data-out buffer, enabled by
`-DATAO`, active only on I/O writes) is disabled, so `GPIO_1[12..19]` are
floating FPGA inputs. The '245 amplifies those floating levels onto the H8 data
bus.

Net effect: **the board injects indeterminate levels onto the H8 data bus the
large majority of the time.** It functions today only because nothing else
contends when no memory cards are installed — consistent with "works, but not
very stable."

Fix — invert the default so the transceiver points inward unless the FPGA is
actually sourcing data:

```verilog
// GPIO_0[26]: assert outward ONLY when we are actually driving the bus
assign dram_dir_out = iow_active & ~org0_sel;   // registered, dead time per 2.2
```

**Confirm before acting:** check the '245 DIR polarity against the PCB schematic
rather than the README prose, and note that "pin 26 of GPIO-0" in the README may
mean header pin 26 rather than signal `GPIO_0[26]`.

Empirical check: scope an H8 data bus line while running a memory-only loop with
no cards installed. Activity that no card is producing confirms the diagnosis.

### 2.3 `WAIT_n`, `NMI_n`, and `BUSRQ_n` are unconnected

`Z80pa/inst1.WAIT_n`, `.NMI_n`, and `.BUSRQ_n` all sit on dangling nets. There is
**no path for an H8 card to request a wait state.**

This is why the H8-4 serial card and the H17 controller are still on the TO-DO
list. Real H8 peripherals need wait states; without them the design is locked to
whatever speed happens to satisfy the slowest card by luck.

Wire the backplane's wait/hold line in through a synchronizer to `WAIT_n`, and —
separately — add programmable wait states for off-board I/O so the core can run
fast while bus cycles stay at H8 timing. This is the change that unlocks
"run at 8/25 MHz *and* talk to real cards."

### 2.4 Register the bus outputs in the I/O cells

Address and control come combinationally off the core to the pins, so
inter-signal skew is whatever the fitter picked that day.

```tcl
set_instance_assignment -name FAST_OUTPUT_REGISTER ON -to "GPIO_0[*]"
set_instance_assignment -name FAST_INPUT_REGISTER  ON -to "GPIO_1[*]"
```

With matched drive strength this gives the backplane a clean, aligned set of
transitions instead of a staggered ripple.

---

## Tier 3 — cleanup

Dead logic currently in the schematic. All of it produces warnings that mask real
ones:

- **`T80s/inst76` — an entire second CPU instance with every port dangling.**
  Delete it and drop `COMPONENTS/T80/T80s.vhd` from the `.qsf`.
- `-LOW8K` (`OR2/inst71`) — output drives nothing
- `NAND2/inst20`, `NAND2/inst21` — outputs drive nothing
- `RESET` (`74540/inst4.YN6`) — buffered but unused
- `7474/inst37` `1Q` / `2Q` — dangling
- `74541/inst35` `A5..A8` — dangling inputs
- `81mux/inst41` `D5` / `D6` / `D7` — dangling (see 1.1)
- `74148/inst15.EON` — dangling
- `74540/inst4` `A7`/`A8` and `YN7`/`YN8` — unused slices

### Memory latency

`H8FPGAROM.v` and `H8FPGARAM.v` both set `outdata_reg_a = "CLOCK0"`, giving two
clocks of read latency on the same clock as the CPU. That works today purely by
edge-count coincidence. Under the CEN architecture, clock the memories on
`clk50` and the latency becomes 40 ns — invisible inside a T-state, and it stops
being something that breaks when the speed changes.

Current memory config:

| | Words | Width | Init | Notes |
|---|---|---|---|---|
| `H8FPGAROM` | 4096 | 8 | `COMPONENTS/ROMS/2732_XCON8.HEX` | `outdata_reg_a = CLOCK0` |
| `H8FPGARAM` | 32768 | 8 | — | `read_during_write_mode_port_a = NEW_DATA_NO_NBE_READ` |

---

## Suggested order

1. `.qsf` unused-pin reservation + add the `.sdc` — ~15 min. Re-read the fitter
   warnings afterward; they'll be meaningful for the first time.
2. Delete the dead logic so the warning list is clean.
3. Clock-enable architecture (`h8_clkgen` + `CEN_p`/`CEN_n` in `Z80pa.vhd`) —
   removes both clock muxes.
4. Reset synchronizer.
5. `Z80IN` priority mux with `FF` default.
6. Input synchronizers, especially `MEMOK` before it reaches `wren`.
7. Registered '245 turnaround with dead time.
8. `WAIT_n` + programmable I/O wait states → then H8-4 and H17 become tractable.

---

## Broader recommendation

Steps 3–7 are painful to draw in BDF and easy to write in Verilog. Keep
`H8FPGA.bdf` as a thin top level (pins + the T80pa instance + memories) and move
all the glue into one `h8_glue.v`. That buys code review, version-controllable
diffs, and simulation — the only way to be confident about bus turnaround timing
without an H8 on the bench.

---

## PCB constraints this must respect

From `README.md` and the pin assignments:

- GPIO-0 (left 5 '245s) = fixed **outputs** to the H8 bus
- GPIO-1 (right 5 '245s) = fixed **inputs** from the bus, except `GPIO_1[12..19]`,
  the bidirectional data byte
- Bidirectional '245 direction = `GPIO_0[26]` (`-DATAI`); low = input from bus,
  high = output to bus
- DIP4 (speed / bus-clock select) on `GPIO_1[20..23]`
- DIP8 (HA8-8 ORG-0 status byte) on `GPIO_1[26..33]`
- LED bar graph available for debug

Implication: the FPGA must never drive any GPIO-1 pin except `[12..19]`, and must
not drive unused GPIO-0 pins that land on live bus signals — which is exactly
what Tier 0.1 fixes.

---

# Tier 4 — Moving RAM to the onboard SDRAM

Addresses the README TO-DO item: *"Get it working with the DE0-NANO 32MB SDRAM
instead of on-chip RAM so can have a 4K ROM and 64K of RAM."*

**Verdict: yes to 64K of RAM in SDRAM — comfortable fit with large timing
margin. No to putting the ROM there.**

**Depends on Tier 1.1** (the `CEN_p`/`CEN_n` clock-enable rework). Do that first;
see 4.4.

## 4.1 Why the ROM should stay in M9K

1. **SDRAM is volatile.** The CPU fetches from `0x0000` the instant it leaves
   reset, so contents must already be present. You'd need a boot loader pulling
   the image out of the EPCS config flash into SDRAM before releasing the Z80 —
   an entire extra subsystem replacing something `altsyncram` does for free via
   `init_file`.
2. **The ROM costs almost nothing.** 4096 x 8 = 4 M9K blocks out of 66 (6%).
3. **It's the only latency-free memory on the chip.** M9K reads are
   single-cycle. Fast monitor-ROM instruction fetch is worth more than the
   blocks it costs.

Correct split: **ROM in M9K, all 64K of RAM in SDRAM.**

## 4.2 The arithmetic behind the README's claim

The claim is correct, and only barely:

- EP4CE22F17C6 has 66 M9K blocks (594 Kbit total)
- In x8 mode an M9K yields 1024 bytes — the extra 1024 bits per block are
  parity, reachable only in x9 mode
- 64 KB RAM = 64 blocks, 4 KB ROM = 4 blocks → **68 needed, 66 available**

Short by exactly 2 blocks. Current design uses 36 (32 RAM + 4 ROM). Move RAM to
SDRAM and it drops to 4 of 66, leaving 62 blocks free.

## 4.3 What the SDRAM gives you

DE0-Nano SDRAM: 32 MB, 16-bit, 4 banks, IS42S16160 family. **Confirm the exact
part and speed grade for your board revision** — some are IS42S16320. The
`DRAM_*` pins are already assigned in `H8FPGA.qsf` and are dedicated, not shared
with GPIO.

Latency at 50 MHz, CL2: a full activate → read → precharge is roughly 7 clocks
≈ **140 ns**. A 2 MHz Z80 memory cycle is 3 T-states ≈ **1.5 µs**. Roughly 10x
margin. Even at 25 MHz Z80 (~120 ns per M-cycle) it is workable if rows are kept
open. Bandwidth is a non-issue: one byte per 1.5 µs against a ~100 MB/s
interface.

**Run the SDRAM at 50 MHz, in the same domain as the CPU.** MiSTer cores use
100+ MHz because they are feeding video; this design feeds one Z80. A single
50 MHz domain means no CDC, no dual-clock FIFO, and a design that can actually
be constrained.

## 4.4 Prerequisite: Tier 1.1 becomes mandatory

SDRAM cannot be cleanly bolted onto a CPU whose clock is a combinational mux
(`81mux/inst41`). The controller must live in one fixed, constrained clock
domain, and the CPU must be stallable while a transaction completes. Both are
exactly what the `CEN_p`/`CEN_n` architecture provides.

Order: clock-enable rework, *then* SDRAM. Doing SDRAM first builds on a
foundation that is about to be replaced.

## 4.5 Stall mechanism — gate CEN, do not use WAIT_n

Two options:

- **`WAIT_n`** — currently dangling on `Z80pa/inst1` (see 2.3). Also
  `T80pa.vhd`'s own header notes *"WAIT_n is broken in T80.vhd. Simulate correct
  WAIT_n locally"*, so the semantics live in the wrapper and are subtle.
- **Gate the clock enables** — hold `cen_p`/`cen_n` low until the SDRAM returns.
  The core simply does not advance. No wait-state semantics to get right, no
  interaction with the core's internal M-cycle tracking.

Use the second. One-line change to `h8_clkgen` (1.1):

```verilog
wire cen_p_gated = cen_p & ~mem_busy;
wire cen_n_gated = cen_n & ~mem_busy;
```

This is a *different* problem from the H8 bus wait states in 2.3 — external
cards still need real `WAIT_n`. CEN gating covers internal memory latency only.

## 4.6 Controller

Do **not** use Terasic's FIFO-based demo controller (`Sdram_Control` from the
DE0-Nano CD) — it is built for streaming, and this access pattern is single
random bytes. Do not pull in MiSTer's `sdram.sv` either; it is tuned for a
different pattern at a different frequency.

A purpose-built controller for "one random byte, latency-tolerant, low
bandwidth" is the easiest possible case:

```verilog
module h8_sdram (
    input             clk,        // 50 MHz, same as CPU domain
    input             rst_n,
    // CPU side
    input      [15:0] addr,       // Z80 A[15:0]
    input      [7:0]  wdata,
    input             rd, wr,     // single-cycle strobes
    output reg [7:0]  rdata,
    output reg        busy,       // gates cen_p/cen_n
    // SDRAM pins
    output reg [12:0] DRAM_ADDR,
    output reg [1:0]  DRAM_BA,
    output reg [1:0]  DRAM_DQM,
    output reg        DRAM_CAS_N, DRAM_RAS_N, DRAM_WE_N, DRAM_CS_N, DRAM_CKE,
    inout      [15:0] DRAM_DQ
);
    // 64KB window = 32K 16-bit words. Bank 0, row = A[15:10], col = A[9:1].
    // A[0] picks the byte within the word via DQM on writes / mux on reads.
    // Whole 64K lives in one bank so a row stays open across sequential fetches.

    // States: INIT_WAIT(100us) -> PRECHARGE_ALL -> REFRESH x2 -> LOAD_MODE
    //         -> IDLE -> ACTIVATE -> READ/WRITE -> (CL2) -> PRECHARGE
    //         -> REFRESH (every 7.8125us = 390 clks @ 50MHz)
endmodule
```

Sketch only — exact tRCD / tRP / tRC clock counts must come from the datasheet
for the speed grade on your board.

Four things needing care:

1. **Init sequence** — 100 µs idle after configuration, then PRECHARGE ALL, two
   AUTO REFRESH, LOAD MODE REGISTER (CL2, burst length 1, sequential). Hold the
   Z80 in reset until this completes; hook into the reset synchronizer from 1.3.
2. **Refresh** — 8192 rows / 64 ms = one AUTO REFRESH every 7.8125 µs, i.e.
   every 390 clocks at 50 MHz. A refresh costs ~7 clocks. Arbitrate: service
   refresh when the CPU is idle; if the CPU requests mid-refresh, stall via
   `busy`. (`Z80pa.RFSH_n` is dangling and can stay that way — the controller
   does its own refresh.)
3. **`DRAM_CLK` phase** — drive from a dedicated phase-shifted PLL output, not
   from logic. The SDRAM must see the clock at the right offset relative to when
   the controller drives address/data; typically 180° or a tuned ns offset. Set
   up in the PLL megawizard, then **verify with an SDC** —
   `set_output_delay` / `set_input_delay` on the `DRAM_*` pins. Another place
   the missing `.sdc` (0.2) bites.
4. **Byte lanes** — `A[0]` selects. Reads: mux the DQ half. Writes: assert the
   opposite `DQM` bit to mask.

## 4.7 Bonus: the memory map gets simpler

Current ROM-vs-RAM decode is tangled — `7430/inst16` decoding `-A12..-A15` +
`MEMR` for `-ROMEN`, `NAND3/inst55`/`inst56` for the RAM enables, and a
`-ROMDIS` path for the ORG-0 remap.

With the full 64K in SDRAM, RAM is *always* present underneath the whole address
space, so ROM shadowing collapses to one term in the read mux already being
built for `Z80IN` (1.2):

```verilog
wire rom_visible = !rom_disable && (addr[15:12] == 4'h0);
```

That makes the ORG-0 ROM-disable remap nearly free — exactly what HDOS and CP/M
need at low addresses.

Also decide what `MEMOK` means afterwards. It currently gates the RAM enables,
asynchronously (see 2.1). With all 64K internal, either drop external memory
entirely or keep `MEMOK` as a way for a bus card to override a region.

## 4.8 What to do with the other 31.9 MB

Relevant to the remaining TO-DO items: an H17 hard-sector disk is 40 tracks x 10
sectors x 256 bytes ≈ 100 KB per side, so 32 MB holds 300+ disk images. That
makes SDRAM a natural backing store for H17 emulation.

Being volatile, images would need loading from the EPCS64 config flash (roughly
6 MB free after the bitstream) or from an SD card added to a GPIO header — the
DE0-Nano has no card slot.

## 4.9 Effort estimate

| Step | Scope |
|---|---|
| Clock-enable rework (prerequisite) | Tier 1.1 |
| SDRAM controller | ~200 lines Verilog, ~200 LEs |
| PLL: add phase-shifted DRAM clock output | megawizard regen |
| SDC for the DRAM interface | ~15 lines |
| Memory map / read-mux integration | replaces the tri-state mess in 1.2 |
| Simulation | worth doing properly — the one part you do not want to debug on the bench |

The controller itself is the easy part. The real work is the clock-domain rework
it sits on, which needed doing anyway.

---

# Tier 5 — Dropping external RAM support

Decision: with the full 64K in SDRAM (Tier 4), the design no longer supports
memory on the H8 backplane. I/O still goes to the bus; memory does not.

## 5.1 It is already effectively dropped

Tracing the data-in path: `-DATAI` enables `74540/inst10`, the only buffer that
puts backplane data onto `Z80IN`. `-DATAI` = `NAND2/inst25(IOR, -ORG0SEL)`, so
that buffer is enabled **only for I/O reads**. A memory read never takes data
from the bus.

And `NAND3/inst55` / `NAND3/inst56` both carry `-A15` as a term, so the on-chip
RAM answers only `0x0000-0x7FFF`. Above `0x8000` nothing drives `Z80IN` at all —
that is the origin of the 32K ceiling, and reads up there return whatever the
tri-state collapse in 1.2 happens to produce.

So this work is mostly deleting logic that exists to *limit* the internal RAM,
not logic that supports external RAM.

## 5.2 What gets deleted

| Element | Role today |
|---|---|
| `NAND3/inst55` | `-RAMWREN` = `MEMW AND MEMOK AND -A15` |
| `NAND3/inst56` | `-RAMRDEN` = `MEMR AND MEMOK AND -A15` |
| `NAND3/inst64` | `-MEMOK` = `NAND(-ROMEN, -DATAO, -DATAI)` |
| `NOT/inst65` | `MEMOK` |
| `NOT/inst22` | `RAMWREN` |
| `NOT/inst23` | `RAMRDEN` |
| the `-A15` term | the 32K ceiling |

Memory decode collapses to:

```verilog
wire rom_sel = memr && rom_visible;          // 0x0000-0x0FFF, ORG-0 gated
wire ram_sel = (memr || memw) && !rom_sel;   // everything else, full 64K
```

The `MEMOK` interlock is no longer needed because the Tier 1.2 priority mux makes
ROM-over-RAM precedence explicit rather than an emergent property of a
combinational interlock.

## 5.3 This makes 2.5 mandatory, not optional

Dropping external RAM means the FPGA will never need to read memory from the
backplane — so the transceiver's resting direction should be **inward**, always,
except when the FPGA is actively sourcing data during an I/O write.

Section 2.5 documents that the direction currently rests **outward**, driving
floating FPGA pin levels onto the H8 data bus during every memory and idle cycle.
Fix 2.5 as part of this work. Once fixed, an installed memory card responding to
`MEMR` is harmless — it drives the bus, and the FPGA simply ignores it.

## 5.4 Keep driving MEMR / MEMW to the bus

Recommend **against** removing `MEMR` (`GPIO_0[17]`) and `MEMW` (`GPIO_0[21]`):

- a real H8 CPU card drives them
- they cost nothing
- they are invaluable on a logic analyzer
- with 2.5 fixed there is no contention risk even if a RAM card is installed
- they are needed again if memory-mapped cards are ever re-enabled

## 5.5 Optional escape hatch

`SW[0..3]` and `LED[0..7]` are assigned in `H8FPGA.qsf` but absent from the
design (part of the 82 unused pins in 0.1). Wiring one onboard slide switch to an
"allow external memory" bit preserves the option at no cost.

DIP8 cannot be used for this — all eight bits are consumed by the HA8-8 ORG-0
status byte.

---

# Implementation log

Branch: `stability-rework`. Integration approach: full Verilog top level;
`H8FPGA.bdf` retained on disk as a reference but removed from the build.

## Done

| Item | Where |
|---|---|
| 0.1 unused-pin reservation | `H8FPGA.qsf` |
| 0.2 timing constraints | `H8FPGA.sdc` (new) |
| 1.1 clock mux -> clock enables | `RTL/h8_clkgen.v` |
| 1.2 tri-state read bus -> priority mux | `RTL/h8_memmap.v` |
| 1.3 reset synchronizer / stretch / debounce | `RTL/h8_reset.v` |
| 1.4 ORG-0 ROM disable | `RTL/h8_memmap.v`, `RTL/h8_org0.v` |
| 1.5 GPIO_1[20] short | `RTL/h8fpga_top.v` |
| 2.1 input synchronizers | `RTL/h8_sync.v`, `RTL/h8_intctl.v` |
| 2.2 turnaround guard band | `RTL/h8_busif.v` |
| 2.4 registered bus outputs | `RTL/h8fpga_top.v` |
| 2.5 '245 direction default | `RTL/h8_busif.v` |
| 3 dead logic removed | not carried over from the BDF |
| 4 64K of RAM in SDRAM | `RTL/h8_sdram.v`, `RTL/h8fpga_top.v` |
| 5 external RAM support dropped | `RTL/h8_memmap.v` |

Dead logic that simply does not exist in the Verilog: `T80s/inst76` (a whole
second CPU with every port dangling), `-LOW8K`, `NAND2/inst20`, `NAND2/inst21`,
the unused `RESET` buffer, `74148/inst15.EON`, `7474/inst37`'s second flop
outputs, `74541/inst35.A5..A8`, `81mux` `D5`/`D6`/`D7`, and the whole
`MEMOK`/`-MEMOK` interlock.

`T80s.vhd` and `Z80pa.vhd` are dropped from the `.qsf`. `H8FPGAPLL` is retained
but no longer instantiated — the design runs directly off the 50 MHz oscillator
now, and Tier 4 needs the PLL back for the phase-shifted DRAM clock.

## Verification

`SIM/` — Icarus Verilog. `make units`, `make top`, `make mutate`.

- **56 unit checks** across all six rework modules
- **16 top-level checks** using a scripted CPU stub (`SIM/stubs.v`)
- **4 mutation checks** — each reintroduces one original defect and must be
  reported as a failure, proving the tests are not vacuous

`SIM/stubs.v` deliberately shadows `T80pa`, `H8FPGAROM` and `H8FPGARAM` so
Icarus can elaborate the design without a VHDL simulator or Altera libraries.
**It must never be added to `H8FPGA.qsf`.**

What the simulation does NOT cover: the real T80pa core (VHDL, not visible to
Icarus), so this proves wiring, polarity, memory-map routing, ORG-0 behaviour
and turnaround sequencing — not Z80 correctness. Nor has anything been through
Quartus.

## Open

- **2.3 WAIT_n is still tied high.** T80pa's `WAIT_n` *is* functional — sampled
  at T2, stalls via `CEN_pol` (`T80pa.vhd:172`) — so wiring it is viable. What
  is missing is which backplane pin carries the H8 wait/hold line.
  `GPIO_1[5,9,10,11,24,25]` are the unused candidates; identifying the right one
  needs the PCB schematic. Until then no card can insert wait states, which is
  why the H8-4 and H17 do not work.
- **`FAST_OUTPUT_REGISTER` / `FAST_INPUT_REGISTER` not yet enabled.** The
  outputs are registered now (2.4), so these will finally pack. Add them once a
  Quartus run confirms the design compiles.
- **Will T80 close timing at 50 MHz on an EP4CE22C6?** Unknown until Quartus
  runs. T80 typically manages 50-60 MHz on Cyclone IV, so it is plausible but
  not certain. If it does not close, the remedy is easy: bring back the PLL,
  clock the design at 25 MHz, and halve every divisor in `h8_clkgen`
  (12 -> 6 for 2.083 MHz). This is exactly the question 0.2 exists to answer.
- **`H8FPGA.sdc` PLL clock-name patterns are guesses.** With the PLL no longer
  instantiated the `set_clock_groups` block will simply post its warning and
  skip; harmless, and it becomes relevant again at Tier 4.
- **2.5 needs a hardware confirmation** before being called fixed: check the
  '245 DIR polarity against the PCB schematic, and whether "pin 26 of GPIO-0"
  means the signal or the header pin.
## Tier 4 status: implemented

`RTL/h8_sdram.v` -- single-byte random-access controller, 50 MHz, same clock
domain as the CPU. Open-row caching (1 KB per row) so sequential fetches skip
ACTIVATE/PRECHARGE: 4 clocks on a row hit versus 9 on a miss.

Integration in `h8fpga_top`:

| | |
|---|---|
| `USE_SDRAM` parameter | 1 = 64K in SDRAM, 0 = original 32K M9K fallback |
| `RAM_FULL_64K` | now driven from `USE_SDRAM` |
| `h8_clkgen.stall` | driven from `sdram_busy` (review 4.5) |
| CPU reset | `rst_n_cpu = rst_n & sdram_ready` |
| `DRAM_CLK` | `~clk` (see below) |

**The `ready` deadlock.** `h8_reset` has a `ready` input intended for this, but
wiring it to `sdram_ready` deadlocks -- the controller needs a reset to run its
init, and gating that reset on the ready it produces means init never starts.
So the system reset is ungated and the CPU gets a separate `rst_n_cpu`. The
simulation confirms it: the SDRAM run takes 119 us versus 14 us for the M9K
fallback, and the difference is the CPU genuinely waiting out initialization.

**The fallback is deliberate.** Keeping `USE_SDRAM=0` working means bring-up can
isolate "is it the SDRAM or is it the rest of the rework?", and you always have
a machine to debug from. Both configurations produce byte-identical read traces
in simulation (`a0 ff a0 ff 77 ff 5a ff 99`); if they ever diverge, the SDRAM
backend is not a drop-in.

### DRAM_CLK: what was done and what was not

`DRAM_CLK = ~clk`. This puts the SDRAM's edges mid-period so read data straddles
the controller's sampling edge with roughly 10 ns of setup and hold at 50 MHz,
and the clock and data pin delays largely cancel since both leave through
comparable output paths. For a -7 part (tSU ~1.5 ns) that is comfortable.

This is **not** a properly phase-compensated DRAM clock. Above roughly 75 MHz
you need a PLL output with an explicit phase shift, which is what Terasic's own
DE0-Nano demo uses. `H8FPGAPLL` is retained in the project for exactly that.
The inverted clock was chosen over hand-editing generated megafunction code
that could not be verified here.

`H8FPGA.sdc` now constrains the interface (`create_generated_clock -invert`,
plus tSU/tHD/tAC/tOH delays) so TimeQuest will say if this is wrong. If those
paths fail, do not loosen the numbers -- re-check the part number, then raise
`T_RD_WAIT`, then move to a phase-shifted PLL output.

### What the SDRAM simulation does and does not prove

`SIM/sdram_model.v` is a deliberately strict IS42S16160 model that reports an
error on anything the datasheet forbids: commands before the 100 us init wait,
out-of-order init, READ/WRITE without an open row, ACTIVATE on an un-precharged
bank, tRCD/tRP/tRC violations, refresh interval overruns, and DQM misuse.

17 controller checks pass with **0 protocol errors**, covering byte lanes and
DQM masking, row hits, row misses, a 40-row walk, the top of the 64K window,
and retention across an idle period with refreshes. Six mutations were checked
and all six are caught, including refresh disabled (10 protocol errors),
row-change precharge skipped (84), inverted DQM, and a read captured one clock
late.

**It does not prove the electrical capture point.** The model treats read data
as valid for a clean full clock period; a real part specifies tAC and tOH. The
logic is verified -- address mapping, byte lanes, row management, refresh, init
order -- and the capture alignment still has to be confirmed against the
datasheet and TimeQuest. `T_RD_WAIT` is the documented knob if the bench
disagrees.

### Still open in Tier 4

- Exact part number and speed grade unconfirmed (IS42S16160 vs IS42S16320).
- The 4.8 idea -- using the remaining ~31.9 MB for H17 disk images -- is
  untouched. It also needs a non-volatile source, since SDRAM loses everything
  on power-down.
