# =============================================================================
#  VHDL practical flow: GHDL (simulation) + Vivado (synthesis / implementation)
#  UVVM variant: testbenches can use the UVVM Utility Library (see README, section 1b)
#  Run `make help` for the list of targets.
# =============================================================================

# ---- Design selection (override on the command line, e.g. make sim TB=counter_tb)
TOP   ?= bpsk_tx                # top-level entity for synthesis / implementation
TB    ?= bpsk_tx_tb             # testbench entity for simulation
STOP  ?= 1ms               # safety stop time for simulation

# ---- Tools
GHDL       ?= ghdl
GHDL_STD   := --std=08
# -frelaxed: UVVM uses plain shared variables, which strict VHDL-2008 rejects;
# GHDL re-reads UVVM's sources when a testbench uses it, so every analysis needs the flag
GHDL_FLAGS = $(GHDL_STD) -frelaxed -P$(UVVM_LIB)
WAVEVIEWER ?= gtkwave

VIVADO_DIR ?= /home/preben/apps/2026.1/Vivado
VIVADO     ?= $(VIVADO_DIR)/bin/vivado
PART       ?= xc7a35tcpg236-1   # Basys 3 (Artix-7 35T)

# ---- UVVM (compile once with `make uvvm-lib`, see README section 1b)
UVVM_DIR ?= $(HOME)/design/libs/UVVM                    # UVVM git checkout
UVVM_LIB ?= $(HOME)/design/libs/uvvm_compiled/ghdl      # compiled libraries (*-obj08.cf)

# ---- Sim Config
GENERICS ?=            # make sim only, e.g. GENERICS="-gGC_SPS=5 -gGC_CCPS=1"; sim-all ignores it

# configurations sim-all runs per testbench: one word per run, generics separated by commas,
# "default" = the testbench's own generic defaults; a testbench with no list runs once with its defaults
CONFIGS_bpsk_tx_tb := default \
	GC_SPS=8,GC_CCPS=2,GC_PHASE_WIDTH=8,GC_ADDR_WIDTH=4 \
	GC_SPS=12,GC_CCPS=3 \
	GC_SPS=16,GC_CCPS=7 \
	GC_SPS=64,GC_CCPS=1,GC_SAMPLE_WIDTH=12,GC_ADDR_WIDTH=10 \
	GC_SPS=128,GC_CCPS=1 \
	GC_SPS=32,GC_CCPS=8,GC_PHASE_WIDTH=28
CONFIGS_bpsk_rx_tb := $(CONFIGS_bpsk_tx_tb) # rx runs the tx configurations

# ---- Paths
SIM_DIR   := sim
BUILD_DIR := build
NCO_DIR   := ip/rtl_nco
SRC       := $(wildcard src/*.vhd) $(wildcard $(NCO_DIR)/src/*.vhd)
TBS       := $(wildcard tb/*.vhd) $(wildcard $(NCO_DIR)/tb/*.vhd)

TOP  := $(strip $(TOP))
TB   := $(strip $(TB))
STOP := $(strip $(STOP))
PART := $(strip $(PART))
UVVM_DIR := $(strip $(UVVM_DIR))
UVVM_LIB := $(strip $(UVVM_LIB))

VIVADO_BATCH = cd $(BUILD_DIR) && $(VIVADO) -mode batch -nojournal -notrace

.PHONY: help check uvvm-lib sim sim-all wave synth impl bit rtl open-synth open-impl reports save-reports clean

help:
	@echo "Simulation (GHDL, VHDL-2008)"
	@echo "  make sim   [TB=$(TB)]         analyse, elaborate, run -> $(SIM_DIR)/<TB>.ghw"
	@echo "  make sim-all                  run every *_tb.vhd in each CONFIGS_<tb> configuration, print pass/fail"
	@echo "  make wave  [TB=$(TB)]         open the .ghw in $(WAVEVIEWER)"
	@echo "Vivado (part $(PART))"
	@echo "  make synth [TOP=$(TOP)]       synthesis -> $(BUILD_DIR)/post_synth.dcp + reports"
	@echo "  make impl                     opt/place/route -> $(BUILD_DIR)/post_route.dcp + reports"
	@echo "  make bit                      write bitstream (optional, no board needed)"
	@echo "  make rtl   [TOP=$(TOP)]       open the elaborated RTL schematic in the Vivado GUI"
	@echo "  make open-synth / open-impl   open a checkpoint in the Vivado GUI"
	@echo "  make reports                  list generated reports"
	@echo "  make save-reports             copy key reports to $(REPORTS_DIR)/ (tracked in git)"
	@echo "Other"
	@echo "  make check                    show tool versions and whether UVVM is compiled"
	@echo "  make uvvm-lib                 compile UVVM from $(UVVM_DIR) into $(UVVM_LIB)"
	@echo "  make clean                    delete $(SIM_DIR)/ and $(BUILD_DIR)/"

check:
	@$(GHDL) --version | head -n 1
	@$(VIVADO) -version | head -n 1
	@command -v $(WAVEVIEWER) >/dev/null && echo "$(WAVEVIEWER): found" || echo "$(WAVEVIEWER): not found (use Surfer in VS Code instead)"
	@[ -f $(UVVM_LIB)/uvvm_util-obj08.cf ] && echo "UVVM: compiled in $(UVVM_LIB)" || echo "UVVM: not compiled - run make uvvm-lib"

# compile_all.sh needs bash (not sh) and an existing target directory;
# it writes the libraries to <target>/ghdl, so the target is the parent of UVVM_LIB
uvvm-lib:
	@[ -d $(UVVM_DIR)/script ] || { echo "no UVVM checkout in $(UVVM_DIR) - git clone https://github.com/UVVM/UVVM.git $(UVVM_DIR)"; exit 1; }
	mkdir -p $(dir $(UVVM_LIB))
	cd $(UVVM_DIR)/script && bash compile_all.sh ghdl $(abspath $(UVVM_LIB)/..)

# ---------------------------------------------------------------- Simulation
sim:
	@mkdir -p $(SIM_DIR)
	@# import file by file: an empty/unfinished file is skipped instead of stopping the run;
	@# ghdl -m then only compiles the units that $(TB) actually needs
	@cd $(SIM_DIR) && for f in $(addprefix ../,$(SRC) $(TBS)); do \
		out=$$($(GHDL) -i $(GHDL_FLAGS) $$f 2>&1) || \
		{ echo "$$out" | grep -q "no design unit" && echo "skipped $$f (empty)" || echo "$$out"; }; \
	done
	cd $(SIM_DIR) && $(GHDL) -m $(GHDL_FLAGS) $(TB)
	cd $(SIM_DIR) && $(GHDL) -r $(GHDL_FLAGS) $(TB) $(GENERICS) --wave=$(TB).ghw --stop-time=$(STOP)
	@echo "Waveform: $(SIM_DIR)/$(TB).ghw"

# run every testbench in tb/ (files named *_tb.vhd, file name = entity name) and print a summary;
# other files in tb/ (e.g. simulation-only packages) are compiled but not run
# GHDL exits 0 even after a failed assert, so failures are found in the output;
# UVVM stops with status 1 at its stop limit, but with a raised limit it only prints
# "Simulation FAILED" from report_alert_counters(FINAL)
TB_NAMES := $(basename $(notdir $(filter %_tb.vhd,$(TBS))))
# every run as <testbench>:<config>
SIM_RUNS := $(foreach tb,$(TB_NAMES),$(addprefix $(tb):,$(or $(CONFIGS_$(tb)),default)))

# the full log is printed only for a failing run
sim-all:
	@[ -n "$(TB_NAMES)" ] || { echo "no testbenches in tb/"; exit 1; }
	@failed=""; \
	for run in $(SIM_RUNS); do \
		tb=$${run%%:*}; cfg=$${run#*:}; \
		if [ "$$cfg" = default ]; then gen=""; else gen="-g$$(echo $$cfg | sed 's/,/ -g/g')"; fi; \
		out=$$($(MAKE) --no-print-directory sim TB=$$tb GENERICS="$$gen" 2>&1); status=$$?; \
		if [ $$status -ne 0 ] || ! echo "$$out" | grep -q 'Simulation SUCCESS' || \
		   echo "$$out" | grep -qE '\((assertion|report) (error|failure)\)|Simulation FAILED'; then \
			echo "$$out"; echo "FAIL  $$tb  $$cfg"; failed="$$failed $$run"; \
		else \
			echo "pass  $$tb  $$cfg"; \
		fi; \
	done; \
	echo "==="; \
	if [ -n "$$failed" ]; then echo "FAILED:$$failed"; exit 1; else echo "all $(words $(SIM_RUNS)) runs passed"; fi

wave:
	$(WAVEVIEWER) $(SIM_DIR)/$(TB).ghw &

# ---------------------------------------------------------------- Vivado
synth:
	@mkdir -p $(BUILD_DIR)
	$(VIVADO_BATCH) -log synth.log -source ../scripts/synth.tcl -tclargs $(TOP) $(PART)

impl:
	@mkdir -p $(BUILD_DIR)
	$(VIVADO_BATCH) -log impl.log -source ../scripts/impl.tcl

bit:
	@mkdir -p $(BUILD_DIR)
	$(VIVADO_BATCH) -log bit.log -source ../scripts/bitstream.tcl

rtl:
	@mkdir -p $(BUILD_DIR)
	cd $(BUILD_DIR) && $(VIVADO) -mode gui -nojournal -log rtl.log -source ../scripts/rtl.tcl -tclargs $(TOP) $(PART) &

open-synth:
	cd $(BUILD_DIR) && $(VIVADO) -nojournal -log gui.log post_synth.dcp &

open-impl:
	cd $(BUILD_DIR) && $(VIVADO) -nojournal -log gui.log post_route.dcp &

reports:
	@ls -1 $(BUILD_DIR)/reports 2>/dev/null || echo "No reports yet - run make synth / make impl"

# copy the reports worth keeping from build/ (ignored by git) to reports/ (tracked);
# override the list with e.g. make save-reports SAVE_REPORTS="post_route_power.rpt"
REPORTS_DIR  := reports
SAVE_REPORTS ?= post_route_utilization.rpt post_synth_utilization_hier.rpt post_route_timing.rpt

save-reports:
	@missing=""; for r in $(SAVE_REPORTS); do \
		[ -f $(BUILD_DIR)/reports/$$r ] || missing="$$missing $$r"; \
	done; \
	if [ -n "$$missing" ]; then echo "not in $(BUILD_DIR)/reports/:$$missing (run make synth impl first)"; exit 1; fi
	@if [ -n "$$(find src constraints -newer $(BUILD_DIR)/reports/$(firstword $(SAVE_REPORTS)) -type f 2>/dev/null)" ]; then \
		echo "WARNING: src/ or constraints/ changed after the last build - reports may be out of date"; fi
	@if grep -qs "no user specified timing constraints" $(BUILD_DIR)/reports/post_route_timing.rpt && \
		echo " $(SAVE_REPORTS) " | grep -q " post_route_timing.rpt "; then \
		echo "WARNING: post_route_timing.rpt has no clock constraint - add create_clock to constraints/$(TOP).xdc"; fi
	@mkdir -p $(REPORTS_DIR)
	cp $(addprefix $(BUILD_DIR)/reports/,$(SAVE_REPORTS)) $(REPORTS_DIR)/

clean:
	rm -rf $(SIM_DIR) $(BUILD_DIR) .Xil *.jou *.log *.str clockInfo.txt
