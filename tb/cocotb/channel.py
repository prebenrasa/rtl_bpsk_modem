"""Simple AWGN channel between tx_sample_* and rx_sample_* of bpsk_channel_harness.

See noisy_channel_draft.md for the maths (sections 3.1 - 3.4).
"""
import math
import random

import cocotb
from cocotb.triggers import RisingEdge
from cocotb.types import LogicArray


class AwgnChannel:
    """tx_sample_* -> gain -> + AWGN -> round/saturate -> rx_sample_*, one clock of latency.

    Per edge: reads tx_sample_valid/tx_sample_data (the values at the edge) and
    drives rx_sample_*, which rx samples at the next edge: a one-clock register.
    ebn0_db=None is a transparent channel (gain 1, no noise).

    Noise per valid sample, sigma = a * sqrt(GC_SPS / (4 * Eb/N0)) with a the
    signal amplitude after the gain; the gain backs the signal off so that
    signal + 4 sigma fits the sample range (rare clipping, counted).
    Uses Python's `random` (seeded per test by cocotb).
    """

    LATENCY = 1  # clocks, for ModemModel

    def __init__(self, dut, ebn0_db: float | None, headroom_sigmas: float = 4.0):
        self.dut = dut
        self.width = len(dut.tx_sample_data)
        self.max_value = 2 ** (self.width - 1) - 1
        self.min_value = -(2 ** (self.width - 1))
        sps = int(dut.GC_SPS.value)

        if ebn0_db is None:
            self.gain, self.sigma = 1.0, 0.0
        else:
            sigma_per_amplitude = math.sqrt(sps / (4 * 10 ** (ebn0_db / 10)))
            self.gain = 1 / (1 + headroom_sigmas * sigma_per_amplitude)
            self.sigma = self.gain * self.max_value * sigma_per_amplitude  # in LSB

        self.n_samples = 0
        self.n_clipped = 0
        self._task = None
        self._drive(0, 0)

    def start(self) -> None:
        if self._task is None:
            self._task = cocotb.start_soon(self._run())

    def stop(self) -> None:
        if self._task is not None:
            self._task.cancel()
            self._task = None

    @property
    def clip_rate(self) -> float:
        return self.n_clipped / self.n_samples if self.n_samples else 0.0

    def _drive(self, valid: int, value: int) -> None:
        self.dut.rx_sample_valid.value = valid
        self.dut.rx_sample_data.value = LogicArray.from_signed(value, self.width)

    def _apply(self, x: int) -> int:
        y = round(self.gain * x + random.gauss(0.0, self.sigma)) if self.sigma else x
        if y > self.max_value or y < self.min_value:
            self.n_clipped += 1
            y = max(self.min_value, min(self.max_value, y))
        return y

    async def _run(self) -> None:
        dut = self.dut
        while True:
            await RisingEdge(dut.clk)
            if dut.reset.value == 1 or dut.tx_sample_valid.value != 1:
                self._drive(0, 0)
            else:
                self.n_samples += 1
                self._drive(1, self._apply(dut.tx_sample_data.value.to_signed()))
