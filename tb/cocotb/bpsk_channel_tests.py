"""cocotb tests of bpsk_channel_harness: tx -> AwgnChannel -> rx.

Demonstrates that the channel is transparent without noise, and that AWGN
causes bit errors close to the BPSK theory BER = Q(sqrt(2 Eb/N0)).
"""
import math

import cocotb

from bpsk_tests import BitSequence, BpskTestbench
from channel import AwgnChannel, PhaseErrorMonitor, PhaseOffsetChannel


def ber_theory(ebn0_db: float) -> float:
    """BPSK in AWGN: Q(sqrt(2 Eb/N0)) = 0.5 erfc(sqrt(Eb/N0))."""
    return 0.5 * math.erfc(math.sqrt(10 ** (ebn0_db / 10)))


def ber_bounds(n_bits: int, ebn0_db: float, loss_db: float = 1.0, z: float = 4.0) -> tuple[float, float]:
    """Accepted BER range for n_bits decisions: a binomial interval of z standard deviations.

    Lower edge around theory (a real receiver cannot beat it); upper edge around theory at
    ebn0_db - loss_db, allowing for implementation loss (sample quantisation, LUT, Costas
    loop jitter: about 0.3 dB measured over 6 seeds x 8 configurations). z = 4 gives a
    false failure rate of about 3e-5 per edge, so the check holds for any seed.
    """
    def edge(p: float, sign: int) -> float:
        return p + sign * z * math.sqrt(p * (1 - p) / n_bits)

    return max(0.0, edge(ber_theory(ebn0_db), -1)), edge(ber_theory(ebn0_db - loss_db), +1)


@cocotb.test(timeout_time=20, timeout_unit="ms")
async def test_channel_transparent(dut):
    """No noise: every bit arrives, correct and trusted, at GC_SPS + 8 + 1 clocks (one clock of channel)."""
    tb = BpskTestbench(dut, channel=AwgnChannel(dut, ebn0_db=None))
    await tb.start()
    await tb.run(BitSequence.random(64, gap_prob=0.3, max_gap=2 * tb.sps))
    await tb.finish()


@cocotb.test(timeout_time=100, timeout_unit="ms")
@cocotb.parametrize(ebn0_db=[0.0, 4.0])
async def test_channel_awgn(dut, ebn0_db):
    """AWGN: bits still arrive in order and on time, but some are wrong; BER near theory."""
    n_bits = 1000
    channel = AwgnChannel(dut, ebn0_db=ebn0_db)
    tb = BpskTestbench(dut, channel=channel, strict=False, expected_trust=None)
    await tb.start()
    await tb.run(BitSequence.random(n_bits))
    await tb.finish()

    expected = ber_theory(ebn0_db)
    sb = tb.scoreboard
    dut._log.info(
        f"Eb/N0 {ebn0_db} dB: gain {channel.gain:.3f}, sigma {channel.sigma:.1f} LSB, "
        f"clip rate {channel.clip_rate:.2g}; BER {sb.ber:.4f} measured, {expected:.4f} theory"
    )
    assert channel.clip_rate < 1e-3, f"clip rate {channel.clip_rate:.2g}: noise does not fit the sample range"
    low, high = ber_bounds(n_bits, ebn0_db)
    assert low <= sb.ber <= high, f"BER {sb.ber:.4f} outside {low:.4f} .. {high:.4f} (theory {expected:.4f})"


@cocotb.test(timeout_time=100, timeout_unit="ms")
@cocotb.parametrize(phase_deg=[30.0, -60.0], freq_offset=[0.0, 1e-4])
async def test_phase_offset(dut, phase_deg, freq_offset):
    """Carrier phase offset (and drift): the Costas loop pulls the phase error to ~0.

    A wrong feedback sign drives the error to +-90 degrees instead (I collapses, bits turn random).
    Bits are counted, not checked, while the loop acquires; the phase error over the last
    symbols must be small.
    """
    n_bits, n_settled = 300, 50
    channel = PhaseOffsetChannel(dut, phase_deg=phase_deg, freq_offset=freq_offset)
    tb = BpskTestbench(dut, channel=channel, strict=False, expected_trust=None)
    tb.in_mon.subscribe(channel.on_bit)
    phase_mon = PhaseErrorMonitor(dut)
    await tb.start()
    phase_mon.start()
    await tb.run(BitSequence.random(n_bits))
    await tb.finish()

    phase_mon.write_csv(
        f"costas_phase{phase_deg:g}_drift{freq_offset:g}.csv",  # in the run directory build/cocotb/<toplevel>/<config>/
        sps=tb.sps, phase_deg=phase_deg, freq_offset=freq_offset,
    )
    errors = phase_mon.errors_deg
    trace = ", ".join(f"{e:.1f}" for e in errors[:: max(1, len(errors) // 15)])
    dut._log.info(f"phase {phase_deg} deg, drift {freq_offset} cycles/sample: error trace [{trace}] deg")
    settled = errors[-n_settled:]
    worst = max(abs(e) for e in settled)
    dut._log.info(f"last {n_settled} symbols: worst |error| {worst:.2f} deg; {tb.scoreboard.summary()}")
    assert len(errors) >= n_bits, f"only {len(errors)} symbols seen"
    assert worst < 5.0, f"phase error not settled: worst |error| {worst:.1f} deg over the last {n_settled} symbols"
