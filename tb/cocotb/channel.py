"""Simple AWGN channel between tx_sample_* and rx_sample_* of bpsk_channel_harness.

See noisy_channel_draft.md for the maths (sections 3.1 - 3.4).
"""
import math
import random

import cocotb
from cocotb.triggers import RisingEdge
from cocotb.types import LogicArray

from dut_generics import DutGenerics


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
        self.generics = DutGenerics.from_dut(dut)
        self.width = self.generics.sample_width
        self.max_value = self.generics.max_sample
        self.min_value = self.generics.min_sample
        sps = self.generics.sps

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
            if dut.reset_n.value == 0 or dut.tx_sample_valid.value != 1:
                self._drive(0, 0)
            else:
                self.n_samples += 1
                self._drive(1, self._apply(dut.tx_sample_data.value.to_signed()))


class PhaseOffsetChannel(AwgnChannel):
    """Like AwgnChannel, but rebuilds each tx sample with a carrier phase offset (and drift).

    A real passband sample cannot be rotated on its own (no quadrature), so the
    channel regenerates it from the bit: subscribe on_bit to the BitInMonitor,
    which sees each bit 3 clocks before its first sample. Sample m (counted over
    valid tx samples since start) of bit b is
        (2b - 1) * A * sin(2 pi (GC_CCPS / GC_SPS * k + freq_offset * m) + phase)
    with k = m mod GC_SPS the index within the symbol, then gain, AWGN and
    rounding as in AwgnChannel. Symbol timing is unchanged (LATENCY 1).

    With differential encoding (GC_DIFF_ENCODING) the tx sends the symbol
    d = b xor d_prev, not the bit b, so on_bit encodes the same way: the
    previous symbol is the state, '0' (the reference) after reset.
    """

    def __init__(self, dut, phase_deg: float, freq_offset: float = 0.0, ebn0_db: float | None = None):
        super().__init__(dut, ebn0_db)
        self.sps = self.generics.sps
        self.ccps = self.generics.ccps
        self.phase = math.radians(phase_deg)
        self.freq_offset = freq_offset  # cycles per sample
        self.diff_encoding = self.generics.diff_encoding
        self._symbol = 0  # last symbol queued: encoder state, the reference after reset
        self._bits: list[int] = []  # symbols of accepted bits, not yet sent
        self.symbols: list[int] = []  # every symbol queued since start, in order (line symbols)
        self._bit = 0
        self._m = 0

    def on_bit(self, txn) -> None:
        """BitInMonitor callback: queue the symbol of the next accepted bit."""
        self._symbol = txn.bit ^ self._symbol if self.diff_encoding else txn.bit
        self._bits.append(self._symbol)
        self.symbols.append(self._symbol)

    async def _run(self) -> None:
        dut = self.dut
        while True:
            await RisingEdge(dut.clk)
            if dut.reset_n.value == 0:
                self._bits.clear()
                self._symbol = 0
                self._m = 0
                self._drive(0, 0)
            elif dut.tx_sample_valid.value != 1:
                self._drive(0, 0)
            else:
                k = self._m % self.sps
                if k == 0:
                    assert self._bits, "tx sample with no accepted bit queued"
                    self._bit = self._bits.pop(0)
                cycles = self.ccps * k / self.sps + self.freq_offset * self._m
                x = (2 * self._bit - 1) * self.max_value * math.sin(2 * math.pi * cycles + self.phase)
                self._m += 1
                self.n_samples += 1
                self._drive(1, round(self._apply(x)))

class PhaseErrorMonitor:
    """Logs the residual carrier phase error of bpsk_rx once per symbol.

    When i_rx.s_decision_done rises, the moving sums hold the products of exactly one
    symbol: I = sum r*sin, Q = sum r*cos, and atan2(Q, I) = phi - theta. They (and s_freq)
    change with every valid sample, so they are read right at that edge.
    Wrapped to (-90, 90] degrees: the data bit and the BPSK 180 degree ambiguity drop out.
    """

    def __init__(self, dut):
        self.dut = dut
        self.errors_deg: list[float] = []
        self.freqs: list[int] = []  # i_rx.s_freq per symbol (integral path, in 2**-C_FRAC_WIDTH step LSBs)
        self.iq: list[tuple[int, int]] = []  # (I, Q) per symbol: the correlations the error comes from
        # s_freq is GC_PHASE_WIDTH + C_FRAC_WIDTH bits: one cycle/sample is 2**freq_width
        self.freq_width = len(dut.i_rx.s_freq)
        self._task = None

    def start(self) -> None:
        if self._task is None:
            self._task = cocotb.start_soon(self._run())

    def stop(self) -> None:
        if self._task is not None:
            self._task.cancel()
            self._task = None

    async def _run(self) -> None:
        rx = self.dut.i_rx
        while True:
            # wakes once per symbol, not every clock: s_decision_done is a one-clock pulse. The moving sums
            # and s_freq change every sample, but read right after this edge the sums are exactly one symbol
            await RisingEdge(rx.s_decision_done)
            i = rx.s_sine_accumulator.value.to_signed()
            q = rx.s_cos_accumulator.value.to_signed()
            error = math.degrees(math.atan2(q, i))
            self.errors_deg.append((error + 90.0) % 180.0 - 90.0)
            self.iq.append((i, q))
            self.freqs.append(rx.s_freq.value.to_signed())
