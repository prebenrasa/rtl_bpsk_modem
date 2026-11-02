"""cocotb data-logging runs of bpsk_channel_harness for the report figures (not a regression test).

Started by report_runner.py, one simulation per experiment, never by test_runner.py. Each test reads its
parameters from REPORT_* environment variables and writes CSV files into its run directory, which
plot_report.py turns into figures:

  test_report_ber    REPORT_EBN0_DB, REPORT_N_BITS, REPORT_LOG_SYMBOLS -> ber.csv (one row)[, symbols.csv, bits.csv]
  test_report_phase  REPORT_PHASE_DEG, REPORT_FREQ_OFFSET, REPORT_EBN0_DB (empty = no noise),
                     REPORT_N_BITS, REPORT_LOG_SAMPLES (1 = also samples.csv)
                                                                       -> symbols.csv, bits.csv[, samples.csv]
  test_report_tx     REPORT_BITS (a 0/1 string) or REPORT_N_BITS (random) -> tx.csv, bits.csv
  test_report_throughput  REPORT_DUTY (clk_en duty), REPORT_N_BITS     -> throughput.csv (one row)

Bits are counted, not checked (strict=False): the runs log what the receiver does, the regression tests
in bpsk_channel_tests.py check it.
"""
import math
import os

import cocotb
from cocotb.triggers import RisingEdge

from bpsk_channel_tests import ber_theory
from bpsk_tests import BitSequence, BpskTestbench
from channel import AwgnChannel, PhaseErrorMonitor, PhaseOffsetChannel


def env_float(name: str, default: float | None = None) -> float | None:
    value = os.environ.get(name, "")
    return float(value) if value else default


def env_int(name: str, default: int) -> int:
    value = os.environ.get(name, "")
    return int(value) if value else default


class SampleLogger:
    """Records a value every clock where a qualifier signal is '1' (read right after the edge, as the
    other monitors do): e.g. tx_sample_data while tx_sample_valid, or the rx moving sum per sample."""

    def __init__(self, dut, qualifier, signals: dict):
        self.dut = dut
        self.qualifier = qualifier
        self.signals = signals  # column name -> signal handle
        self.rows: list[list[int]] = []

    def start(self) -> None:
        cocotb.start_soon(self._run())

    async def _run(self) -> None:
        while True:
            await RisingEdge(self.dut.clk)
            if self.qualifier.value == 1:
                self.rows.append([_to_int(sig) for sig in self.signals.values()])

    def write_csv(self, path: str) -> None:
        with open(path, "w") as f:
            f.write("sample," + ",".join(self.signals) + "\n")
            for n, row in enumerate(self.rows):
                f.write(f"{n}," + ",".join(str(v) for v in row) + "\n")


def _to_int(signal) -> int:
    value = signal.value
    return value.to_signed() if len(signal) > 1 else int(value)


def write_bits_csv(path: str, sent: list[int], errors: list[bool]) -> None:
    """Per bit: the bit sent and whether the rx output was wrong (empty if no output was compared)."""
    with open(path, "w") as f:
        f.write("bit_index,bit,error\n")
        for k, bit in enumerate(sent):
            error = int(errors[k]) if k < len(errors) else ""
            f.write(f"{k},{bit},{error}\n")


@cocotb.test(timeout_time=2000, timeout_unit="ms")
async def test_report_ber(dut):
    """AWGN, no phase offset: count bit errors over REPORT_N_BITS random bits at REPORT_EBN0_DB."""
    ebn0_db = env_float("REPORT_EBN0_DB", 4.0)
    n_bits = env_int("REPORT_N_BITS", 1000)
    log_symbols = env_int("REPORT_LOG_SYMBOLS", 0) == 1
    channel = AwgnChannel(dut, ebn0_db=ebn0_db)
    tb = BpskTestbench(dut, channel=channel, strict=False, expected_trust=None)
    phase_mon = PhaseErrorMonitor(dut)
    sent: list[int] = []
    tb.in_mon.subscribe(lambda txn: sent.append(txn.bit))
    await tb.start()
    if log_symbols:
        phase_mon.start()
    await tb.run(BitSequence.random(n_bits))
    await tb.finish()

    sb = tb.scoreboard
    diff = tb.generics.diff_encoding
    if log_symbols:  # per symbol: the line symbol sent and the rx correlations, to separate symbol errors from decoding
        with open("symbols.csv", "w") as f:
            f.write("symbol,line_symbol,i,q\n")
            line = 0
            for k, ((i, q), bit) in enumerate(zip(phase_mon.iq, sent)):
                line = bit ^ line if diff else bit
                f.write(f"{k},{line},{i},{q}\n")
        write_bits_csv("bits.csv", sent, sb.errors)
    with open("ber.csv", "w") as f:
        f.write("ebn0_db,diff_encoding,n_bits,n_errors,ber,theory,gain,sigma_lsb,clip_rate\n")
        f.write(f"{ebn0_db},{int(diff)},{sb.n_compared},{sb.n_bit_errors},{sb.ber},{ber_theory(ebn0_db, diff)},"
                f"{channel.gain},{channel.sigma},{channel.clip_rate}\n")
    dut._log.info(f"Eb/N0 {ebn0_db} dB, diff encoding {diff}: {sb.summary()}")


@cocotb.test(timeout_time=2000, timeout_unit="ms")
async def test_report_phase(dut):
    """Carrier phase offset (and drift, and optionally AWGN): log the Costas loop per symbol.

    symbols.csv per symbol: the channel phase, the wrapped error (as PhaseErrorMonitor), a data-aided
    error over the full circle (the known line symbol removes the data sign, so a lock at 180 degrees
    shows as +-180), I and Q, and the frequency correction.
    """
    phase_deg = env_float("REPORT_PHASE_DEG", 30.0)
    freq_offset = env_float("REPORT_FREQ_OFFSET", 0.0)
    ebn0_db = env_float("REPORT_EBN0_DB")
    n_bits = env_int("REPORT_N_BITS", 300)
    log_samples = env_int("REPORT_LOG_SAMPLES", 0) == 1

    channel = PhaseOffsetChannel(dut, phase_deg=phase_deg, freq_offset=freq_offset, ebn0_db=ebn0_db)
    tb = BpskTestbench(dut, channel=channel, strict=False, expected_trust=None)
    tb.in_mon.subscribe(channel.on_bit)
    phase_mon = PhaseErrorMonitor(dut)
    rx = dut.i_rx
    samples = SampleLogger(dut, rx.s_acc_valid, {"i": rx.s_sine_accumulator, "decision": rx.s_decision_done})
    sent: list[int] = []
    tb.in_mon.subscribe(lambda txn: sent.append(txn.bit))

    await tb.start()
    phase_mon.start()
    if log_samples:
        samples.start()
    await tb.run(BitSequence.random(n_bits))
    await tb.finish()

    sps = tb.generics.sps
    with open("symbols.csv", "w") as f:
        f.write("symbol,channel_deg,error_deg,full_error_deg,i,q,freq_correction,line_symbol\n")
        for k, (error, (i, q), freq) in enumerate(zip(phase_mon.errors_deg, phase_mon.iq, phase_mon.freqs)):
            symbol = channel.symbols[k]
            full = math.degrees(math.atan2(q, i)) - (0.0 if symbol == 1 else 180.0)
            full = (full + 180.0) % 360.0 - 180.0
            channel_deg = phase_deg + 360.0 * freq_offset * (k + 0.5) * sps  # mid-symbol
            f.write(f"{k},{channel_deg},{error},{full},{i},{q},{freq / 2**phase_mon.freq_width},{symbol}\n")
    write_bits_csv("bits.csv", sent, tb.scoreboard.errors)
    if log_samples:
        samples.write_csv("samples.csv")
    dut._log.info(f"phase {phase_deg} deg, drift {freq_offset}, Eb/N0 {ebn0_db}: {tb.scoreboard.summary()}")


@cocotb.test(timeout_time=2000, timeout_unit="ms")
async def test_report_tx(dut):
    """Transparent channel: log every valid tx sample, for the waveform and the spectrum."""
    bits = os.environ.get("REPORT_BITS", "")
    sequence = BitSequence.from_bits(bits) if bits else BitSequence.random(env_int("REPORT_N_BITS", 1000))
    tb = BpskTestbench(dut, channel=AwgnChannel(dut, ebn0_db=None))
    tx = SampleLogger(dut, dut.tx_sample_valid, {"value": dut.tx_sample_data})
    await tb.start()
    tx.start()
    await tb.run(sequence)
    await tb.finish()

    tx.write_csv("tx.csv")
    write_bits_csv("bits.csv", sequence.bits, tb.scoreboard.errors)


@cocotb.test(timeout_time=2000, timeout_unit="ms")
async def test_report_throughput(dut):
    """Back-to-back random bits at clk_en duty REPORT_DUTY: measured throughput and latency.

    Throughput is the steady-state rate between the first and the last rx bit, in bits per clock; latency
    is from the edge that accepts the first bit to the edge that samples its rx_bit_valid (as BitOutMonitor
    records it), so it includes the channel's one clock.
    """
    duty = env_float("REPORT_DUTY", 1.0)
    n_bits = env_int("REPORT_N_BITS", 200)
    tb = BpskTestbench(dut, channel=AwgnChannel(dut, ebn0_db=None))
    accepted: list[int] = []
    received: list[int] = []
    tb.in_mon.subscribe(lambda txn: accepted.append(txn.cycle))
    tb.out_mon.subscribe(lambda txn: received.append(txn.cycle))
    await tb.start()
    tb.clk_en.start(duty=duty)
    await tb.run(BitSequence.random(n_bits))
    await tb.finish()
    tb.clk_en.stop()

    bits_per_clock = (len(received) - 1) / (received[-1] - received[0])
    with open("throughput.csv", "w") as f:
        f.write("sps,duty,n_bits,bits_per_clock,latency_clocks,channel_latency\n")
        f.write(f"{tb.generics.sps},{duty},{len(received)},{bits_per_clock},{received[0] - accepted[0]},"
                f"{AwgnChannel.LATENCY}\n")
    dut._log.info(f"SPS {tb.generics.sps}, clk_en duty {duty}: {bits_per_clock:.5f} bits/clock, "
                  f"first bit after {received[0] - accepted[0]} clocks")

