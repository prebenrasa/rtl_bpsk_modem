"""Reads configs/sim_configs.txt, the configuration list shared with the GHDL flow.

Used by the pytest runner (test_runner.py) only: the tests read the generics of their run from the DUT.
"""
from pathlib import Path

SIM_CONFIGS_FILE = Path(__file__).resolve().parents[2] / "configs" / "sim_configs.txt"  # this file is in tb/cocotb/


def sim_configs(target: str) -> list[str]:
    """Configurations of a target (section header name), in file order; ["default"] if it has none."""
    configs, active = [], False
    for line in SIM_CONFIGS_FILE.read_text().splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        if line.startswith("["):
            active = target in line.strip("[]").split()
        elif active:
            configs.append(line.split()[0])
    return configs or ["default"]


def parse_config(config: str) -> dict[str, int]:
    """"GC_SPS=8,GC_CCPS=2" -> {"GC_SPS": 8, "GC_CCPS": 2}; "default" -> {}."""
    if config == "default":
        return {}
    return {name: int(value) for name, value in (item.split("=") for item in config.split(","))}
