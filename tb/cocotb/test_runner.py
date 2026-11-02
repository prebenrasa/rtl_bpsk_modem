"""pytest launcher for every cocotb test module in tb/cocotb/ (cocotb_tools.runner).

TARGETS lists each HDL toplevel and the cocotb test modules that run against it. Each toplevel
is compiled once; each configuration of configs/sim_configs.txt (section cocotb_<toplevel>)
is one pytest test that runs the simulation with its generics.

To add tests:
- for an existing toplevel: add the module name to its list in TARGETS;
- for a new toplevel: add a row to TARGETS and, for more than its default generics,
  a [cocotb_<toplevel>] section in configs/sim_configs.txt.
Name cocotb test modules <name>_tests.py, so pytest does not collect them itself.

    uv run pytest tb/cocotb                      everything
    uv run pytest tb/cocotb -k bpsk_modem        one toplevel
    uv run pytest tb/cocotb -k GC_SPS-16         configurations matching a pattern (ids as in config_id)
    WAVES=1 uv run pytest tb/cocotb              also write build/cocotb/<toplevel>/<config>/<toplevel>.ghw
    SEED=1234 uv run pytest tb/cocotb            rerun with the random seed a failing run logged
"""
import os
import subprocess
from pathlib import Path

import pytest
from cocotb_tools.runner import get_runner

from sim_configs import parse_config, sim_configs

ROOT = Path(__file__).resolve().parents[2]
BUILD_DIR = ROOT / "build" / "cocotb"

# toplevel -> cocotb test modules run against it
TARGETS = {
    "bpsk_modem": ["bpsk_sample_tests"],
    "bpsk_channel_harness": ["bpsk_channel_tests"],
}


def rtl_sources() -> list[str]:
    """RTL_SRC and HARNESS_SRC from mk/sources.mk, so the source list exists in one place only."""
    out = subprocess.run(
        ["make", "-s", "-f", str(ROOT / "mk" / "sources.mk"), "--eval", "print: ; @echo $(RTL_SRC) $(HARNESS_SRC)", "print"],
        check=True, capture_output=True, text=True,
    )
    return out.stdout.split()


def ghdl_args(toplevel: str) -> list[str]:
    # --workdir: each configuration runs in its own folder, but the compiled library is in the toplevel's build folder
    return ["--std=08", f"--workdir={BUILD_DIR / toplevel}"]


def config_id(config: str) -> str:
    """"GC_SPS=12,GC_CCPS=3" -> "GC_SPS-12_GC_CCPS-3": pytest id and folder name ("=" breaks pytest -k)."""
    return config.replace(",", "_").replace("=", "-")


@pytest.fixture(scope="session")
def build():
    """Returns a function that compiles a toplevel on first use and hands back its runner."""
    runners = {}

    def get(toplevel: str):
        if toplevel not in runners:
            runner = get_runner("ghdl")
            runner.build(
                sources=rtl_sources(),
                hdl_toplevel=toplevel,
                build_dir=BUILD_DIR / toplevel,
                build_args=ghdl_args(toplevel),
                always=True,
            )
            runners[toplevel] = runner
        return runners[toplevel]

    return get


@pytest.mark.parametrize(
    "toplevel, config",
    [pytest.param(top, cfg, id=f"{top}-{config_id(cfg)}") for top in TARGETS for cfg in sim_configs(f"cocotb_{top}")],
)
def test_cocotb(build, toplevel, config):
    # GHDL applies generics at run time (ghdl -r -g...), so all configurations of a toplevel share one build
    build(toplevel).test(
        test_module=TARGETS[toplevel],
        hdl_toplevel=toplevel,
        build_dir=BUILD_DIR / toplevel,
        test_dir=BUILD_DIR / toplevel / config_id(config),
        test_args=ghdl_args(toplevel),
        parameters=parse_config(config),
        waves=bool(os.environ.get("WAVES")),
        seed=os.environ.get("SEED"),
    )
