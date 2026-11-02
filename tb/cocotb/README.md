# cocotb tests

| File | Contents |
|---|---|
| `bpsk_tests.py` | Verification components: bit driver and monitors, `ClkEnDriver`, `ModemModel` (expected bits, latency and trust), `BitScoreboard`, and `BpskTestbench`, which wires them up for one DUT |
| `bpsk_sample_tests.py` | Tests of `bpsk_modem` (tx -> rx directly) |
| `bpsk_channel_tests.py` | Tests of `bpsk_channel_harness` (tx -> channel model -> rx): noise, carrier phase, phase inversion |
| `channel.py` | Channel models between `tx_sample_*` and `rx_sample_*` (`AwgnChannel`, `PhaseOffsetChannel`), and `PhaseErrorMonitor`, which logs the Costas loop's residual phase error |
| `dut_generics.py` | `DutGenerics`: the generics of the DUT the tests need (and values derived from them), read once per component with `DutGenerics.from_dut(dut)` |
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
  loop's phase error over the last 50 symbols must stay below 5 degrees. Fails at GC_PHASE_WIDTH=8 / GC_ADDR_WIDTH=4: the
  16-entry LUT makes carrier phases 22.5 degrees apart, and the loop hunts between two of them.
- `test_phase_inversion`, at 180 and 150 degrees: the loop locks with every symbol decision inverted. Over the bits after
  acquisition (60 of 200), all must be wrong without differential encoding, and none with it.

The phase tests run without noise and at full amplitude.

Signals are read right after `await RisingEdge(dut.clk)`, which gives the values the DUT sampled at that edge.
