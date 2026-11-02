"""Runs the data-logging simulations behind the report figures (bpsk_report_tests.py), in parallel.

Not collected by the regression run (pytest only picks up test_*.py); start it explicitly:

    uv run pytest tb/cocotb/report_runner.py                 every experiment (tens of minutes: the BER runs)
    uv run pytest tb/cocotb/report_runner.py -k ber          one group
    uv run python tb/cocotb/plot_report.py                   then the figures

Each experiment is one simulation of bpsk_channel_harness with its own generics, cocotb test and REPORT_*
parameters, run in build/report/data/<experiment id>/ with a fixed seed, so the figures are reproducible.
params.json in that folder records what the run was, for plot_report.py.
"""
import json
import os

import pytest

from bpsk_channel_tests import ber_theory
from test_runner import ROOT, build, ghdl_args, lib_dir  # noqa: F401 (build is a fixture)

TOPLEVEL = "bpsk_channel_harness"
DATA_DIR = ROOT / "build" / "report" / "data"

# reference configuration: the generic defaults (L 8, N 24, M 10, SPS 32, CCPS 8 = carrier at fs/4, default loop
# gains) with differential encoding on. Every experiment starts from it and changes only what it studies.
REFERENCE = {"GC_DIFF_ENCODING": "true"}


def config(**generics) -> dict:
    """The reference configuration with some generics changed, e.g. config(GC_SPS=8, GC_CCPS=2)."""
    return {**REFERENCE, **{name: str(value).lower() if isinstance(value, bool) else value
                            for name, value in generics.items()}}


def experiment(exp_id: str, test: str, generics: dict, **params):
    """One run: id (folder name and pytest id), cocotb test, generics, REPORT_* parameters."""
    return pytest.param(exp_id, test, generics, params, id=exp_id)


def ber_bits(ebn0_db: float, diff: bool) -> int:
    """Enough bits for about 300 errors, within 4000 .. 80000 (simulation time). With differential encoding the
    errors come in pairs, so 300 errors are only about 150 independent events."""
    return min(80000, max(4000, round(300 / ber_theory(ebn0_db, diff))))


EXPERIMENTS = [
    # BER against Eb/N0, without and with differential encoding (the longest runs, so they start first)
    *[experiment(f"ber_diff{int(diff)}_{ebn0}db", "test_report_ber", config(GC_DIFF_ENCODING=diff),
                 ebn0_db=ebn0, n_bits=ber_bits(ebn0, diff))
      for ebn0 in range(7, -1, -1) for diff in (False, True)],
    # BER diagnosis at 2 dB: every symbol decision logged, several seeds per mode
    *[experiment(f"berdiag_diff{int(diff)}_run{run}", "test_report_ber", config(GC_DIFF_ENCODING=diff),
                 ebn0_db=2, n_bits=20000, log_symbols=1)
      for diff in (False, True) for run in range(4)],
    # constellation: 30 degree offset, without noise and at 10 dB
    experiment("constellation_clean", "test_report_phase", config(), phase_deg=30, n_bits=200),
    experiment("constellation_10db", "test_report_phase", config(), phase_deg=30, ebn0_db=10, n_bits=400),
    # initial phase sweep over the full circle, finer near the unstable point at 90 degrees: measured S-curve of
    # the phase detector, and lock time against initial offset (hang-up near 90 degrees, Gardner 1977)
    *[experiment(f"acqsweep_{phase:g}", "test_report_phase", config(), phase_deg=phase, n_bits=400)
      for phase in sorted({*range(-175, 181, 5), 87, 88, 89, 89.5, 89.9, 90.1, 90.5, 91, 92, 93})],
    # pull-in: frequency offsets (cycles/sample) up to well past what the loop can follow
    *[experiment(f"pullin_{offset:g}", "test_report_phase", config(), phase_deg=0, freq_offset=offset, n_bits=400)
      for offset in (1e-5, 3e-5, 1e-4, 3e-4, 1e-3, 2e-3, 3e-3, 5e-3, 1e-2)],
    # 180 degree ambiguity, without and with differential encoding
    *[experiment(f"inversion_diff{int(diff)}", "test_report_phase", config(GC_DIFF_ENCODING=diff),
                 phase_deg=150, n_bits=200)
      for diff in (False, True)],
    # tx waveform, without and with differential encoding
    *[experiment(f"tx_wave_diff{int(diff)}", "test_report_tx", config(GC_DIFF_ENCODING=diff), bits="110100")
      for diff in (False, True)],
    # tx spectrum of the reference; LUT size at GC_CCPS 3 (at fs/4 the NCO only reads 4 exact phases, so a
    # 16-entry LUT would look the same as the 1024-entry one)
    experiment("tx_spectrum_ref", "test_report_tx", config(), n_bits=2000),
    *[experiment(f"tx_spectrum_ccps3_m{m}", "test_report_tx", config(GC_CCPS=3, GC_ADDR_WIDTH=m), n_bits=2000)
      for m in (10, 4)],
    # residual phase jitter against carrier cycles per symbol
    *[experiment(f"ccps_{ccps}", "test_report_phase", config(GC_CCPS=ccps), phase_deg=30, n_bits=300)
      for ccps in (1, 2, 3, 4, 6, 8, 12, 15)],
    # matched filter output per sample (eye), without noise and at 10 dB
    experiment("eye_clean", "test_report_phase", config(), phase_deg=0, n_bits=200, log_samples=1),
    experiment("eye_10db", "test_report_phase", config(), phase_deg=0, ebn0_db=10, n_bits=200, log_samples=1),
    # throughput and latency against samples per symbol (carrier kept at fs/4) and the clk_en duty
    *[experiment(f"throughput_sps{sps}_duty{duty:g}", "test_report_throughput", config(GC_SPS=sps, GC_CCPS=sps // 4),
                 duty=duty, n_bits=200)
      for sps in (8, 16, 32, 64, 128) for duty in (1.0, 0.5, 0.25)],
]


@pytest.mark.parametrize("exp_id, test, generics, params", EXPERIMENTS)
def test_report(build, exp_id, test, generics, params):
    run_dir = DATA_DIR / exp_id
    run_dir.mkdir(parents=True, exist_ok=True)
    seed = 1000 + sum(map(ord, exp_id))  # fixed per experiment: reruns give the same figures
    (run_dir / "params.json").write_text(json.dumps(
        {"id": exp_id, "test": test, "generics": generics, "params": params, "seed": seed}, indent=2))
    build(TOPLEVEL).test(
        test_module="bpsk_report_tests",
        testcase=test,
        hdl_toplevel=TOPLEVEL,
        build_dir=lib_dir(TOPLEVEL),
        test_dir=run_dir,
        test_args=ghdl_args(TOPLEVEL),
        parameters=generics,
        extra_env={f"REPORT_{name.upper()}": str(value) for name, value in params.items()},
        seed=seed,
    )
