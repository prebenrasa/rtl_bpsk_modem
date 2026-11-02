"""cocotb tests of bpsk_channel_harness: tx -> AwgnChannel -> rx.

Demonstrates that the channel is transparent without noise, and that AWGN
causes bit errors close to the BPSK theory BER = Q(sqrt(2 Eb/N0)).
"""
import math

import cocotb

from bpsk_tests import BitSequence, BpskTestbench
from channel import AwgnChannel


def ber_theory(ebn0_db: float) -> float:
    """BPSK in AWGN: Q(sqrt(2 Eb/N0)) = 0.5 erfc(sqrt(Eb/N0))."""
    return 0.5 * math.erfc(math.sqrt(10 ** (ebn0_db / 10)))


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
    # loose demo bound (not a statistical test): within a factor 2 of theory
    assert expected / 2 <= sb.ber <= expected * 2, f"BER {sb.ber:.4f} not within 2x of theory {expected:.4f}"
