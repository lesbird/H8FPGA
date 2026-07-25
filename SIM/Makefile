# =========================================================================
# Simulation for the H8FPGA stability rework.
#
# Requires Icarus Verilog (iverilog + vvp). If it is not on your PATH, set
# IVDIR to the bin directory of an install, e.g. a YosysHQ oss-cad-suite:
#
#   make IVDIR=/path/to/oss-cad-suite/bin
#
# Targets:
#   make units   unit tests for each rework module
#   make sdram   SDRAM controller against a protocol-checking model
#   make top     top-level integration, BOTH RAM backends
#   make mutate  sanity-check that the tests actually catch regressions
#   make all     everything
#
# NOTE: SIM/stubs.v defines modules named T80pa, H8FPGAROM and H8FPGARAM so
# that Icarus can elaborate the design without a VHDL simulator or Altera
# libraries. It must NEVER be added to H8FPGA.qsf.
# =========================================================================

IVDIR    ?=
IVERILOG := $(if $(IVDIR),$(IVDIR)/,)iverilog
VVP      := $(if $(IVDIR),$(IVDIR)/,)vvp

RTL := ../RTL/h8fpga_top.v ../RTL/h8_clkgen.v ../RTL/h8_reset.v \
       ../RTL/h8_sync.v ../RTL/h8_intctl.v ../RTL/h8_org0.v \
       ../RTL/h8_busif.v ../RTL/h8_memmap.v ../RTL/h8_sdram.v

# The top-level test needs the stubs; the unit tests do not (and must not have
# them, since nothing there instantiates a CPU or a memory).
RTL_UNITS := ../RTL/h8_clkgen.v ../RTL/h8_reset.v ../RTL/h8_sync.v \
             ../RTL/h8_intctl.v ../RTL/h8_org0.v ../RTL/h8_busif.v \
             ../RTL/h8_memmap.v

IVFLAGS := -g2005 -Wall -Wno-timescale

.PHONY: all units sdram top mutate clean

all: units sdram top

units: tb_units.vvp
	@$(VVP) ./tb_units.vvp

sdram: tb_sdram.vvp
	@$(VVP) ./tb_sdram.vvp

# Exercise the SDRAM path and the M9K fallback. Both must produce identical
# read traces -- if they diverge, the SDRAM backend is not a drop-in.
top: tb_top_sdram.vvp tb_top_m9k.vvp
	@echo "--- USE_SDRAM=1 (SDRAM, Tier 4) ---"
	@$(VVP) ./tb_top_sdram.vvp
	@echo "--- USE_SDRAM=0 (32K M9K fallback) ---"
	@$(VVP) ./tb_top_m9k.vvp

tb_units.vvp: tb_units.v $(RTL_UNITS)
	@$(IVERILOG) $(IVFLAGS) -o $@ tb_units.v $(RTL_UNITS)

tb_sdram.vvp: tb_sdram.v sdram_model.v ../RTL/h8_sdram.v
	@$(IVERILOG) $(IVFLAGS) -o $@ tb_sdram.v sdram_model.v ../RTL/h8_sdram.v

tb_top_sdram.vvp: tb_top.v stubs.v sdram_model.v $(RTL)
	@$(IVERILOG) $(IVFLAGS) -Ptb_top.USE_SDRAM_TB=1 -o $@ \
	   tb_top.v stubs.v sdram_model.v $(RTL)

tb_top_m9k.vvp: tb_top.v stubs.v sdram_model.v $(RTL)
	@$(IVERILOG) $(IVFLAGS) -Ptb_top.USE_SDRAM_TB=0 -o $@ \
	   tb_top.v stubs.v sdram_model.v $(RTL)

# ---------------------------------------------------------------------------
# Mutation check.
#
# A test suite that passes on the first try deserves suspicion. Each mutation
# below reintroduces one of the defects the rework removes; every one MUST be
# reported as a failure. If a mutation passes, the corresponding test is
# vacuous and needs fixing.
# ---------------------------------------------------------------------------
mutate:
	@rm -rf .mut && mkdir -p .mut && cp ../RTL/*.v .mut/
	@echo "Each line below MUST say FAIL."
	@echo ""
	@printf "  read-mux default FF -> 00          : "
	@perl -pi -e "s/cpu_di = 8'hFF/cpu_di = 8'h00/" .mut/h8_memmap.v
	@$(MAKE) -s _mutrun; cp ../RTL/h8_memmap.v .mut/
	@printf "  rom_dis dropped (original bug)     : "
	@perl -pi -e "s/assign rom_rd = memr & rom_window & ~rom_dis;/assign rom_rd = memr \& rom_window;/" .mut/h8_memmap.v
	@$(MAKE) -s _mutrun; cp ../RTL/h8_memmap.v .mut/
	@printf "  '245 DIR driven without sequencing : "
	@perl -pi -e "s/assign d245_dir_out = \(state == ST_OUT\);/assign d245_dir_out = drive_req;/" .mut/h8_busif.v
	@$(MAKE) -s _mutrun; cp ../RTL/h8_busif.v .mut/
	@printf "  clkgen default divisor removed     : "
	@perl -pi -e "s/default: div_sel = 5'd12;.*/default: div_sel = 5'd0;/" .mut/h8_clkgen.v
	@$(MAKE) -s _mutrun
	@rm -rf .mut

_mutrun:
	@$(IVERILOG) $(IVFLAGS) -o .mut/m.vvp tb_units.v .mut/h8_clkgen.v \
	   .mut/h8_reset.v .mut/h8_sync.v .mut/h8_intctl.v .mut/h8_org0.v \
	   .mut/h8_busif.v .mut/h8_memmap.v 2>/dev/null
	@$(VVP) .mut/m.vvp 2>/dev/null | grep -E "^(PASS|FAIL):" || echo "(no result)"

clean:
	rm -f *.vvp *.vcd
	rm -rf .mut
