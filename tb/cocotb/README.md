# cocotb tests

| File | Contents |
|---|---|
| `bpsk_tests.py` | Verification components: bit driver and monitors, `ClkEnDriver`, `ModemModel` (expected bits, latency and trust), `BitScoreboard`, and `BpskTestbench`, which wires them up for one DUT |
| `bpsk_sample_tests.py` | Tests of `bpsk_modem` (tx -> rx directly) |
| `bpsk_channel_tests.py` | Tests of `bpsk_channel_harness` (tx -> channel model -> rx): noise, carrier phase, phase inversion |
| `channel.py` | Channel models between `tx_sample_*` and `rx_sample_*` (`AwgnChannel`, `PhaseOffsetChannel`), and `PhaseErrorMonitor`, which logs the Costas loop's residual phase error |
| `dut_generics.py` | `DutGenerics`: the generics of the DUT the tests need (and values derived from them), read once per component with `DutGenerics.from_dut(dut)` |
| `plot_costas.py` | Plots the CSVs `test_phase_offset` writes (needs the `dev` dependency group, matplotlib) |
| `bpsk_report_tests.py` | Data-logging runs of `bpsk_channel_harness` for the report figures (BER, Costas loop per symbol, tx samples); not part of the regression run |
| `report_runner.py` | Runs the report experiments (generics, test and parameters per run, fixed seeds) in parallel into `build/report/data/` |
| `plot_report.py` | Turns those runs into the report figures in `doc/figures/` |
| `test_runner.py` | pytest launcher (`cocotb_tools.runner`) for every toplevel in its `TARGETS` table: compiles each toplevel once, one pytest test per toplevel and configuration |
| `sim_configs.py` | Reads `configs/sim_configs.txt`, section `cocotb_<toplevel>` (shared with the GHDL flow) |

The source list comes from `mk/sources.mk`. Output goes to `build/cocotb/<toplevel>/<configuration>/`.

The configurations run in parallel, one pytest-xdist worker per CPU (`addopts` in `pyproject.toml`). Each worker compiles
its own library in `build/cocotb/<toplevel>/lib/<worker>/`. Pass `-n 0` to run them one after another, e.g. with `-s` to see the
simulation log.

Adding tests:
- for an existing toplevel: write `<name>_tests.py` and add `<name>_tests` to the toplevel's list in `TARGETS`;
- for a new toplevel: add a row to `TARGETS`, and a `[cocotb_<toplevel>]` section in `configs/sim_configs.txt` for more than its default generics.

Name test modules `*_tests.py`, not `test_*.py`: they only run inside a simulation, so pytest must not collect them.

```bash
make cocotb                              # every configuration
make cocotb PYTEST_ARGS="-k bpsk_modem"  # one toplevel
make cocotb PYTEST_ARGS="-k GC_SPS-16"   # configurations matching a pattern (ids: GC_SPS-16_GC_CCPS-7)
WAVES=1 make cocotb                      # also write build/cocotb/<toplevel>/<configuration>/<toplevel>.ghw
SEED=1234 make cocotb PYTEST_ARGS="-k GC_SPS-16"  # rerun a failing run with the seed from its log
make cocotb PYTEST_ARGS="-n 0 -s -k default"     # one after another, with the simulation log
```

Generics: the tests read them from the DUT, so the VHDL defaults are the only copy. All reads go through `DutGenerics`
(`tb.generics.sps` in a test); add a field there when a test needs another generic. A configuration may
set a boolean generic (`GC_DIFF_ENCODING=true`); `sim_configs.py` passes it to GHDL as written.

## Tests

Every test runs once per configuration of its toplevel. With `GC_DIFF_ENCODING`, bits out still equal bits in (tx encodes,
rx decodes); `ModemModel` then expects the first bit after reset to be untrusted, since rx decodes it against the reference symbol.

`bpsk_sample_tests.py` (`bpsk_modem`), a starting point for writing tests:
- `test_sample_reset_state`: after reset, tx is ready, rx outputs nothing, and nothing comes out without input.
- `test_sample_loopback`, with `clk_en` duty 1.0 and 0.6: directed patterns (a run of 1s, alternating bits), then random
  bits with idle gaps. Checks order, value, `rx_bit_trust`, and (with `clk_en` = '1') the latency of GC_SPS + 7 clocks.

`bpsk_channel_tests.py` (`bpsk_channel_harness`; the channel adds one clock of latency):
- `test_channel_transparent`: no noise; every bit arrives correct, trusted and on time, with idle gaps between bits.
- `test_channel_awgn`, at Eb/N0 0 and 4 dB: 1000 random bits. Bits are counted, not checked one by one. The BER must lie
  within a binomial interval (4 sigma) between theory and theory at 1 dB implementation loss; the theory is
  Q(sqrt(2 Eb/N0)), or 2p(1 - p) with differential encoding (errors come in pairs, so the interval is sqrt(2) wider).
  The clip rate of the channel must stay below 1e-3.
- `test_phase_offset`, at 30 and -60 degrees, without and with a drift of 1e-4 cycles/sample: 300 random bits; the Costas
  loop's phase error over the last 50 symbols must stay below 5 degrees. Writes
  `costas_phase<deg>_drift<offset>.csv` per case for `plot_costas.py`. Fails at GC_PHASE_WIDTH=8 / GC_ADDR_WIDTH=4: the
  16-entry LUT makes carrier phases 22.5 degrees apart, and the loop hunts between two of them.
- `test_phase_inversion`, at 180 and 150 degrees: the loop locks with every symbol decision inverted. Over the bits after
  acquisition (60 of 200), all must be wrong without differential encoding, and none with it.

The phase tests run without noise and at full amplitude.

Signals are read right after `await RisingEdge(dut.clk)`, which gives the values the DUT sampled at that edge.

## Report figures

    make figures                                            simulations (tens of minutes: the BER runs) + figures
    uv run pytest tb/cocotb/report_runner.py -k pullin      rerun one group of experiments
    uv run --group dev python tb/cocotb/plot_report.py      figures only, from build/report/data/

`report_runner.py` is not collected by `make cocotb` (pytest only picks up `test_*.py`). Each experiment runs in
`build/report/data/<id>/` with a seed derived from its id, so a rerun gives the same figures; `params.json` there
records the generics and parameters. Every experiment starts from the reference configuration, the generic defaults
(GC_SAMPLE_WIDTH 8, GC_PHASE_WIDTH 24, GC_ADDR_WIDTH 10, GC_SPS 32, GC_CCPS 8: carrier at fs/4, default loop gains)
with GC_DIFF_ENCODING on, and changes only what it studies (`REFERENCE` and `config()` in `report_runner.py`).
`plot_report.py` writes to `doc/figures/` (`--out`, `--format pdf`):

| Figure | Shows | Experiments |
|---|---|---|
| `ber.png` | BER against Eb/N0, without and with differential encoding, against theory, 95 % intervals | `ber_*` |
| `constellation.png` | I/Q at the decision instants, 30° offset: the loop rotates the symbols onto the I axis | `constellation_*` |
| `acquisition.png` | (a) measured S-curve of the phase detector against the I·Q Costas detector, (b) transients, (c) acquisition time against initial offset (no hang-up at 90°) | `acqsweep_*` |
| `phase_plane.png` | frequency pull-in as a phase-plane portrait: two offsets lock, one cycle-slips | `pullin_*` |
| `pullin.png` | frequency correction and residual error against carrier frequency offset | `pullin_*` |
| `inversion.png` | cumulative bit errors at a 150° offset, without and with differential encoding | `inversion_*` |
| `tx_waveform.png` | tx samples for a few bits, without and with differential encoding | `tx_wave_*` |
| `tx_spectrum.png` | tx spectrum of the reference against the ideal one; a 1024- against a 16-entry sine LUT at GC_CCPS 3 (at fs/4 the LUT size does not show) | `tx_spectrum_*` |
| `loop_compare.png` | per-symbol against per-sample Costas loop, residual error and lock time per configuration | none: reads `reports/costas_per_symbol/` and `reports/costas_per_sample/` |
| `ccps_jitter.png` | residual phase jitter against carrier cycles per symbol | `ccps_*` |
| `eye.png` | the I moving sum per sample, folded on the decision instant | `eye_*` |
| `throughput.png` | measured throughput against GC_SPS at clk_en duty 1, 0.5 and 0.25, and latency, at 100 MHz | `throughput_*` |
| `fpga_resources.png` | post-route LUT/FF/LUTRAM and f_max across design iterations (from git history) and against GC_SPS | none: reads `build/fpga/resources.csv` from `scripts/fpga_resources.py` (Vivado, not run by `make figures`) |
| `architecture.svg` | block diagram, hand-drawn SVG | none |
