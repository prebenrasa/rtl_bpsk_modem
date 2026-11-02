"""cocotb tests of bpsk_channel_harness: tx -> AwgnChannel -> rx.

Demonstrates that the channel is transparent without noise, that AWGN
causes bit errors close to the BPSK theory BER = Q(sqrt(2 Eb/N0)) (about
twice that with differential encoding), and that the Costas loop locks on
a carrier phase offset, at 180 degrees inverted unless the bits are
differentially encoded.
"""
import math

import cocotb

from bpsk_tests import BitSequence, BpskTestbench
from channel import AwgnChannel, PhaseErrorMonitor, PhaseOffsetChannel


def ber_theory(ebn0_db: float, diff_encoding: bool = False) -> float:
    """BPSK in AWGN: p = Q(sqrt(2 Eb/N0)) = 0.5 erfc(sqrt(Eb/N0)) per symbol decision.

    With differential encoding a bit is wrong when exactly one of its two symbol
    decisions is: 2 p (1 - p).
    """
    p = 0.5 * math.erfc(math.sqrt(10 ** (ebn0_db / 10)))
    return 2 * p * (1 - p) if diff_encoding else p


def ber_bounds(n_bits: int, ebn0_db: float, diff_encoding: bool = False,
               loss_db: float = 1.0, z: float = 4.0) -> tuple[float, float]:
    """Accepted BER range for n_bits decisions: a binomial interval of z standard deviations.

    Lower edge around theory (a real receiver cannot beat it); upper edge around theory at
    ebn0_db - loss_db, allowing for implementation loss (sample quantisation, LUT, Costas
    loop jitter: about 0.3 dB measured over 6 seeds x 8 configurations). z = 4 gives a
    false failure rate of about 3e-5 per edge, so the check holds for any seed.
    With differential encoding the errors come in pairs (one wrong symbol spoils two bits),
    so the error count varies about twice as much as a binomial one: sigma times sqrt(2).
    """
    spread = math.sqrt(2) if diff_encoding else 1.0

    def edge(p: float, sign: int) -> float:
        return p + sign * z * spread * math.sqrt(p * (1 - p) / n_bits)

    return (max(0.0, edge(ber_theory(ebn0_db, diff_encoding), -1)),
            edge(ber_theory(ebn0_db - loss_db, diff_encoding), +1))


@cocotb.test(timeout_time=20, timeout_unit="ms")
async def test_channel_transparent(dut):
    """No noise: every bit arrives, correct and trusted, at GC_SPS + 8 + 1 clocks (one clock of channel)."""
    tb = BpskTestbench(dut, channel=AwgnChannel(dut, ebn0_db=None))
    await tb.start()
    await tb.run(BitSequence.random(64, gap_prob=0.3, max_gap=2 * tb.generics.sps))
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

    expected = ber_theory(ebn0_db, tb.generics.diff_encoding)
    sb = tb.scoreboard
    dut._log.info(
        f"Eb/N0 {ebn0_db} dB: gain {channel.gain:.3f}, sigma {channel.sigma:.1f} LSB, "
        f"clip rate {channel.clip_rate:.2g}; BER {sb.ber:.4f} measured, {expected:.4f} theory"
    )
    assert channel.clip_rate < 1e-3, f"clip rate {channel.clip_rate:.2g}: noise does not fit the sample range"
    low, high = ber_bounds(n_bits, ebn0_db, tb.generics.diff_encoding)
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
        sps=tb.generics.sps, phase_deg=phase_deg, freq_offset=freq_offset,
    )
    errors = phase_mon.errors_deg
    trace = ", ".join(f"{e:.1f}" for e in errors[:: max(1, len(errors) // 15)])
    dut._log.info(f"phase {phase_deg} deg, drift {freq_offset} cycles/sample: error trace [{trace}] deg")
    settled = errors[-n_settled:]
    worst = max(abs(e) for e in settled)
    dut._log.info(f"last {n_settled} symbols: worst |error| {worst:.2f} deg; {tb.scoreboard.summary()}")
    assert len(errors) >= n_bits, f"only {len(errors)} symbols seen"
    assert worst < 5.0, f"phase error not settled: worst |error| {worst:.1f} deg over the last {n_settled} symbols"


@cocotb.test(timeout_time=100, timeout_unit="ms")
@cocotb.parametrize(phase_deg=[180.0, 150.0])
async def test_phase_inversion(dut, phase_deg):
    """Carrier offset near 180 degrees: the Costas loop locks with every symbol decision inverted.

    Without differential encoding every bit after acquisition is then inverted: the BPSK
    phase ambiguity. With it the inversion cancels and every bit after acquisition is
    correct. 150 degrees has to be pulled to 180 first; 180 degrees is already a lock point.
    """
    n_bits, n_acquire = 200, 60
    channel = PhaseOffsetChannel(dut, phase_deg=phase_deg)
    tb = BpskTestbench(dut, channel=channel, strict=False, expected_trust=None)
    tb.in_mon.subscribe(channel.on_bit)
    await tb.start()
    await tb.run(BitSequence.random(n_bits))
    await tb.finish()

    locked = tb.scoreboard.errors[n_acquire:]
    n_wrong = sum(locked)
    dut._log.info(
        f"phase {phase_deg} deg, diff encoding {tb.generics.diff_encoding}: {n_wrong} of {len(locked)} bits wrong "
        f"after acquisition; {tb.scoreboard.summary()}"
    )
    assert len(tb.scoreboard.errors) == n_bits, f"only {len(tb.scoreboard.errors)} bits seen"
    if tb.generics.diff_encoding:
        assert n_wrong == 0, f"{n_wrong} of {len(locked)} bits wrong after acquisition: the inversion did not cancel"
    else:
        assert n_wrong == len(locked), (
            f"{n_wrong} of {len(locked)} bits wrong after acquisition: expected all inverted (180 degree lock)"
        )
