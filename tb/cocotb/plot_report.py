"""Figures for the project report, from the runs of report_runner.py (build/report/data/).

    uv run pytest tb/cocotb/report_runner.py      the simulations (tens of minutes)
    uv run python tb/cocotb/plot_report.py        every figure into doc/figures/
    uv run python tb/cocotb/plot_report.py --out some/dir --format pdf

A figure whose data is missing is skipped with a note. loop_compare.png reads the saved
test_phase_offset CSVs in reports/costas_per_symbol/ and reports/costas_per_sample/ instead.
"""
import argparse
import csv
import json
import math
import textwrap
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np
from matplotlib.colors import LinearSegmentedColormap
from matplotlib.ticker import FuncFormatter

ROOT = Path(__file__).resolve().parents[2]
DATA = ROOT / "build" / "report" / "data"

# reference palette (dataviz skill): categorical slots 1-3, text inks, recessive grid; blue ramp for ordered series
BLUE, ORANGE, AQUA = "#2a78d6", "#eb6834", "#1baf7a"
INK, INK_2, INK_3, GRID = "#0b0b0b", "#52514e", "#8a8984", "#e4e3df"
BLUE_RAMP = ["#86b6ef", "#6da7ec", "#5598e7", "#3987e5", "#2a78d6", "#256abf", "#1c5cab", "#184f95", "#104281", "#0d366b"]
RAMP_CMAP = LinearSegmentedColormap.from_list("blue_ramp", BLUE_RAMP)

plt.rcParams.update({
    "figure.facecolor": "white", "axes.facecolor": "white", "savefig.facecolor": "white",
    "axes.edgecolor": INK_3, "axes.labelcolor": INK_2, "axes.titlecolor": INK, "axes.titlesize": 11,
    "axes.titleweight": "bold", "axes.labelsize": 10, "axes.spines.top": False, "axes.spines.right": False,
    "axes.grid": True, "grid.color": GRID, "grid.linewidth": 0.8,
    "xtick.color": INK_2, "ytick.color": INK_2, "xtick.labelsize": 9, "ytick.labelsize": 9,
    "legend.frameon": False, "legend.fontsize": 9, "lines.linewidth": 2, "font.size": 10,
    "figure.titlesize": 12, "figure.titleweight": "bold",
})


# ---------------------------------------------------------------- data
def read_csv(path: Path) -> dict[str, np.ndarray]:
    with open(path) as f:
        rows = list(csv.DictReader(f))
    return {key: np.array([float(r[key]) if r[key] != "" else np.nan for r in rows]) for key in rows[0]}


def runs(prefix: str) -> list[tuple[dict, Path]]:
    """(params.json, folder) of every run whose id starts with prefix, in id order."""
    found = []
    for folder in sorted(DATA.glob(f"{prefix}*")):
        meta = folder / "params.json"
        if meta.exists():
            found.append((json.loads(meta.read_text()), folder))
    return found


def wrap(deg, low=-180.0):
    """Angle in degrees into [low, low + 360)."""
    return (np.asarray(deg) - low) % 360.0 - (-low)


def lock_symbol(error_deg: np.ndarray, threshold: float = 5.0) -> float:
    """First symbol after which |error| stays below threshold; nan if it never does."""
    above = np.flatnonzero(np.abs(error_deg) >= threshold)
    if len(above) == 0:
        return 0.0
    return float(above[-1] + 1) if above[-1] + 1 < len(error_deg) else math.nan


def ber_theory(ebn0_db, diff: bool):
    p = 0.5 * np.vectorize(math.erfc)(np.sqrt(10 ** (np.asarray(ebn0_db) / 10)))
    return 2 * p * (1 - p) if diff else p


def save(fig, name: str, out: Path, fmt: str) -> None:
    path = out / f"{name}.{fmt}"
    fig.savefig(path, dpi=200, bbox_inches="tight")
    plt.close(fig)
    print(f"saved {path.relative_to(ROOT) if path.is_relative_to(ROOT) else path}")


def direct_label(ax, x, y, text, xytext=(4, 0), **kw):
    """Label beside a mark, in text ink: the mark carries the identity, not the label's colour."""
    ax.annotate(text, (x, y), xytext=xytext, textcoords="offset points", va="center", fontsize=9, color=INK_2, **kw)


# ---------------------------------------------------------------- figures
def fig_ber(out, fmt):
    data = [(meta, read_csv(folder / "ber.csv")) for meta, folder in runs("ber_") if (folder / "ber.csv").exists()]
    if not data:
        return print("ber: no data")
    fig, ax = plt.subplots(figsize=(6.4, 4.4))
    grid = np.linspace(0, 8, 200)
    for diff, color, name in ((0, BLUE, "BPSK"), (1, ORANGE, "BPSK, differential encoding")):
        points = sorted((d["ebn0_db"][0], d["n_errors"][0], d["n_bits"][0]) for _, d in data if d["diff_encoding"][0] == diff)
        if not points:
            continue
        ebn0, errors, bits = map(np.array, zip(*points))
        ber = errors / bits
        # 95 % Wilson interval of the binomial proportion. With differential encoding one symbol error spoils two
        # bits, so the count varies like half as many independent trials: n_eff = n / 2
        bits = bits / 2 if diff else bits
        z = 1.96
        centre = (ber + z**2 / (2 * bits)) / (1 + z**2 / bits)
        half = z * np.sqrt(ber * (1 - ber) / bits + z**2 / (4 * bits**2)) / (1 + z**2 / bits)
        ax.plot(grid, ber_theory(grid, bool(diff)), color=color, linewidth=1.2, linestyle="--", alpha=0.8)
        ax.errorbar(ebn0, ber, yerr=[ber - (centre - half), centre + half - ber], fmt="o", color=color,
                    markersize=6, markeredgecolor="white", markeredgewidth=1.5, capsize=3, elinewidth=1.2,
                    label=f"{name}: measured")
    ax.plot([], [], color=INK_3, linestyle="--", linewidth=1.2, label="theory: Q(√(2Eb/N0)), 2p(1−p)")
    ax.set_yscale("log")
    ax.set_ylim(1e-4, 0.3)
    ax.set_xlim(-0.3, 7.5)
    ax.set_xlabel("Eb/N0 (dB)")
    ax.set_ylabel("bit error rate")
    ax.set_title("Bit error rate in AWGN: measured against theory")
    ax.legend(loc="lower left")
    ax.text(0.99, 0.98, "reference configuration (GC_SPS 32), 4000–80000 bits per point, 95 % intervals",
            transform=ax.transAxes, ha="right", va="top", fontsize=8, color=INK_3)
    save(fig, "ber", out, fmt)


def fig_constellation(out, fmt):
    cases = [(f, t) for f, t in (("constellation_clean", "no noise"), ("constellation_10db", "Eb/N0 = 10 dB"))
             if (DATA / f / "symbols.csv").exists()]
    if not cases:
        return print("constellation: no data")
    fig, axes = plt.subplots(1, len(cases), figsize=(5.2 * len(cases), 4.8), squeeze=False)
    for ax, (folder, title) in zip(axes[0], cases):
        d = read_csv(DATA / folder / "symbols.csv")
        scale = np.median(np.hypot(d["i"], d["q"])[-50:])
        n = np.arange(len(d["i"]))
        points = ax.scatter(d["i"] / scale, d["q"] / scale, c=n, cmap=RAMP_CMAP, s=14, linewidths=0.4,
                            edgecolors="white")
        clean = folder.endswith("clean")
        if clean:  # the loop's path with the data removed (each symbol mirrored onto the +I side); noise hides it
            sign = np.where(d["line_symbol"] == 1, 1.0, -1.0)
            path_i, path_q = (sign * d["i"] / scale)[:40], (sign * d["q"] / scale)[:40]
            ax.plot(path_i, path_q, color=INK_2, linewidth=1, zorder=3, label="loop path, data removed")
            ax.legend(loc="lower right", fontsize=8)
        reach = 1.35 if clean else 1.9
        ax.axhline(0, color=INK_3, linewidth=0.8)
        ax.axvline(0, color=INK_3, linewidth=0.8)
        offset = math.radians(30)
        for sign in (1, -1):
            ax.plot([0, sign * math.cos(offset)], [0, sign * math.sin(offset)], color=INK_3, linewidth=1, linestyle=":")
        ax.set_xlim(-reach, reach)
        ax.set_ylim(-reach, reach)
        ax.set_aspect("equal")
        ax.set_xlabel("I (normalised)")
        ax.set_ylabel("Q (normalised)")
        ax.set_title(title)
        cbar = fig.colorbar(points, ax=ax, shrink=0.8, pad=0.02)
        cbar.set_label("symbol", color=INK_2)
        cbar.outline.set_visible(False)
    axes[0][0].annotate("start: 30° offset", (math.cos(offset), math.sin(offset)), xytext=(0.15, 1.12),
                        fontsize=8, color=INK_2, arrowprops={"arrowstyle": "-", "color": INK_3, "linewidth": 0.8})
    fig.suptitle("Constellation at the decision instants: the Costas loop rotates the symbols onto the I axis")
    fig.tight_layout()
    save(fig, "constellation", out, fmt)


def nearest_lock(full_error_deg) -> tuple[np.ndarray, np.ndarray]:
    """(distance in degrees to the nearer lock point 0 or 180, True where that point is 180)."""
    e = wrap(full_error_deg)
    to_zero, to_pi = np.abs(e), 180.0 - np.abs(e)
    return np.minimum(to_zero, to_pi), to_pi < to_zero


def fig_acquisition(out, fmt):
    """Carrier phase acquisition, in the three views of the synchronisation literature: the phase detector's
    S-curve (Rice 2009, ch. 7; Mengali & D'Andrea 1997), the transients, and acquisition time against the
    initial offset, where an I·Q Costas detector shows hang-up near 90 degrees (Gardner 1977)."""
    sweep = []
    for meta, folder in runs("acqsweep_"):
        if (folder / "symbols.csv").exists():
            sweep.append((meta["params"]["phase_deg"], read_csv(folder / "symbols.csv")))
    if not sweep:
        return print("acquisition: no data")
    sweep.sort(key=lambda item: item[0])
    fig, (ax_s, ax_t, ax_l) = plt.subplots(1, 3, figsize=(14, 4.4), gridspec_kw={"width_ratios": [1, 1.25, 1.1]})

    # (a) S-curve: the RTL's error sign(I)·Q against the phase error, every symbol of every run
    phase, error = [], []
    for _, d in sweep:
        amplitude = np.median(np.hypot(d["i"], d["q"])[-50:])
        phase.append(wrap(d["full_error_deg"]))
        error.append(np.sign(d["i"]) * d["q"] / amplitude)
    phi = np.linspace(-180, 180, 1441)
    rad = np.radians(phi)
    hard = np.sin(rad) * np.sign(np.cos(rad))
    hard[np.abs(np.abs(phi) - 90) < 0.3] = np.nan  # no line across the jump
    ax_s.plot(phi, 0.5 * np.sin(2 * rad), color=INK_3, linestyle=":", linewidth=1.4, label="I·Q detector: ½ sin 2φ")
    ax_s.plot(phi, hard, color=INK_3, linestyle="--", linewidth=1.2, label="sign(I)·Q: sin φ · sign(cos φ)")
    ax_s.plot(np.concatenate(phase), np.concatenate(error), "o", color=BLUE, markersize=2.5, alpha=0.5,
              markeredgewidth=0, label="bpsk_rx, measured")
    for x in (-180, 0, 180):
        ax_s.plot(x, 0, "o", color=INK, markersize=7, zorder=5)
    for x in (-90, 90):
        ax_s.plot(x, 0, "o", color="white", markeredgecolor=INK, markersize=7, zorder=5)
    ax_s.text(10, -0.2, "stable", ha="left", fontsize=8, color=INK_2)
    ax_s.text(97, 0.12, "unstable", ha="left", fontsize=8, color=INK_2)
    ax_s.set_xticks([-180, -90, 0, 90, 180])
    ax_s.set_xlim(-185, 185)
    ax_s.set_ylim(-1.25, 1.45)
    ax_s.set_xlabel("phase error φ (deg)")
    ax_s.set_ylabel("detector output (normalised)")
    ax_s.set_title("(a) Phase detector S-curve", loc="left")
    ax_s.legend(loc="upper left", fontsize=8)

    # (b) transients from a few initial offsets on both sides of 90 degrees
    shown = [30, 60, 85, 95, 120, 150]
    data = [(p, d) for p, d in sweep if p in shown]
    for k, (p0, d) in enumerate(data):
        color = BLUE_RAMP[round(k * (len(BLUE_RAMP) - 1) / max(1, len(data) - 1))]
        e = wrap(d["full_error_deg"], low=-90.0)
        ax_t.plot(d["symbol"], e, color=color, linewidth=1.6)
        direct_label(ax_t, d["symbol"][0], e[0], f"{p0:g}°", xytext=(-4, 0), ha="right")
    for lock, text in ((0, "lock at 0°"), (180, "lock at 180°: symbols inverted")):
        ax_t.axhline(lock, color=INK_3, linewidth=1, linestyle="--")
        ax_t.text(80, lock + 4, text, ha="right", va="bottom", fontsize=8, color=INK_2)
    ax_t.set_xlim(-10, 80)
    ax_t.set_ylim(-25, 205)
    ax_t.set_yticks([0, 45, 90, 135, 180])
    ax_t.set_xlabel("symbol")
    ax_t.set_ylabel("carrier phase error (deg)")
    ax_t.set_title("(b) Transients from initial offsets", loc="left")

    # (c) acquisition time against the initial offset, by lock point
    p0s, times, to_pi = [], [], []
    for p0, d in sweep:
        dist, at_pi = nearest_lock(d["full_error_deg"])
        p0s.append(p0)
        times.append(lock_symbol(dist))
        to_pi.append(bool(at_pi[-1]))
    p0s, times, to_pi = np.array(p0s), np.array(times), np.array(to_pi)
    for mask, color, name in ((~to_pi, BLUE, "locks at 0°"), (to_pi, ORANGE, "locks at 180° (inverted)")):
        ax_l.plot(p0s[mask], times[mask], "o", color=color, markersize=5, markeredgecolor="white",
                  markeredgewidth=1, label=name)
    for x in (-90, 90):
        ax_l.axvline(x, color=INK_3, linewidth=1, linestyle=":")
    ax_l.set_xticks([-180, -90, 0, 90, 180])
    ax_l.set_xlim(-185, 185)
    ax_l.set_ylim(0, 42)
    ax_l.text(0, 40.5, "no hang-up at ±90°", ha="center", va="top", fontsize=8, color=INK_2)
    ax_l.set_xlabel("initial phase offset (deg)")
    ax_l.set_ylabel("symbols until |error| < 5°")
    ax_l.set_title("(c) Acquisition time", loc="left")
    ax_l.legend(loc="upper left", fontsize=8)

    fig.suptitle("Carrier phase acquisition of the Costas loop")
    fig.tight_layout()
    fig.text(0.99, 0.0, "reference configuration, no noise, initial offsets every 5° and finer near 90°; "
             "the hard-limited detector keeps full restoring force next to the unstable point",
             ha="right", va="top", fontsize=8, color=INK_3)
    save(fig, "acquisition", out, fmt)


def fig_phase_plane(out, fmt):
    """Phase-plane portrait of frequency pull-in (Gardner, Phaselock Techniques): frequency correction against
    the unwrapped phase error, for offsets the loop locks to and one it cycle-slips through."""
    cases = [(o, DATA / f"pullin_{o:g}" / "symbols.csv") for o in (1e-3, 3e-3, 5e-3)]
    cases = [(o, path) for o, path in cases if path.exists()]
    if not cases:
        return print("phase plane: no data")
    fig, ax = plt.subplots(figsize=(6.6, 4.6))
    for (offset, path), color in zip(cases, (BLUE, AQUA, ORANGE)):
        d = read_csv(path)
        e = d["error_deg"].copy()  # wrapped to (-90, 90]: 0 and 180 are the same lock point here
        f = d["freq_correction"] / offset
        jumps = np.flatnonzero(np.abs(np.diff(e)) > 90) + 1  # a slip wraps the error: break the line there
        e, f = np.insert(e, jumps, np.nan), np.insert(f, jumps, np.nan)
        slipping = offset >= 5e-3  # drawn thin and underneath: hundreds of slips form a band
        ax.plot(e, f, color=color, linewidth=0.6 if slipping else 1.4, alpha=0.6 if slipping else 1.0,
                zorder=1 if slipping else 3, label=f"offset {offset:g} cycles/sample")
        ax.plot(e[0], f[0], "o", color=color, markersize=6, markeredgecolor="white")
    ax.plot(0, 1, "o", color=INK, markersize=7, zorder=5)
    ax.annotate("lock: zero phase error,\ncorrection = offset", (0, 1), xytext=(-70, 0.93), fontsize=8, color=INK_2,
                arrowprops={"arrowstyle": "-", "color": INK_3, "linewidth": 0.8})
    ax.axhline(1, color=INK_3, linestyle="--", linewidth=1)
    ax.set_xlim(-90, 90)
    ax.set_xticks([-90, -45, 0, 45, 90])
    ax.set_xlabel("phase error, modulo 180° (deg)")
    ax.set_ylabel("frequency correction / offset")
    ax.set_title("Frequency pull-in: phase plane")
    ax.legend(loc="center left", fontsize=8)
    fig.text(0.99, 0.0, "reference configuration, no noise; dots: start. At 5e-3 the error keeps slipping round "
             "and the correction never builds up",
             ha="right", va="top", fontsize=8, color=INK_3)
    save(fig, "phase_plane", out, fmt)


def fig_pullin(out, fmt):
    data = []
    for meta, folder in runs("pullin_"):
        if (folder / "symbols.csv").exists():
            d = read_csv(folder / "symbols.csv")
            data.append((meta["params"]["freq_offset"], d))
    if not data:
        return print("pull-in: no data")
    data.sort(key=lambda item: item[0])
    offsets = np.array([o for o, _ in data])
    final_freq = np.array([np.mean(d["freq_correction"][-50:]) for _, d in data])
    residual = np.array([np.max(np.abs(d["error_deg"][-50:])) for _, d in data])
    fc, limit = 8 / 32, 8 / 32 / 8  # default carrier, GC_FREQ_LIMIT = an eighth of the step

    fig, (ax_f, ax_e) = plt.subplots(2, 1, sharex=True, figsize=(6.4, 6.2))
    ideal = np.array([offsets.min() / 2, limit * 1.3])
    ax_f.plot(ideal, ideal, color=INK_3, linestyle="--", linewidth=1.2, label="ideal: correction = offset")
    ax_f.plot(offsets, np.abs(final_freq), "o-", color=BLUE, markersize=6, markeredgecolor="white",
              markeredgewidth=1.5, label="loop frequency correction, last 50 symbols")
    ax_f.set_yscale("log")
    ax_f.set_ylabel("frequency (cycles/sample)")
    ax_f.legend(loc="upper left")
    ax_f.set_title("Pull-in range: frequency offset the loop can track")
    locked = residual < 5
    ax_e.plot(offsets, residual, "-", color=BLUE, linewidth=1.2)
    ax_e.plot(offsets[locked], residual[locked], "o", color=BLUE, markersize=6, markeredgecolor="white",
              markeredgewidth=1.5, label="locked (< 5°)")
    ax_e.plot(offsets[~locked], residual[~locked], "X", color=ORANGE, markersize=8, markeredgecolor="white",
              markeredgewidth=1, label="not locked")
    ax_e.axhline(5, color=INK_3, linestyle="--", linewidth=1)
    ax_e.set_yscale("log")
    ax_e.set_xscale("log")
    ax_e.set_ylabel("worst |phase error|,\nlast 50 symbols (deg)")
    ax_e.set_xlabel("carrier frequency offset (cycles/sample)")
    ax_e.legend(loc="upper left")
    for ax in (ax_f, ax_e):
        ax.axvline(limit, color=INK_3, linewidth=1, linestyle=":")
    ax_f.text(limit, ax_f.get_ylim()[0], "GC_FREQ_LIMIT\n(fc / 8) ", fontsize=8, color=INK_2, va="bottom",
              ha="right")
    fig.tight_layout()
    fig.text(0.99, 0.0, f"carrier fc = {fc:g} cycles/sample (GC_SPS 32, GC_CCPS 8), no noise, 400 bits per offset",
             ha="right", va="top", fontsize=8, color=INK_3)
    save(fig, "pullin", out, fmt)


def fig_inversion(out, fmt):
    cases = [(diff, DATA / f"inversion_diff{diff}" / "bits.csv") for diff in (0, 1)]
    cases = [(diff, path) for diff, path in cases if path.exists()]
    if not cases:
        return print("inversion: no data")
    fig, ax = plt.subplots(figsize=(6.4, 4.2))
    n = 0
    for diff, path in cases:
        d = read_csv(path)
        errors = np.nan_to_num(d["error"])
        n = len(errors)
        color, name = (ORANGE, "differential encoding") if diff else (BLUE, "no encoding")
        cumulative = np.cumsum(errors)
        ax.plot(d["bit_index"], cumulative, color=color, label=name)
        count = int(cumulative[-1])
        direct_label(ax, d["bit_index"][-1], cumulative[-1], f"{count} error{'s' if count != 1 else ''}")
    ax.plot([0, n], [0, n], color=INK_3, linestyle="--", linewidth=1, label="every bit wrong")
    ax.set_xlabel("bit")
    ax.set_ylabel("cumulative bit errors")
    ax.set_title("Carrier offset of 150°: the loop locks at 180°")
    ax.set_xlim(0, n * 1.15)
    ax.legend(loc="upper left")
    save(fig, "inversion", out, fmt)


def fig_tx_waveform(out, fmt):
    cases = [(diff, DATA / f"tx_wave_diff{diff}") for diff in (0, 1) if (DATA / f"tx_wave_diff{diff}" / "tx.csv").exists()]
    if not cases:
        return print("tx waveform: no data")
    fig, axes = plt.subplots(len(cases), 1, sharex=True, figsize=(7.6, 2.4 * len(cases) + 0.6), squeeze=False)
    for ax, (diff, folder) in zip(axes[:, 0], cases):
        meta = json.loads((folder / "params.json").read_text())
        sps = meta["generics"].get("GC_SPS", 32)  # the reference value when the run does not set it
        tx, bits = read_csv(folder / "tx.csv"), read_csv(folder / "bits.csv")["bit"].astype(int)
        symbols, prev = [], 0
        for b in bits:
            prev = b ^ prev if diff else b
            symbols.append(prev)
        t = tx["sample"] / sps
        amplitude = np.max(np.abs(tx["value"]))
        # the continuous carrier each symbol samples, for the eye: few samples per carrier cycle at fs/4
        ccps = meta["generics"].get("GC_CCPS", sps // 4)
        fine = np.linspace(0, len(symbols), len(symbols) * 400, endpoint=False)
        sign = np.array([2 * symbols[int(x)] - 1 for x in fine])
        ax.plot(fine, sign * amplitude * np.sin(2 * np.pi * ccps * (fine % 1)), color=INK_3, linewidth=0.8,
                label="carrier ± sin")
        sample_symbol = np.array([symbols[min(int(x), len(symbols) - 1)] for x in t])
        for value, color in ((1, BLUE), (0, ORANGE)):
            ax.plot(t[sample_symbol == value], tx["value"][sample_symbol == value], "o", color=color, markersize=2.8,
                    label=f"samples, symbol {value} ({'+' if value else '−'}sin)")
        for k, (b, s) in enumerate(zip(bits, symbols)):
            flip = k > 0 and s != symbols[k - 1]
            ax.axvline(k, color=INK if flip else GRID, linewidth=1.2 if flip else 1, linestyle="--" if flip else "-",
                       zorder=0)
            ax.text(k + 0.5, amplitude * 1.32, f"bit {b}", ha="center", fontsize=8, color=INK)
            ax.text(k + 0.5, amplitude * 1.12, f"sym {s}", ha="center", fontsize=8, color=INK_2)
        ax.set_ylim(-amplitude * 1.2, amplitude * 1.55)
        ax.set_yticks([-amplitude, 0, amplitude])
        ax.set_ylabel("tx_sample_data")
        ax.set_title("differential encoding: symbol = bit xor previous symbol" if diff else "no encoding: symbol = bit",
                     loc="left", fontsize=10)
        ax.grid(axis="x", visible=False)
    axes[0, 0].legend(loc="lower left", bbox_to_anchor=(0, 1.12), ncol=3, fontsize=8)
    axes[-1, 0].set_xlabel("time (symbols); dashed: 180° phase flip at a symbol change")
    axes[-1, 0].set_xlim(0, len(bits))
    fig.suptitle("bpsk_tx output: a 180° phase flip wherever the symbol changes")
    fig.tight_layout()
    save(fig, "tx_waveform", out, fmt)


def welch_psd(x: np.ndarray, segment: int = 4096) -> tuple[np.ndarray, np.ndarray]:
    """Averaged periodogram, Hann window, 50 % overlap; frequency in cycles/sample (0 .. 0.5)."""
    window = np.hanning(segment)
    step = segment // 2
    spectra = [np.abs(np.fft.rfft(window * x[start:start + segment])) ** 2
               for start in range(0, len(x) - segment + 1, step)]
    return np.fft.rfftfreq(segment), np.mean(spectra, axis=0)


def ideal_spectrum(sps: int, ccps: int, n_fft: int = 1 << 15) -> tuple[np.ndarray, np.ndarray]:
    """PSD (dB, peak 0) for random independent symbols: |P(f)|² of one symbol's ideal, unquantised carrier burst."""
    theory = np.abs(np.fft.rfft(np.sin(2 * np.pi * ccps * np.arange(sps) / sps), n_fft)) ** 2
    return np.fft.rfftfreq(n_fft), 10 * np.log10(theory / theory.max() + 1e-14)


def fig_tx_spectrum(out, fmt):
    panels = [
        ("Reference configuration (GC_CCPS 8: carrier at fs/4)", 8, [("tx_spectrum_ref", BLUE, "measured, 1024-entry LUT")]),
        ("LUT size at GC_CCPS 3 (at fs/4 the NCO reads only 4 exact phases)", 3,
         [("tx_spectrum_ccps3_m10", BLUE, "1024-entry LUT (GC_ADDR_WIDTH 10)"),
          ("tx_spectrum_ccps3_m4", ORANGE, "16-entry LUT (GC_ADDR_WIDTH 4)")]),
    ]
    panels = [(t, c, [r for r in runs_ if (DATA / r[0] / "tx.csv").exists()]) for t, c, runs_ in panels]
    panels = [panel for panel in panels if panel[2]]
    if not panels:
        return print("tx spectrum: no data")
    sps = 32
    fig, axes = plt.subplots(len(panels), 1, sharex=True, figsize=(7.2, 3.3 * len(panels) + 0.4), squeeze=False)
    for ax, (title, ccps, cases) in zip(axes[:, 0], panels):
        for folder, color, label in cases:
            f, psd = welch_psd(read_csv(DATA / folder / "tx.csv")["value"])
            ax.plot(f, 10 * np.log10(psd / psd.max() + 1e-14), color=color, linewidth=1.2, label=label)
        ax.plot(*ideal_spectrum(sps, ccps), color=INK_3, linewidth=1, linestyle="--", label="theory: ideal carrier")
        fc = ccps / sps
        ax.axvline(fc, color=INK_3, linewidth=1, linestyle=":")
        ax.text(fc, 3, " carrier", fontsize=8, color=INK_2, va="bottom")
        ax.set_ylim(-90, 8)
        ax.set_ylabel("power (dB, re peak)")
        ax.set_title(title, loc="left", fontsize=10)
        ax.legend(loc="upper right")
        if ccps == 3 and any(folder.endswith("m4") for folder, _, _ in cases):
            spur = 13 / 32  # the 16-entry LUT's phase steps of 1/16 cycle put a harmonic of the carrier burst here
            ax.annotate("LUT phase quantisation", (spur, -20), xytext=(0.22, -18), fontsize=8, color=INK_2,
                        arrowprops={"arrowstyle": "-", "color": INK_3, "linewidth": 0.8})
    axes[-1, 0].set_xlim(0, 0.5)
    axes[-1, 0].set_xlabel("frequency (cycles/sample)")
    fig.suptitle("Transmit spectrum, random bits")
    fig.tight_layout()
    fig.text(0.99, 0.0, f"GC_SPS {sps}, GC_SAMPLE_WIDTH 8, 2000 bits, Hann window, 4096-point segments",
             ha="right", va="top", fontsize=8, color=INK_3)
    save(fig, "tx_spectrum", out, fmt)


def fig_throughput(out, fmt, f_clk_mhz: float = 100.0):
    rows = [read_csv(folder / "throughput.csv") for _, folder in runs("throughput_")
            if (folder / "throughput.csv").exists()]
    if not rows:
        return print("throughput: no data")
    table = sorted((r["duty"][0], r["sps"][0], r["bits_per_clock"][0], r["latency_clocks"][0], r["channel_latency"][0])
                   for r in rows)
    fig, (ax_t, ax_l) = plt.subplots(1, 2, figsize=(10, 4.2))
    sps_grid = np.array(sorted({row[1] for row in table}))
    for duty, color in ((1.0, BLUE), (0.5, ORANGE), (0.25, AQUA)):
        points = [(sps, bpc) for d, sps, bpc, _, _ in table if d == duty]
        if not points:
            continue
        sps, bpc = map(np.array, zip(*points))
        ax_t.plot(sps_grid, f_clk_mhz * duty / sps_grid, color=color, linestyle="--", linewidth=1.2)
        ax_t.plot(sps, f_clk_mhz * bpc, "o", color=color, markersize=7, markeredgecolor="white",
                  markeredgewidth=1.5, label=f"clk_en duty {duty:g}")
    ax_t.plot([], [], color=INK_3, linestyle="--", linewidth=1.2, label="theory: f_clk · duty / GC_SPS")
    ax_t.set_xscale("log", base=2)
    ax_t.set_yscale("log")
    ax_t.yaxis.set_major_formatter(FuncFormatter(lambda v, _: f"{v:g}"))
    ax_t.set_xticks(sps_grid, [f"{s:g}" for s in sps_grid])
    ax_t.set_xlabel("samples per symbol (GC_SPS)")
    ax_t.set_ylabel(f"throughput at {f_clk_mhz:g} MHz (Mbit/s)")
    ax_t.set_title("Throughput: one bit per GC_SPS enabled clocks")
    ax_t.legend(loc="upper right")

    points = [(sps, latency - channel - 1) for d, sps, _, latency, channel in table if d == 1.0]
    if points:
        sps, clocks = map(np.array, zip(*points))
        ax_l.plot(sps_grid, (sps_grid + 7) / f_clk_mhz, color=INK_3, linestyle="--", linewidth=1.2,
                  label="spec: GC_SPS + 7 clocks")
        ax_l.plot(sps, clocks / f_clk_mhz, "o", color=BLUE, markersize=7, markeredgecolor="white",
                  markeredgewidth=1.5, label="measured, bpsk_modem")
        for x, c in zip(sps, clocks):
            direct_label(ax_l, x, c / f_clk_mhz, f"{c:g} clk", xytext=(6, -8))
    ax_l.set_xscale("log", base=2)
    ax_l.set_yscale("log")
    ax_l.set_yticks([0.1, 0.2, 0.5, 1, 2])
    ax_l.yaxis.set_major_formatter(FuncFormatter(lambda v, _: f"{v:g}"))
    ax_l.yaxis.set_minor_formatter(FuncFormatter(lambda v, _: ""))
    ax_l.set_xticks(sps_grid, [f"{s:g}" for s in sps_grid])
    ax_l.set_xlabel("samples per symbol (GC_SPS)")
    ax_l.set_ylabel(f"latency at {f_clk_mhz:g} MHz (µs)")
    ax_l.set_title("Latency, bit in to bit out (clk_en = 1)")
    ax_l.legend(loc="upper left")
    for ax in (ax_t, ax_l):
        ax.axvline(32, color=GRID, linewidth=6, zorder=0)
    ax_t.text(32, ax_t.get_ylim()[0], " reference", fontsize=8, color=INK_2, va="bottom")
    fig.tight_layout()
    fig.text(0.99, 0.0, "carrier at fs/4 (GC_CCPS = GC_SPS / 4), 200 back-to-back random bits per point, "
             "throughput scales with the clock (timing met at 100 MHz)", ha="right", va="top", fontsize=8, color=INK_3)
    save(fig, "throughput", out, fmt)


def offset_metrics(folder: Path) -> tuple[float, float] | None:
    """(worst residual over the last 50 symbols, worst lock symbol) over the four test_phase_offset cases."""
    files = sorted(folder.glob("costas_*.csv"))
    if len(files) != 4:
        return None
    residual, lock = [], []
    for path in files:
        e = read_csv(path)["error_deg"]
        residual.append(np.max(np.abs(e[-50:])))
        lock.append(lock_symbol(e))
    return max(residual), max(lock)


def fig_loop_compare(out, fmt):
    sym_dir, smp_dir = ROOT / "reports" / "costas_per_symbol", ROOT / "reports" / "costas_per_sample"
    if not (sym_dir.exists() and smp_dir.exists()):
        return print("loop compare: reports/costas_per_symbol or costas_per_sample missing")
    configs = []
    for folder in sorted(sym_dir.iterdir()):
        other = smp_dir / folder.name
        if folder.is_dir() and other.is_dir() and "ADDR_WIDTH-4" not in folder.name:
            a, b = offset_metrics(folder), offset_metrics(other)
            if a and b:
                configs.append((folder.name, a, b))
    if not configs:
        return print("loop compare: no common configurations")

    def short(name):
        """"GC_SPS-32_GC_CCPS-7_GC_SAMPLE_WIDTH-16" -> "SPS 32\nCCPS 7\nL 16" (L, N, M as in the headers)."""
        if name == "default":
            return "default\n(SPS 32\nCCPS 8)"
        letters = {"SAMPLE_WIDTH": "L", "PHASE_WIDTH": "N", "ADDR_WIDTH": "M"}
        parts = [part.split("-") for part in name.removeprefix("GC_").split("_GC_")]
        return "\n".join(f"{letters.get(key, key)} {value}" for key, value in parts)

    configs.sort(key=lambda c: (c[0] != "default", c[0]))

    labels = [short(name) for name, _, _ in configs]
    x = np.arange(len(configs))
    width = 0.38
    fig, (ax_r, ax_l) = plt.subplots(1, 2, figsize=(10, 4.2))
    for ax, index, ylabel, title in ((ax_r, 0, "worst |phase error|, last 50 symbols (deg)", "Residual error"),
                                     (ax_l, 1, "symbols until |error| < 5°", "Lock time")):
        for offset, (k, color, name) in zip((-width / 2, width / 2), ((1, BLUE, "per-symbol update"),
                                                                       (2, ORANGE, "per-sample update"))):
            values = [c[k][index] for c in configs]
            ax.bar(x + offset, values, width - 0.04, color=color, label=name)
        ax.set_xticks(x, labels, fontsize=8)
        ax.set_ylabel(ylabel)
        ax.set_title(title)
        ax.grid(axis="x", visible=False)
        ax.set_axisbelow(True)
    fig.suptitle("Costas loop: per-symbol against per-sample update (worst of four offset/drift cases)")
    fig.tight_layout(rect=(0, 0, 1, 0.93))
    fig.legend(*ax_r.get_legend_handles_labels(), loc="upper center", ncol=2, bbox_to_anchor=(0.5, 0.94))
    save(fig, "loop_compare", out, fmt)


def fig_ccps(out, fmt):
    data = []
    for meta, folder in runs("ccps_"):
        if (folder / "symbols.csv").exists():
            e = read_csv(folder / "symbols.csv")["error_deg"][-100:]
            data.append((meta["generics"]["GC_CCPS"], np.sqrt(np.mean(e**2)), np.max(np.abs(e))))
    if not data:
        return print("ccps: no data")
    data.sort()
    ccps, rms, worst = map(np.array, zip(*data))
    fig, ax = plt.subplots(figsize=(6.4, 4.2))
    ax.plot(ccps, worst, "o-", color=ORANGE, markersize=6, markeredgecolor="white", markeredgewidth=1.5,
            label="worst |error|")
    ax.plot(ccps, rms, "o-", color=BLUE, markersize=6, markeredgecolor="white", markeredgewidth=1.5,
            label="rms error")
    ax.set_xscale("log", base=2)
    ax.set_xticks(ccps, [f"{c:g}" for c in ccps])
    ax.set_xlabel("carrier cycles per symbol (GC_CCPS; GC_SPS 32, reference otherwise)")
    ax.set_ylabel("phase error, last 100 symbols (deg)")
    ax.set_ylim(bottom=0)
    ax.set_title("Residual phase jitter is highest with 1-2 carrier cycles per symbol")
    ax.legend(loc="upper right")
    ax.text(0.99, 0.72, "with few carrier cycles per symbol, the double-frequency\nterm leaks into Q at bit changes"
            "\n30° offset, no noise, one run per point",
            transform=ax.transAxes, ha="right", fontsize=8, color=INK_3)
    save(fig, "ccps_jitter", out, fmt)


def fig_eye(out, fmt):
    cases = [(f, t) for f, t in (("eye_clean", "no noise"), ("eye_10db", "Eb/N0 = 10 dB"))
             if (DATA / f / "samples.csv").exists()]
    if not cases:
        return print("eye: no data")
    fig, axes = plt.subplots(1, len(cases), sharey=True, figsize=(5.2 * len(cases), 4.2), squeeze=False)
    for ax, (folder, title) in zip(axes[0], cases):
        sps = json.loads((DATA / folder / "params.json").read_text())["generics"].get("GC_SPS", 32)
        d = read_csv(DATA / folder / "samples.csv")
        i, decisions = d["i"], np.flatnonzero(d["decision"] == 1)
        peak = np.median(np.abs(i[decisions[10:]]))
        t = np.arange(-sps, sps + 1) / sps
        for n in decisions[10:110]:  # skip the start-up symbols; 100 traces
            ax.plot(t, i[n - sps:n + sps + 1] / peak, color=BLUE, linewidth=0.6, alpha=0.18)
        ax.axvline(0, color=INK_3, linewidth=1, linestyle="--")
        ax.text(0.02, 1.25, "decision", fontsize=8, color=INK_2)
        ax.set_xlim(-1, 1)
        ax.set_ylim(-1.4, 1.4)
        ax.set_xlabel("time from decision instant (symbols)")
        ax.set_title(title)
    axes[0][0].set_ylabel("I moving sum (normalised)")
    fig.suptitle("Matched filter output per sample: the decision is taken at the peak")
    fig.tight_layout()
    save(fig, "eye", out, fmt)


def fig_fpga_resources(out, fmt):
    """Post-route resources and timing of bpsk_modem from scripts/fpga_resources.py: across the design
    iterations of the receiver, and across GC_SPS for the current design."""
    path = ROOT / "build" / "fpga" / "resources.csv"
    if not path.exists():
        return print("fpga resources: no build/fpga/resources.csv (run scripts/fpga_resources.py)")
    with open(path) as f:
        rows = list(csv.DictReader(f))
    iters = [r for r in rows if r["group"] == "iteration"]
    sweep = sorted((r for r in rows if r["group"] == "sps"), key=lambda r: int(r["generics"].split()[0].split("=")[1]))
    fig, (ax_r, ax_f, ax_s) = plt.subplots(1, 3, figsize=(15, 4.6), gridspec_kw={"width_ratios": [1.7, 1.1, 1]})

    # (a) resources per iteration
    labels = [f"{k + 1}\n" + "\n".join(textwrap.wrap(r["label"].replace(",", ""), 12, break_long_words=False)) for k, r in enumerate(iters)]
    x = np.arange(len(iters))
    width = 0.27
    for k, (key, color, name) in enumerate((("lut", BLUE, "LUT (logic + LUTRAM)"), ("ff", ORANGE, "flip-flop"),
                                            ("lutram", AQUA, "LUT as memory"))):
        values = [float(r[key]) for r in iters]
        bars = ax_r.bar(x + (k - 1) * width, values, width - 0.03, color=color, label=name)
        if key == "ff":
            for bar, v in zip(bars, values):
                ax_r.text(bar.get_x() + bar.get_width() / 2, v + 15, f"{v:.0f}", ha="center", fontsize=7.5, color=INK_2)
    ax_r.set_xticks(x, labels, fontsize=8)
    ax_r.set_ylabel("cells used (post-route)")
    ax_r.set_title("(a) Resources across design iterations", loc="left")
    ax_r.legend(loc="upper left", fontsize=8)
    ax_r.grid(axis="x", visible=False)
    ax_r.set_axisbelow(True)

    # (b) achievable clock per iteration
    fmax = np.array([float(r["fmax_mhz"]) for r in iters])
    met = fmax >= 100
    ax_f.bar(x[met], fmax[met], 0.6, color=BLUE, label="meets 100 MHz")
    ax_f.bar(x[~met], fmax[~met], 0.6, color=ORANGE, label="fails 100 MHz")
    for xi, v in zip(x, fmax):
        ax_f.text(xi, v + 3, f"{v:.0f}", ha="center", fontsize=8, color=INK_2)
    for k, r in enumerate(iters):  # the pipelining steps: gain over the iteration before
        if "pipelined" in r["label"] and k > 0:
            ax_f.annotate(f"pipelined\n+{fmax[k] - fmax[k - 1]:.0f} MHz", (k, fmax[k] + 14), ha="center",
                          fontsize=8, color=INK)
    ax_f.axhline(100, color=INK_3, linestyle="--", linewidth=1)
    ax_f.set_ylim(0, 185)
    ax_f.legend(loc="upper right", fontsize=8)
    ax_f.set_xticks(x, [str(k + 1) for k in range(len(iters))], fontsize=9)
    ax_f.set_xlabel("design iteration (as in (a))")
    ax_f.set_ylabel("f_max estimate (MHz) = 1 / (T − WNS)")
    ax_f.set_title("(b) Timing across iterations", loc="left")
    ax_f.grid(axis="x", visible=False)
    ax_f.set_axisbelow(True)

    # (c) scaling with samples per symbol
    sps = np.array([int(r["generics"].split()[0].split("=")[1]) for r in sweep])
    for key, color, name in (("lut", BLUE, "LUT"), ("ff", ORANGE, "flip-flop"), ("lutram", AQUA, "LUT as memory")):
        ax_s.plot(sps, [float(r[key]) for r in sweep], "o-", color=color, markersize=6, markeredgecolor="white",
                  markeredgewidth=1.5, label=name)
    ax_s.set_xscale("log", base=2)
    ax_s.set_xticks(sps, [str(v) for v in sps])
    ax_s.set_ylim(bottom=0)
    ax_s.set_xlabel("samples per symbol (GC_SPS)")
    ax_s.set_ylabel("cells used (post-route)")
    ax_s.set_title("(c) Scaling with GC_SPS", loc="left")
    ax_s.legend(loc="upper left", fontsize=8)

    fig.suptitle("FPGA implementation of bpsk_modem (tx + rx), Artix-7 xc7a35t, Vivado post-route")
    fig.tight_layout()
    fig.text(0.99, 0.0, "every variant: default generics (L 8, N 24, M 10, GC_SPS 32) unless swept, 10 ns clock constraint; "
             "DSP48: " + ", ".join(f"{float(r['dsp']):.0f}" for r in iters) + " per iteration",
             ha="right", va="top", fontsize=8, color=INK_3)
    save(fig, "fpga_resources", out, fmt)


FIGURES = [fig_ber, fig_constellation, fig_acquisition, fig_pullin, fig_inversion, fig_tx_waveform, fig_tx_spectrum,
           fig_loop_compare, fig_ccps, fig_eye, fig_throughput, fig_phase_plane,
           fig_fpga_resources]

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", type=Path, default=ROOT / "doc" / "figures", help="output folder")
    parser.add_argument("--format", default="png", help="png, pdf or svg")
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    for figure in FIGURES:
        figure(args.out, args.format)
