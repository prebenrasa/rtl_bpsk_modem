"""Generics of the toplevel under test, read in one place for the testbench and the channel models.

A leaf module (cocotb only), so both bpsk_tests.py and channel.py can import it without a cycle.
The VHDL defaults stay the only copy: every value is read from the DUT of this run.
"""
from dataclasses import dataclass


@dataclass(frozen=True)
class DutGenerics:
    """The generics the testbench needs, plus values derived from them.

    Components that take the DUT read it with DutGenerics.from_dut(dut); pure models
    (ModemModel) take plain values, so they stay usable without a simulator.
    Add a field here when a test needs another generic, not a dut.GC_* read elsewhere.
    """

    sps: int             # GC_SPS: samples per symbol
    ccps: int            # GC_CCPS: carrier cycles per symbol
    sample_width: int    # GC_SAMPLE_WIDTH: sample width in bits (two's complement)
    diff_encoding: bool  # GC_DIFF_ENCODING

    @classmethod
    def from_dut(cls, dut) -> "DutGenerics":
        return cls(
            sps=int(dut.GC_SPS.value),
            ccps=int(dut.GC_CCPS.value),
            sample_width=int(dut.GC_SAMPLE_WIDTH.value),
            diff_encoding=bool(int(dut.GC_DIFF_ENCODING.value)),  # GHDL shows a boolean generic as a 1-bit value
        )

    @property
    def max_sample(self) -> int:
        """Largest sample value, also the tx carrier amplitude."""
        return 2 ** (self.sample_width - 1) - 1

    @property
    def min_sample(self) -> int:
        return -(2 ** (self.sample_width - 1))
