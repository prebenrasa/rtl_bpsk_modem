"""Post-route FPGA resources and timing of bpsk_modem, across design iterations and across GC_SPS.

    uv run python scripts/fpga_resources.py            every variant (Vivado, several minutes), then the CSV
    uv run python scripts/fpga_resources.py --jobs 2   fewer parallel Vivado runs (each needs about 2-3 GB)

Variants:
  - design iterations: a commit from git history each, default generics (checked out into
    build/fpga/worktrees/<commit>, with ip/rtl_nco linked from this checkout: the NCO is the same commit in all);
  - GC_SPS sweep: the working tree, GC_SPS 8 .. 128 with the carrier at fs/4 (GC_CCPS = GC_SPS / 4).
Each runs scripts/fpga_resources.tcl in build/fpga/<variant>/; the numbers go to build/fpga/resources.csv,
which tb/cocotb/plot_report.py turns into fpga_resources.png. Needs VIVADO in local.mk (or vivado on PATH).
"""
import argparse
import csv
import re
import subprocess
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build" / "fpga"
TOP, PART = "bpsk_modem", "xc7a35tcpg236-1"

# commit, short label, what changed (in order)
ITERATIONS = [
    ("ac6d95c", "correlator, one-cycle MAC", "ideal channel: multiply, accumulate and decide in one clock"),
    ("49ae1a6", "pipelined MAC", "multiply registered before the accumulate"),
    ("816839d", "Costas, per symbol", "Costas loop, PI filter with fraction bits"),
    ("96962c8", "per sample, FF buffers", "moving sums, ring buffers with async reset"),
    ("6e4d2a2", "per sample, LUTRAM", "ring buffers without reset: LUTRAM"),
    ("9e44b4a", "pipelined loop filter", "loop filter split into error, integral and step stages"),
    ("WORKTREE", "differential encoding", "current design, differential encoding on"),
]
SPS_SWEEP = [8, 16, 32, 64, 128]


def vivado() -> str:
    local = ROOT / "local.mk"
    if local.exists():
        match = re.search(r"^VIVADO\s*:?=\s*(\S+)", local.read_text(), re.M)
        if match:
            return match.group(1)
    return "vivado"


def checkout(commit: str) -> Path:
    """A worktree of commit (reused if it exists), with the NCO submodule linked from this checkout."""
    if commit == "WORKTREE":
        return ROOT
    tree = OUT / "worktrees" / commit
    if not tree.exists():
        subprocess.run(["git", "-C", str(ROOT), "worktree", "add", "--detach", str(tree), commit], check=True,
                       capture_output=True)
    nco = tree / "ip" / "rtl_nco"
    if not nco.is_symlink():
        if nco.exists():
            nco.rmdir()  # the empty submodule folder
        nco.parent.mkdir(parents=True, exist_ok=True)  # early commits lack the submodule entry
        nco.symlink_to(ROOT / "ip" / "rtl_nco")
    return tree


def rtl_sources(tree: Path) -> list[str]:
    if not (tree / "mk" / "sources.mk").exists():  # before mk/sources.mk: the NCO, then src/ (packages first)
        nco = [str(tree / "ip" / "rtl_nco" / "src" / f) for f in ("sine_lut_pkg.vhd", "nco_pkg.vhd", "nco.vhd")]
        own = sorted((tree / "src").glob("*.vhd"), key=lambda f: (not f.stem.endswith("_pkg"), f.stem != "bpsk_tx",
                                                                     f.stem == "bpsk_modem"))
        return nco + [str(f) for f in own]
    out = subprocess.run(["make", "-s", "-f", str(tree / "mk" / "sources.mk"), "--eval",
                          "print: ; @echo $(RTL_SRC)", "print"], check=True, capture_output=True, text=True)
    return out.stdout.split()


def run(variant: dict, force: bool = False) -> dict:
    folder = OUT / variant["name"]
    if (folder / "timing.rpt").exists() and not force:  # implemented before: reuse (--force reruns)
        return {**variant, **parse(folder)}
    folder.mkdir(parents=True, exist_ok=True)
    tree = checkout(variant["commit"])
    (folder / "sources.f").write_text("\n".join(rtl_sources(tree)) + "\n")
    generics = [f"{k}={v}" for k, v in variant["generics"].items()]
    subprocess.run([vivado(), "-mode", "batch", "-nojournal", "-notrace", "-log", "vivado.log",
                    "-source", str(ROOT / "scripts" / "fpga_resources.tcl"),
                    "-tclargs", TOP, PART, "sources.f", str(ROOT / "constraints" / "clocks.xdc"), *generics],
                   cwd=folder, check=True, capture_output=True)
    return {**variant, **parse(folder)}


def parse(folder: Path) -> dict:
    util = (folder / "utilization.rpt").read_text()

    def used(label: str) -> float:
        match = re.search(rf"^\|\s*{re.escape(label)}\s*\|\s*([\d.]+)", util, re.M)
        return float(match.group(1)) if match else 0.0

    timing = (folder / "timing.rpt").read_text()
    summary = timing[timing.index("Design Timing Summary"):]
    wns = float(re.search(r"^\s+(-?[\d.]+)\s+-?[\d.]+\s+\d+\s+\d+", summary, re.M).group(1))
    path = timing[timing.index("Max Delay Paths"):]

    def field(name: str) -> str:
        return re.search(rf"^\s*{name}:\s+(.+?)\s*$", path, re.M).group(1)

    return {
        "critical_path": f"{field('Source').split('/')[-2]} -> {field('Destination').split('/')[-2]}, "
                         f"{field('Logic Levels')}",
        "lut": used("Slice LUTs"), "lutram": used("LUT as Memory"), "ff": used("Slice Registers"),
        "dsp": used("DSPs"), "bram": used("Block RAM Tile"), "wns_ns": wns,
        "fmax_mhz": 1000.0 / (10.0 - wns),  # 10 ns clock constraint: the period the design could have met
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--jobs", type=int, default=3, help="parallel Vivado runs")
    parser.add_argument("--force", action="store_true", help="rerun variants that were implemented before")
    args = parser.parse_args()
    variants = [{"group": "iteration", "name": f"iter_{commit}", "commit": commit, "label": label,
                 "change": change, "generics": {}} for commit, label, change in ITERATIONS]
    variants += [{"group": "sps", "name": f"sps{sps}", "commit": "WORKTREE", "label": f"GC_SPS {sps}",
                  "change": "", "generics": {"GC_SPS": sps, "GC_CCPS": sps // 4}} for sps in SPS_SWEEP]
    with ThreadPoolExecutor(args.jobs) as pool:
        rows = list(pool.map(lambda v: run(v, args.force), variants))
    fields = ["group", "name", "commit", "label", "change", "generics", "lut", "lutram", "ff", "dsp", "bram",
              "wns_ns", "fmax_mhz", "critical_path"]
    with open(OUT / "resources.csv", "w", newline="") as f:
        writer = csv.DictWriter(f, fields)
        writer.writeheader()
        for row in rows:
            writer.writerow({**{k: row[k] for k in fields if k != "generics"},
                             "generics": " ".join(f"{k}={v}" for k, v in row["generics"].items())})
    for row in rows:
        print(f"{row['name']:24} LUT {row['lut']:5.0f} LUTRAM {row['lutram']:4.0f} FF {row['ff']:5.0f} "
              f"DSP {row['dsp']:2.0f} BRAM {row['bram']:4.1f} WNS {row['wns_ns']:+.3f} ns ~{row['fmax_mhz']:.0f} MHz  "
              f"{row['critical_path']}")
    print(f"saved {OUT / 'resources.csv'}")


if __name__ == "__main__":
    main()
