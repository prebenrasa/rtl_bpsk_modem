# =============================================================================
#  VHDL practical flow: GHDL (simulation) + Vivado (synthesis / implementation)
#  Testbenches use UVVM (compiled once with `make uvvm-lib`); cocotb tests run via pytest.
#  Run `make help` for the list of targets.
#  Comments stay on their own lines: text after a value on the same line adds trailing spaces to it.
# =============================================================================

# ---- Machine-specific settings (tool and library paths) go in local.mk, which git ignores;
# copy local.mk.example to local.mk and edit it. Values given on the command line still win.
-include local.mk

# ---- Design selection (override on the command line, e.g. make sim TB=bpsk_rx_tb)
# top-level entity for synthesis / implementation
TOP  ?= bpsk_modem
# testbench entity for simulation
TB   ?= bpsk_tx_tb
# safety stop time for simulation
STOP ?= 1ms

# ---- Tools
GHDL       ?= ghdl
GHDL_STD   := --std=08
# -frelaxed: UVVM uses plain shared variables, which strict VHDL-2008 rejects;
# GHDL re-reads UVVM's sources when a testbench uses it, so every analysis needs the flag
GHDL_FLAGS = $(GHDL_STD) -frelaxed -P$(UVVM_LIB)
WAVEVIEWER ?= gtkwave
UV         ?= uv

# Vivado on PATH (source <Vivado>/settings64.sh), or set VIVADO in local.mk
VIVADO ?= vivado
# Basys 3 (Artix-7 35T)
PART   ?= xc7a35tcpg236-1

# ---- UVVM
# UVVM git checkout
UVVM_DIR ?= $(HOME)/design/libs/UVVM
# compiled libraries (*-obj08.cf)
UVVM_LIB ?= $(HOME)/design/libs/uvvm_compiled/ghdl

# ---- Sim Config
# make sim only, e.g. GENERICS="-gGC_SPS=5 -gGC_CCPS=1"; sim-all ignores it
GENERICS ?=

# configurations sim-all runs per testbench come from configs/sim_configs.txt (shared with tb/cocotb/);
# override one testbench on the command line, e.g. make sim-all CONFIGS_bpsk_tx_tb="default GC_SPS=12,GC_CCPS=3"
include mk/configs.mk

# ---- Paths
# every generated file goes under $(BUILD_DIR)/ (ignored by git); make clean deletes it
BUILD_DIR := build
SIM_DIR   := $(BUILD_DIR)/ghdl
NCO_DIR   := ip/rtl_nco
# source lists (absolute paths) come from mk/sources.mk, shared with tb/cocotb/ and Vivado
include mk/sources.mk
SRC       := $(RTL_SRC)
TBS       := $(TB_SRC)

# Vivado runs in one folder per top, so .Xil/, clockInfo.txt, logs, checkpoints and reports
# of different tops stay apart; impl, bit and open-* use the folder of the TOP they are given
VIVADO_OUT    = $(BUILD_DIR)/vivado/$(TOP)
VIVADO_BATCH  = cd $(VIVADO_OUT) && $(VIVADO) -mode batch -nojournal -notrace
VIVADO_SCRIPT = $(abspath scripts)
# synth.tcl and rtl.tcl read the sources from this file, one path per line; it is rewritten on every run
VIVADO_SRC_F  = $(abspath $(VIVADO_OUT))/sources.f
write_sources_f = $(file >$(VIVADO_SRC_F)) $(foreach f,$(RTL_SRC),$(file >>$(VIVADO_SRC_F),$(f)))

.PHONY: help check uvvm-lib sim sim-all cocotb test wave synth impl bit rtl open-synth open-impl reports save-reports clean

help:
	@echo "Simulation (GHDL, VHDL-2008)"
	@echo "  make sim   [TB=$(TB)]         analyse, elaborate, run -> $(SIM_DIR)/<TB>.ghw"
	@echo "  make sim-all                  run every *_tb.vhd in each configuration of configs/sim_configs.txt, print pass/fail"
	@echo "  make cocotb                   run the cocotb tests (tb/cocotb/) in each configuration, via pytest"
	@echo "  make test                     sim-all + cocotb"
	@echo "  make wave  [TB=$(TB)]         open the .ghw in $(WAVEVIEWER)"
	@echo "Vivado (part $(PART))"
	@echo "  make synth [TOP=$(TOP)]       synthesis -> $(VIVADO_OUT)/post_synth.dcp + reports"
	@echo "  make impl  [TOP=$(TOP)]       opt/place/route -> $(VIVADO_OUT)/post_route.dcp + reports"
	@echo "  make bit   [TOP=$(TOP)]       write bitstream (optional, no board needed)"
	@echo "  make rtl   [TOP=$(TOP)]       open the elaborated RTL schematic in the Vivado GUI"
	@echo "  make open-synth / open-impl [TOP=$(TOP)]   open a checkpoint in the Vivado GUI"
	@echo "  make reports [TOP=$(TOP)]     list generated reports"
	@echo "  make save-reports [TOP=$(TOP)]   copy key reports to $(REPORTS_DIR)/ (tracked in git)"
	@echo "Other"
	@echo "  make check                    show tool versions and whether UVVM is compiled"
	@echo "  make uvvm-lib                 compile UVVM from $(UVVM_DIR) into $(UVVM_LIB)"
	@echo "  make clean                    delete $(BUILD_DIR)/"

check:
	@$(GHDL) --version | head -n 1
	@$(VIVADO) -version 2>/dev/null | head -n 1 | grep . || echo "Vivado: '$(VIVADO)' not found - source settings64.sh or set VIVADO in local.mk"
	@$(UV) --version 2>/dev/null || echo "uv: not found - needed for make cocotb (https://docs.astral.sh/uv/)"
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
	@cd $(SIM_DIR) && for f in $(SRC) $(TBS); do \
		out=$$($(GHDL) -i $(GHDL_FLAGS) $$f 2>&1) || \
		{ echo "$$out" | grep -q "no design unit" && echo "skipped $$f (empty)" || echo "$$out"; }; \
	done
	cd $(SIM_DIR) && $(GHDL) -m $(GHDL_FLAGS) $(TB)
	cd $(SIM_DIR) && $(GHDL) -r $(GHDL_FLAGS) $(TB) $(GENERICS) --wave=$(TB).ghw --stop-time=$(STOP)
	@echo "Waveform: $(SIM_DIR)/$(TB).ghw"

# run every testbench in tb/uvvm/ and the NCO's tb/ (files named *_tb.vhd, file name = entity name)
# and print a summary; other files there (e.g. simulation-only packages) are compiled but not run
# GHDL exits 0 even after a failed assert, so failures are found in the output;
# UVVM stops with status 1 at its stop limit, but with a raised limit it only prints
# "Simulation FAILED" from report_alert_counters(FINAL)
TB_NAMES := $(basename $(notdir $(filter %_tb.vhd,$(TBS))))
# every run as <testbench>:<config>
SIM_RUNS := $(foreach tb,$(TB_NAMES),$(addprefix $(tb):,$(or $(CONFIGS_$(tb)),$(call sim_configs,$(tb)),default)))

# the full log is printed only for a failing run
sim-all:
	@[ -n "$(TB_NAMES)" ] || { echo "no testbenches in tb/uvvm/"; exit 1; }
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

# cocotb tests through the pytest runner (tb/cocotb/test_runner.py), one pytest test per toplevel and configuration;
# pass pytest options with PYTEST_ARGS, e.g. make cocotb PYTEST_ARGS="-k GC_SPS-16"; waveforms with WAVES=1
PYTEST_ARGS ?=
cocotb:
	$(UV) run pytest tb/cocotb $(PYTEST_ARGS)

test: sim-all cocotb

wave:
	$(WAVEVIEWER) $(SIM_DIR)/$(TB).ghw &

# ---------------------------------------------------------------- Vivado
synth:
	@mkdir -p $(VIVADO_OUT)
	$(write_sources_f)
	$(VIVADO_BATCH) -log synth.log -source $(VIVADO_SCRIPT)/synth.tcl -tclargs $(TOP) $(PART) $(VIVADO_SRC_F)

impl:
	@mkdir -p $(VIVADO_OUT)
	$(VIVADO_BATCH) -log impl.log -source $(VIVADO_SCRIPT)/impl.tcl

bit:
	@mkdir -p $(VIVADO_OUT)
	$(VIVADO_BATCH) -log bit.log -source $(VIVADO_SCRIPT)/bitstream.tcl

rtl:
	@mkdir -p $(VIVADO_OUT)
	$(write_sources_f)
	cd $(VIVADO_OUT) && $(VIVADO) -mode gui -nojournal -log rtl.log -source $(VIVADO_SCRIPT)/rtl.tcl -tclargs $(TOP) $(PART) $(VIVADO_SRC_F) &

open-synth:
	cd $(VIVADO_OUT) && $(VIVADO) -nojournal -log gui.log post_synth.dcp &

open-impl:
	cd $(VIVADO_OUT) && $(VIVADO) -nojournal -log gui.log post_route.dcp &

reports:
	@ls -1 $(VIVADO_OUT)/reports 2>/dev/null || echo "No reports yet - run make synth / make impl"

# copy the reports worth keeping from build/ (ignored by git) to reports/<TOP>/ (tracked);
# override the list with e.g. make save-reports SAVE_REPORTS="post_route_power.rpt"
REPORTS_DIR   = reports/$(TOP)
SAVE_REPORTS ?= post_route_utilization.rpt post_synth_utilization_hier.rpt post_route_timing.rpt

save-reports:
	@missing=""; for r in $(SAVE_REPORTS); do \
		[ -f $(VIVADO_OUT)/reports/$$r ] || missing="$$missing $$r"; \
	done; \
	if [ -n "$$missing" ]; then echo "not in $(VIVADO_OUT)/reports/:$$missing (run make synth impl first)"; exit 1; fi
	@if [ -n "$$(find src constraints $(NCO_DIR)/src -newer $(VIVADO_OUT)/reports/$(firstword $(SAVE_REPORTS)) -type f 2>/dev/null)" ]; then \
		echo "WARNING: src/ or constraints/ changed after the last build - reports may be out of date"; fi
	@if grep -qs "no user specified timing constraints" $(VIVADO_OUT)/reports/post_route_timing.rpt && \
		echo " $(SAVE_REPORTS) " | grep -q " post_route_timing.rpt "; then \
		echo "WARNING: post_route_timing.rpt has no clock constraint - add create_clock to constraints/clocks.xdc"; fi
	@mkdir -p $(REPORTS_DIR)
	cp $(addprefix $(VIVADO_OUT)/reports/,$(SAVE_REPORTS)) $(REPORTS_DIR)/

clean:
	rm -rf $(BUILD_DIR)
