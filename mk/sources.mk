# Source lists of the project, shared by the GHDL flow (Makefile), cocotb (tb/cocotb/test_runner.py)
# and Vivado (the Makefile writes RTL_SRC to build/vivado/<TOP>/sources.f for synth.tcl / rtl.tcl).
# Keep vhdl_ls.toml in step with the folders used here.
#   RTL_SRC   synthesisable sources, in compile order (packages before the entities that use them)
#   TB_SRC    testbenches and simulation-only packages; GHDL sorts these itself (ghdl -i / -m)
#   HARNESS_SRC  simulation-only tops for cocotb (in src/, but never synthesised), compiled after RTL_SRC

ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)

include $(ROOT)/ip/rtl_nco/sources.mk

RTL_SRC := $(RTL_NCO_SRC) \
           $(ROOT)/src/bpsk_pkg.vhd \
           $(ROOT)/src/reset_sync.vhd \
           $(ROOT)/src/bpsk_tx.vhd \
           $(ROOT)/src/bpsk_rx.vhd \
           $(ROOT)/src/bpsk_modem.vhd

HARNESS_SRC := $(ROOT)/src/bpsk_channel_harness.vhd

TB_SRC  :=$(RTL_NCO_TB) $(wildcard $(ROOT)/tb/uvvm/*.vhd)
