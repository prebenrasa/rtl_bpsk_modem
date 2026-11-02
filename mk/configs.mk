# Reads configs/sim_configs.txt (see the format there) for Makefiles.
#   $(call sim_configs,<target>)   configurations of a target, one word each
#   $(call config_generics,<cfg>)  GHDL run options for one configuration: -gNAME=VALUE ...

SIM_CONFIGS_FILE := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))../configs/sim_configs.txt)

comma := ,
sim_configs = $(shell awk -v target=$(1) ' \
	{ sub(/\#.*/, "") } \
	/^[[:space:]]*$$/ { next } \
	/^\[/ { gsub(/[][]/, ""); on = 0; n = split($$0, t, " "); for (i = 1; i <= n; i++) if (t[i] == target) on = 1; next } \
	on { print $$1 }' $(SIM_CONFIGS_FILE))
config_generics = $(if $(filter default,$(1)),,$(addprefix -g,$(subst $(comma), ,$(1))))
