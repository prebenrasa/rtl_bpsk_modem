"""Sample cocotb tests of bpsk_modem built on the components in bpsk_tests.py.

A starting point for trying the commands (make cocotb, PYTEST_ARGS, WAVES=1)
and for writing real tests: each test only configures BpskTestbench.
"""
import cocotb

from bpsk_tests import BitSequence, BpskTestbench


@cocotb.test(timeout_time=100, timeout_unit="us")
async def test_sample_reset_state(dut):
    """After reset: tx ready, no rx output, and nothing comes out without input."""
    tb = BpskTestbench(dut)
    await tb.start()
    assert dut.tx_bit_ready.value == 1, "tx_bit_ready not '1' after reset"
    assert dut.rx_bit_valid.value == 0, "rx_bit_valid not '0' after reset"
    await tb.finish()  # no bits sent: any rx output fails as "output with no bit expected"


@cocotb.test(timeout_time=20, timeout_unit="ms")
@cocotb.parametrize(clk_en_duty=[1.0, 0.6])
async def test_sample_loopback(dut, clk_en_duty):
    """Directed patterns, then random bits with idle gaps, through tx -> rx."""
    tb = BpskTestbench(dut)
    await tb.start()
    tb.clk_en.start(clk_en_duty)

    sequence = (
        BitSequence.constant(1, 4)
        + BitSequence.alternating(8)
        + BitSequence.random(32, gap_prob=0.5, max_gap=2 * tb.sps)
    )
    await tb.run(sequence)
    await tb.finish()
    assert tb.scoreboard.n_compared == len(sequence)
