"""Plot the Costas loop of bpsk_rx from the CSV files test_phase_offset writes.

    uv run python tb/cocotb/plot_costas.py                    every CSV of the default configuration
    uv run python tb/cocotb/plot_costas.py path/to/costas_*.csv

Top: carrier phase of the channel (offset + drift) and the rx NCO's phase that tracks it.
Middle: the residual phase error, phi - theta, per symbol.
Bottom: the loop's frequency correction (integral path) against the true drift.
The figure is also saved as costas.png next to the first CSV.
"""
import csv
import sys
from pathlib import Path

import matplotlib.pyplot as plt

DEFAULT_DIR = Path(__file__).resolve().parents[2] / "build" / "cocotb" / "bpsk_channel_harness" / "default"

paths = [Path(p) for p in sys.argv[1:]] or sorted(DEFAULT_DIR.glob("costas_*.csv"))
if not paths:
    sys.exit(f"no costas_*.csv in {DEFAULT_DIR}: run make cocotb PYTEST_ARGS=\"-k bpsk_channel_harness\" first")

fig, (ax_phase, ax_error, ax_freq) = plt.subplots(3, 1, sharex=True, figsize=(9, 8))
for path in paths:
    with open(path) as f:
        rows = list(csv.DictReader(f))
    symbol = [int(r["symbol"]) for r in rows]
    channel = [float(r["channel_deg"]) for r in rows]
    error = [float(r["error_deg"]) for r in rows]
    label = path.stem.removeprefix("costas_")

    (line,) = ax_phase.plot(symbol, channel, "--", label=f"{label}: channel")
    ax_phase.plot(symbol, [c - e for c, e in zip(channel, error)], color=line.get_color(), label=f"{label}: rx NCO")
    ax_error.plot(symbol, error, color=line.get_color(), label=label)
    ax_freq.plot(symbol, [float(r["freq_correction"]) for r in rows], color=line.get_color(), label=label)
    ax_freq.axhline(float(rows[0]["freq_offset"]), color=line.get_color(), linestyle=":", linewidth=1)

ax_phase.set_ylabel("carrier phase (deg)")
ax_phase.legend(fontsize="small", ncol=2)
ax_error.set_ylabel("phase error (deg)")
ax_error.axhline(0, color="grey", linewidth=0.5)
ax_freq.set_ylabel("freq correction\n(cycles/sample)")
ax_freq.set_xlabel("symbol")
ax_freq.ticklabel_format(axis="y", style="sci", scilimits=(0, 0))
for ax in (ax_phase, ax_error, ax_freq):
    ax.grid(alpha=0.3)
fig.suptitle("bpsk_rx Costas loop: phase offset and drift correction")
fig.tight_layout()
png = paths[0].parent / "costas.png"
fig.savefig(png, dpi=120)
print(f"saved {png}")
plt.show()
