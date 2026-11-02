# cocotb tests

| File | Contents |
|---|---|
| `bpsk_modem_tests.py` | The cocotb tests: a valid/ready bit driver, an rx bit monitor, and a scoreboard comparing them |
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

Generics: the tests read them from the DUT (`cocotb.top.GC_SPS`), so the VHDL defaults are the only copy.

`bpsk_tests.py`, per configuration:
- `test_reset_state`: after reset, tx is ready and rx produces nothing.
- `test_loopback`: random bits, parametrised over the number of bits, idle gaps between bits, and a random
  `clk_en`. Checks order, value, `rx_bit_trust`, and (with `clk_en` = '1') the latency of GC_SPS + 7 clocks.

Signals are read right after `await RisingEdge(dut.clk)`, which gives the values the DUT sampled at that edge.
