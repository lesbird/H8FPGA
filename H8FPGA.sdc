# =========================================================================
# H8FPGA timing constraints
#
# Addresses STABILITY-REVIEW.md section 0.2: the project previously had no
# .sdc at all, so TimeQuest analyzed nothing, the fitter optimized for
# nothing, and every recompile produced a differently-timed machine.
#
# This file constrains the design AS IT IS TODAY (combinational clock mux and
# all). Expect violations on the first run -- that is the point. They are the
# Tier 1 defects finally becoming visible.
# =========================================================================

# -------------------------------------------------------------------------
# Base clock: DE0-Nano 50 MHz oscillator on PIN_R8
# -------------------------------------------------------------------------
create_clock -name CLOCK_50 -period 20.000 [get_ports CLOCK_50]

# H8FPGAPLL c0..c4 = 2.083 / 4.17 / 8.33 / 25 / 50 MHz
derive_pll_clocks


# -------------------------------------------------------------------------
# Clock mux modelling (review 1.1)
#
# 81mux/inst41 combinationally selects one of the five PLL outputs onto net
# CLKOUT, which clocks Z80pa/inst1.CLKIN, H8FPGAROM/inst11.clock and
# H8FPGARAM/inst12.clock. All five PLL clocks therefore physically reach the
# same register clock pins, and TimeQuest will try to close timing between
# every pair of them unless told they are mutually exclusive.
#
# Declaring them exclusive is the standard way to model a clock mux. It makes
# the report meaningful instead of a wall of cross-domain noise.
#
# NOTE: confirm these clock names against `report_clocks` on the first
# TimeQuest run and correct the patterns if the PLL hierarchy differs.
# -------------------------------------------------------------------------
set pll_clocks {}
foreach i {0 1 2 3 4} {
    set c [get_clocks -nowarn "*altpll_component*|clk\[$i\]"]
    if {[get_collection_size $c] > 0} {
        lappend pll_clocks $c
    }
}
if {[llength $pll_clocks] > 1} {
    set cg_args {}
    foreach c $pll_clocks { lappend cg_args -group $c }
    eval set_clock_groups -exclusive $cg_args
} else {
    post_message -type warning \
        "H8FPGA.sdc: PLL clock names did not match; run report_clocks and fix the patterns."
}

derive_clock_uncertainty


# -------------------------------------------------------------------------
# H8 backplane inputs (review 2.1)
#
# GPIO_1[*] arrives from the H8 bus through 74LVC245 level shifters. These
# are genuinely asynchronous to every internal clock and are currently NOT
# synchronized anywhere in the design, so constraining them would produce
# meaningless failures.
#
# Cutting them here is correct both now and after Tier 2.1: once two-flop
# synchronizers are added, the synchronizer input remains the asynchronous
# boundary and this false_path still belongs.
#
# What this does NOT excuse: the missing synchronizers themselves. A
# false_path silences the analyzer, it does not make the crossing safe.
# -------------------------------------------------------------------------
set_false_path -from [get_ports {GPIO_1[*]}]

# Onboard pushbuttons / slide switches, if ever brought into the design
set_false_path -from [get_ports {KEY[*]}] -to *
set_false_path -from [get_ports {SW[*]}]  -to *


# -------------------------------------------------------------------------
# H8 backplane outputs (review 2.4)
#
# Budget reserved for the 74LVC245 (tPD ~4.1 ns max at 3.3 V) plus backplane
# trace and the receiving card's setup requirement.
#
# The H8 bus itself is slow -- a 2 MHz Z80 M-cycle is ~1.5 us -- so absolute
# delay is not the concern. What matters is SKEW BETWEEN these outputs, which
# is currently unmanaged because they come combinationally off the core. Give
# them all the same budget so the fitter aligns them, then enable
# FAST_OUTPUT_REGISTER once the outputs are actually registered (Tier 2.4).
# -------------------------------------------------------------------------
set_output_delay -clock CLOCK_50 -max 8.000 [get_ports {GPIO_0[*]}]
set_output_delay -clock CLOCK_50 -min 0.000 [get_ports {GPIO_0[*]}]
set_output_delay -clock CLOCK_50 -max 8.000 [get_ports {GPIO_2[*]}]
set_output_delay -clock CLOCK_50 -min 0.000 [get_ports {GPIO_2[*]}]

# GPIO_1[12..19] is the bidirectional data byte; the rest of GPIO_1 is input
# only. Constrain the output direction of the whole port -- pins with no
# driver simply have no output path to analyze.
set_output_delay -clock CLOCK_50 -max 8.000 [get_ports {GPIO_1[*]}]
set_output_delay -clock CLOCK_50 -min 0.000 [get_ports {GPIO_1[*]}]


# -------------------------------------------------------------------------
# SDRAM -- Tier 4
#
# DRAM_CLK is driven as the INVERTED system clock (see the long note in
# h8fpga_top.v). That places the SDRAM's edges mid-period so read data
# straddles the controller's sampling edge with roughly 10 ns of margin each
# way at 50 MHz.
#
# Declare it as a generated clock so TimeQuest analyzes the interface rather
# than ignoring it.
# -------------------------------------------------------------------------
create_generated_clock -name DRAM_CLK_out \
    -source [get_ports CLOCK_50] -invert [get_ports DRAM_CLK]

set sdram_out [get_ports {DRAM_ADDR[*] DRAM_BA[*] DRAM_DQM[*] \
                          DRAM_CAS_N DRAM_RAS_N DRAM_WE_N DRAM_CS_N DRAM_CKE}]

# Command/address setup and hold at the SDRAM, from the datasheet:
#   tSU ~1.5 ns, tHD ~0.8 ns for a -7 grade.
# CONFIRM these against the actual part on your board revision -- some
# DE0-Nano builds fit IS42S16320 rather than IS42S16160.
set_output_delay -clock DRAM_CLK_out -max  1.500 $sdram_out
set_output_delay -clock DRAM_CLK_out -min -0.800 $sdram_out
set_output_delay -clock DRAM_CLK_out -max  1.500 [get_ports {DRAM_DQ[*]}]
set_output_delay -clock DRAM_CLK_out -min -0.800 [get_ports {DRAM_DQ[*]}]

# Read data back from the SDRAM: tAC ~5.4 ns access, tOH ~2.7 ns output hold.
set_input_delay  -clock DRAM_CLK_out -max  5.400 [get_ports {DRAM_DQ[*]}]
set_input_delay  -clock DRAM_CLK_out -min  2.700 [get_ports {DRAM_DQ[*]}]

# If these paths fail, the fix is NOT to loosen the numbers. In order of
# preference:
#   1. re-check the part number and speed grade
#   2. raise h8_sdram's T_RD_WAIT (the documented bring-up knob)
#   3. bring back H8FPGAPLL and drive DRAM_CLK from a properly phase-shifted
#      PLL output, which is what is genuinely required above ~75 MHz
