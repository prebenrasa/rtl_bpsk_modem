import random
from collections import deque
from dataclasses import dataclass
from typing import Callable

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge
from cocotb.utils import get_sim_time

from dut_generics import DutGenerics


CLK_PERIOD_NS = 10


def now_cycles() -> int:
    """Current simulation time in clock periods."""
    return round(get_sim_time(unit="ns") / CLK_PERIOD_NS)


@dataclass
class BitTxn:
    """ One bit as seen on a bit interface: value, cycle of the edge that
    transferred it, and (rx side only) the trust flag. The single currency
    passed between monitors, model and scoreboard.
    """
    bit: int
    cycle: int                 # cycle of the edge that transferred it
    trust: int | None = None   # rx side only

@dataclass(frozen=True)
class BitItem:
    """One stimulus item: the bit to send and the idle clocks after it is accepted."""
    bit: int
    idle_after: int = 0  # 0 = next bit back-to-back


class BitInMonitor:
    """ Passive: on every edge, if tx_bit_valid and tx_bit_ready were both '1',
    emits a BitTxn for the accepted bit to its subscribers (callback or queue).
    Must not depend on who drives the pins.
    """
    def __init__(self, dut):
        self.dut = dut
        self._subscribers: list[Callable[[BitTxn], None]] = []
        self._task = None
        self.count = 0  # tx_bit_valid and tx_bit_ready '1' seen since start()
    
    def subscribe(self, callback: Callable[[BitTxn], None]) -> None:
        """Call `callback(txn)` for accepted bits since start() (e.g. scoreboard.expect)."""
        self._subscribers.append(callback)

    def start(self) -> None:
        if self._task is None:
            self._task = cocotb.start_soon(self._run())

    def stop(self) -> None:
        if self._task is not None:
            self._task.cancel()
            self._task = None

    async def _run(self) -> None:
        dut = self.dut
        while True:
            await RisingEdge(dut.clk)
            if dut.tx_bit_valid.value == 1 and dut.tx_bit_ready.value == 1:
                txn = BitTxn(
                    bit=int(dut.tx_bit_data.value),
                    cycle=now_cycles(),
                )
                self.count += 1
                for callback in self._subscribers:
                    callback(txn)


class BitOutMonitor:
    """Passive monitor of the rx bit output.

    Emits one BitTxn for every edge that samples rx_bit_valid = '1', to every
    subscriber, in order. Never drives a signal.

    Sampling rule: signals are read right after `await RisingEdge(clk)`, before
    the DUT's registers update, so the values are the ones the DUT produced
    for that edge (same rule as every other component in this file).
    """

    def __init__(self, dut):
        self.dut = dut
        self._subscribers: list[Callable[[BitTxn], None]] = []
        self._task = None
        self.count = 0  # bits seen since start()

    def subscribe(self, callback: Callable[[BitTxn], None]) -> None:
        """Call `callback(txn)` for every observed bit (e.g. scoreboard.observe)."""
        self._subscribers.append(callback)

    def start(self) -> None:
        if self._task is None:
            self._task = cocotb.start_soon(self._run())

    def stop(self) -> None:
        if self._task is not None:
            self._task.cancel()
            self._task = None

    async def _run(self) -> None:
        dut = self.dut
        while True:
            await RisingEdge(dut.clk)
            if dut.rx_bit_valid.value == 1:
                txn = BitTxn(
                    bit=int(dut.rx_bit_data.value),
                    cycle=now_cycles(),
                    trust=int(dut.rx_bit_trust.value),
                )
                self.count += 1
                for callback in self._subscribers:
                    callback(txn)


class BitSequence:
    """Stimulus for the tx bit interface: an ordered list of BitItem.

    Knows nothing about pins or timing: the driver decides how an item is put
    on the bus, the sequence only decides what and in which order.
    Random sequences use Python's `random`, which cocotb seeds per test
    (reproduce with RANDOM_SEED=<n>).
    """

    def __init__(self, items: list[BitItem]):
        self.items = list(items)

    # ---- constructors
    @classmethod
    def random(cls, n_bits: int, gap_prob: float = 0.0, max_gap: int = 0) -> "BitSequence":
        """`n_bits` random bits; after each, with probability `gap_prob`, 1..max_gap idle clocks."""
        items = []
        for _ in range(n_bits):
            gap = random.randint(1, max_gap) if max_gap > 0 and random.random() < gap_prob else 0
            items.append(BitItem(random.randint(0, 1), gap))
        return cls(items)

    @classmethod
    def from_bits(cls, bits, idle_after: int = 0) -> "BitSequence":
        """Directed: the given bits (iterable of 0/1 or a string like "1011"), same gap after each."""
        return cls([BitItem(int(b), idle_after) for b in bits])

    @classmethod
    def constant(cls, bit: int, n_bits: int) -> "BitSequence":
        """`n_bits` copies of `bit`, back-to-back (no phase transitions at all)."""
        return cls.from_bits([bit] * n_bits)

    @classmethod
    def alternating(cls, n_bits: int, first: int = 1) -> "BitSequence":
        """1010... back-to-back: a phase flip at every symbol boundary."""
        return cls.from_bits([(first + i) % 2 for i in range(n_bits)])

    @classmethod
    def runs(cls, run_lengths: list[int], first: int = 1) -> "BitSequence":
        """Runs of equal bits with the given lengths, alternating value, e.g. [1, 5, 2] -> 1 00000 11."""
        bits = []
        for i, length in enumerate(run_lengths):
            bits += [(first + i) % 2] * length
        return cls.from_bits(bits)

    # ---- use
    def __iter__(self):
        return iter(self.items)

    def __len__(self) -> int:
        return len(self.items)

    def __add__(self, other: "BitSequence") -> "BitSequence":
        """Concatenate: e.g. BitSequence.constant(1, 8) + BitSequence.random(32)."""
        return BitSequence(self.items + other.items)

    @property
    def bits(self) -> list[int]:
        return [item.bit for item in self.items]


class BitDriver:
    """Active driver of the tx bit input (tx_bit_data / tx_bit_valid / tx_bit_ready).

    send() presents one bit and holds it until an edge samples tx_bit_valid =
    tx_bit_ready = '1'. It returns at that edge with tx_bit_valid still '1', so a
    following send() in the same time step gives back-to-back bits with no gap;
    idle() or release() drops tx_bit_valid. Records nothing: BitInMonitor reports
    what was accepted.

    Sampling rule: tx_bit_ready is read right after `await RisingEdge(clk)`, so it
    is the value the DUT sampled at that edge (same rule as the monitors).
    """

    def __init__(self, dut, max_wait_cycles: int = 1000):
        self.dut = dut
        self.max_wait_cycles = max_wait_cycles  # edges send() waits for tx_bit_ready before failing
        self.release()

    def release(self) -> None:
        """Idle the interface: tx_bit_valid = '0', tx_bit_data = '0'."""
        self.dut.tx_bit_valid.value = 0
        self.dut.tx_bit_data.value = 0

    async def send(self, bit: int) -> None:
        """Present `bit` until an edge accepts it; fail after max_wait_cycles edges."""
        dut = self.dut
        dut.tx_bit_data.value = bit
        dut.tx_bit_valid.value = 1
        for _ in range(self.max_wait_cycles):
            await RisingEdge(dut.clk)
            if dut.tx_bit_ready.value == 1:
                return
        self.release()
        assert False, f"tx_bit_ready not '1' within {self.max_wait_cycles} clock cycles"

    async def idle(self, cycles: int) -> None:
        """Release the interface for `cycles` clock edges."""
        self.release()
        await ClockCycles(self.dut.clk, cycles)

    async def send_sequence(self, sequence: BitSequence) -> None:
        """Send every item of `sequence` in order, with its idle gap after it; release at the end."""
        try:
            for item in sequence:
                await self.send(item.bit)
                if item.idle_after > 0:
                    await self.idle(item.idle_after)
        finally:
            self.release()


class ClkEnDriver:
    """Active driver of clk_en: constant '1', or random with a given duty as a background task.

    start(duty) with duty = 1.0 drives '1' and starts no task; with duty < 1.0 a
    task draws a new value after every edge, '1' with probability `duty`.
    stop() ends the task and leaves clk_en = '1'. Uses Python's `random`
    (seeded per test by cocotb).
    """

    def __init__(self, dut):
        self.dut = dut
        self.duty = 1.0
        self._task = None
        dut.clk_en.value = 1

    @property
    def constant(self) -> bool:
        """True when clk_en is '1' every clock (latency checks in clocks are valid)."""
        return self.duty >= 1.0

    def start(self, duty: float = 1.0) -> None:
        assert 0.0 < duty <= 1.0, f"clk_en duty {duty} not in (0, 1]"
        self.stop()
        self.duty = duty
        if not self.constant:
            self._task = cocotb.start_soon(self._run())

    def stop(self) -> None:
        if self._task is not None:
            self._task.cancel()
            self._task = None
        self.duty = 1.0
        self.dut.clk_en.value = 1

    async def _run(self) -> None:
        dut = self.dut
        while True:
            dut.clk_en.value = int(random.random() < self.duty)
            await RisingEdge(dut.clk)



class ModemModel:
    """Reference model of the tx -> (channel) -> rx loopback.

    predict() turns an accepted input BitTxn into the expected output BitTxn:
    the same bit, at accept cycle + sampled latency, with the expected trust.
    The model is fed by BitInMonitor (subscribe predict) and passes each
    prediction to its own subscribers (e.g. scoreboard.expect).

    Latency, with clk_en = '1' every clock (spec, bpsk_modem header):
      GC_SPS + 7 clocks from the accepting edge to the edge that sets rx_bit_valid
      (tx 3 + one symbol + rx 4), plus the channel latency; BitOutMonitor records
      the edge after that, the one that samples rx_bit_valid = '1', hence + 1.
    With a random clk_en the expected cycle is not meaningful: the scoreboard
    must skip the latency check then.

    Differential encoding (GC_DIFF_ENCODING): bits out still equal bits in, as tx
    encodes and rx decodes. The rx decodes the first bit after reset against the
    reference symbol, whose trust is '0', so that bit's expected trust is 0.
    reset() marks the next prediction as that first bit.
    """

    TX_LATENCY = 3  # accepting edge -> first valid sample
    RX_LATENCY = 4  # edge taking the last sample of a symbol -> rx_bit_valid

    def __init__(self, sps: int, channel_latency: int = 0, expected_trust: int | None = 1,
                 diff_encoding: bool = False):
        self.latency = self.TX_LATENCY + sps + self.RX_LATENCY + channel_latency  # spec latency in clocks
        self.sampled_latency = self.latency + 1                                     # as BitOutMonitor records it
        self.expected_trust = expected_trust  # None = don't care (noisy channel)
        self.diff_encoding = diff_encoding
        self._first_bit = True                # next prediction is the first bit after reset
        self._subscribers: list[Callable[[BitTxn], None]] = []

    def reset(self) -> None:
        """The DUT was reset: the next accepted bit is the first one decoded against the reference."""
        self._first_bit = True

    def subscribe(self, callback: Callable[[BitTxn], None]) -> None:
        """Call `callback(expected_txn)` for every prediction (e.g. scoreboard.expect)."""
        self._subscribers.append(callback)

    def predict(self, txn: BitTxn) -> BitTxn:
        """Expected rx output for one accepted tx bit; also passed to every subscriber."""
        trust = self.expected_trust
        if self.diff_encoding and self._first_bit and trust is not None:
            trust = 0
        self._first_bit = False
        expected = BitTxn(
            bit=txn.bit,
            cycle=txn.cycle + self.sampled_latency,
            trust=trust,
        )
        for callback in self._subscribers:
            callback(expected)
        return expected


class BitScoreboard:
    """In-order checker of rx bits against the model's predictions.

    expect() queues an expected BitTxn (from ModemModel); observe() compares an
    observed BitTxn (from BitOutMonitor) with the oldest expected one, at once,
    so a failure points at the edge where it happened.

    Checks per bit:
      - order and count: always exact; an output with nothing expected fails.
      - latency: exact, when check_latency() is true (clk_en constant).
      - trust: when the expected trust is not None.
      - value: strict mode fails on the first wrong bit; counting mode
        (strict=False, noisy channel) tallies bit errors for the BER.
    final_check() fails if expected bits are left over.

    Assertions raised in observe() run inside the monitor's task, which fails
    the test at that edge.
    """

    def __init__(self, strict: bool = True, check_latency: Callable[[], bool] = lambda: True):
        self.strict = strict
        self.check_latency = check_latency  # e.g. lambda: clk_en_driver.constant
        self._expected: deque[BitTxn] = deque()
        self.n_compared = 0          # bits compared
        self.n_bit_errors = 0        # wrong value (counting mode)
        self.n_untrusted = 0         # observed trust = '0'
        self.n_untrusted_errors = 0  # wrong value with trust = '0'
        self.errors: list[bool] = []  # per compared bit: wrong value (e.g. errors after acquisition)

    def expect(self, txn: BitTxn) -> None:
        self._expected.append(txn)

    def observe(self, txn: BitTxn) -> None:
        index = self.n_compared
        assert self._expected, f"rx bit {index} at cycle {txn.cycle}: output with no bit expected"
        expected = self._expected.popleft()
        self.n_compared += 1

        if self.check_latency():
            assert txn.cycle == expected.cycle, (
                f"rx bit {index}: at cycle {txn.cycle}, expected at {expected.cycle} "
                f"({txn.cycle - expected.cycle:+d} clocks)"
            )
        if expected.trust is not None:
            assert txn.trust == expected.trust, (
                f"rx bit {index} at cycle {txn.cycle}: trust {txn.trust}, expected {expected.trust}"
            )

        error = txn.bit != expected.bit
        if self.strict:
            assert not error, f"rx bit {index} at cycle {txn.cycle}: {txn.bit}, expected {expected.bit}"
        self.n_bit_errors += error
        self.errors.append(error)
        if txn.trust == 0:
            self.n_untrusted += 1
            self.n_untrusted_errors += error

    def flush(self) -> None:
        """Drop all expected bits (a reset abandons the bits in flight)."""
        self._expected.clear()

    @property
    def pending(self) -> int:
        """Expected bits not yet observed."""
        return len(self._expected)

    @property
    def ber(self) -> float:
        return self.n_bit_errors / self.n_compared if self.n_compared else 0.0

    def final_check(self) -> None:
        assert not self._expected, (
            f"{self.pending} expected bit(s) never received, first expected at cycle {self._expected[0].cycle}"
        )

    def summary(self) -> str:
        return (
            f"{self.n_compared} bits, {self.n_bit_errors} errors (BER {self.ber:.3g}), "
            f"{self.n_untrusted} untrusted ({self.n_untrusted_errors} of them wrong)"
        )


class BpskTestbench:
    """Builds and wires the verification components for one DUT.

    DUT: bpsk_modem, or bpsk_channel_harness with a `channel` object between
    tx_sample_* and rx_sample_* (anything with LATENCY, start() and stop()).

    Wiring: BitInMonitor -> ModemModel.predict -> BitScoreboard.expect,
            BitOutMonitor -> BitScoreboard.observe.
    The latency check is on while ClkEnDriver is constant; change clk_en pacing
    only between run() and finish(), not while bits are in flight.

    Typical test:
        tb = BpskTestbench(dut)
        await tb.start()
        tb.clk_en.start(duty=0.6)          # optional
        await tb.run(BitSequence.random(32))
        await tb.finish()
    """

    def __init__(self, dut, channel=None, strict: bool = True, expected_trust: int | None = 1):
        self.dut = dut
        self.generics = DutGenerics.from_dut(dut)  # generics of this run, read from the DUT
        self.channel = channel
        if hasattr(dut, "rx_sample_data"):
            assert channel is not None, "bpsk_channel_harness needs a channel between tx and rx samples"
        channel_latency = channel.LATENCY if channel is not None else 0

        self.model = ModemModel(self.generics.sps, channel_latency, expected_trust, self.generics.diff_encoding)
        self.clk_en = ClkEnDriver(dut)
        self.scoreboard = BitScoreboard(strict=strict, check_latency=lambda: self.clk_en.constant)
        # bound for any single wait: a symbol at the slowest clk_en duty, plus the pipeline
        self.max_wait_cycles = 4 * (self.model.latency + self.generics.sps)
        self.driver = BitDriver(dut, max_wait_cycles=self.max_wait_cycles)
        self.in_mon = BitInMonitor(dut)
        self.out_mon = BitOutMonitor(dut)

        self.in_mon.subscribe(self.model.predict)
        self.model.subscribe(self.scoreboard.expect)
        self.out_mon.subscribe(self.scoreboard.observe)

    async def start(self) -> None:
        """Start the clock, reset the DUT, then start monitors (and channel)."""
        self.dut.reset_n.value = 0
        Clock(self.dut.clk, CLK_PERIOD_NS, unit="ns").start()
        await self.reset()
        self.in_mon.start()
        self.out_mon.start()
        if self.channel is not None:
            self.channel.start()

    async def reset(self, cycles: int = 2) -> None:
        """Hold reset_n low for `cycles` edges and release it; bits in flight are abandoned. Returns once the
        reset synchroniser in the DUT has released tx and rx (GC_RESET_STAGES more edges)."""
        self.driver.release()
        self.dut.reset_n.value = 0
        await ClockCycles(self.dut.clk, cycles)
        self.scoreboard.flush()
        self.model.reset()
        self.dut.reset_n.value = 1
        await ClockCycles(self.dut.clk, 1 + self.generics.reset_stages)

    async def run(self, sequence: BitSequence) -> None:
        """Send `sequence`; returns once its last bit is accepted (and its idle gap is over)."""
        await self.driver.send_sequence(sequence)

    async def finish(self) -> None:
        """Wait for every expected bit, wait one more pipeline length for stray
        outputs, then check that nothing is left over and log the summary."""
        while self.scoreboard.pending:
            compared = self.scoreboard.n_compared
            for _ in range(self.max_wait_cycles):
                await RisingEdge(self.dut.clk)
                if self.scoreboard.n_compared > compared:
                    break
            else:
                assert False, (
                    f"{self.scoreboard.pending} bit(s) pending, none received for {self.max_wait_cycles} cycles"
                )
        await ClockCycles(self.dut.clk, 2 * self.model.sampled_latency)  # a stray bit fails in observe()
        self.scoreboard.final_check()
        self.dut._log.info(self.scoreboard.summary())

    def stop(self) -> None:
        self.in_mon.stop()
        self.out_mon.stop()
        self.clk_en.stop()
        if self.channel is not None:
            self.channel.stop()
