--------------------------------------------------------------------------------
-- Entity  : bpsk_modem
-- Purpose : Loopback of bpsk_tx into bpsk_rx: modulates an input bit stream onto a
--           sine carrier and demodulates it back to bits. No channel in between.
--
-- Generics
--   GC_SAMPLE_WIDTH : width of sample_data in bits (two's complement), and the
--                     NCO amplitude width L. Range >= 2.
--   GC_SPS          : samples per symbol: one bit lasts GC_SPS valid samples.
--                     Must satisfy 2*GC_CCPS < GC_SPS (Nyquist, asserted).
--   GC_CCPS         : carrier cycles per symbol. Carrier frequency =
--                     GC_CCPS / GC_SPS cycles per sample. Range >= 1.
--                     The NCO step GC_CCPS * 2**GC_PHASE_WIDTH / GC_SPS must be
--                     an integer to ensure no phase drift.
--   GC_PHASE_WIDTH   : NCO phase accumulator width N. Sets frequency resolution.
--   GC_ADDR_WIDTH    : sine LUT address width M (2**M entries), taken from the
--                     top M bits of the phase. Must be <= GC_PHASE_WIDTH.
--   GC_CORR_THRESHOLD: trust threshold for a decision. bit_trust = '1' when
--                     |correlation| >= GC_CORR_THRESHOLD, where correlation is
--                     the sum of sample * carrier over one symbol.
--   GC_KP, GC_KI     : Costas loop gains of bpsk_rx as shifts (2**-GC_KP,
--                     2**-GC_KI). Defaults as in bpsk_rx.
--   GC_FREQ_LIMIT    : pull-in range of the bpsk_rx frequency correction, in
--                     NCO step LSBs. Default as in bpsk_rx.
--   GC_DIFF_ENCODING : differential encoding of the bits, see bpsk_tx.
--                     Default true.
--   GC_RESET_STAGES  : flip-flops in the reset synchroniser (reset_sync), the
--                     reset release latency in clocks. Range >= 2. Default 2.
--
-- Clock and enable
--   clk    : single clock domain. rising edge.
--   clk_en : paces bpsk_tx, one sample per clk_en = '1'. bpsk_rx has no clock
--            enable: it takes every sample qualified by the tx sample_valid.
--
-- Reset
--   reset_n: async assertion, active low. Its release is synchronised to clk by
--   reset_sync, so tx and rx leave reset GC_RESET_STAGES rising edges after
--   reset_n goes high, on the same edge. tx_bit_ready is valid from then on.
--   state after reset: tx idle and waiting for bit input, rx waiting for samples.
--                      Symbols in flight are abandoned.
--   tx and rx must be reset together: rx symbol alignment and carrier phase
--   follow from both sample counters and NCOs starting at 0.
--
-- Input handshake
--   A bit is accepted at a rising edge where tx_bit_valid = '1' and tx_bit_ready = '1'
--   (bpsk_tx handshake). Sender: hold tx_bit_valid and tx_bit_data until accepted.
--
-- Output
--   rx_bit_valid is a one clk pulse. rx_bit_data and rx_bit_trust hold their value
--   until the next output.
--
-- Timing (clk_en = '1' every clock)
--   Latency : GC_SPS + 7 clocks from the edge that accepts a bit to rx_bit_valid
--             (tx latency 3 + GC_SPS samples + rx latency 4).
--   Rate    : one bit per GC_SPS clk_en pulses. Back-to-back bits have no gap.
--
-- Notes
--   - tx and rx share clock and symbol timing (reset together), so no symbol
--     synchronisation is needed. The carrier phase is recovered by the Costas
--     loop in bpsk_rx, which locks at 0 or 180 degrees (inverted bits).
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

use work.bpsk_pkg.all;
use work.nco_pkg.all;

entity bpsk_modem is
    generic (
        GC_SAMPLE_WIDTH   : positive := C_DEFAULT_SAMPLE_WIDTH;                   -- Bit width of transmited and received samples and NCO L output amplitude width
        GC_SPS            : positive := C_DEFAULT_SPS;                            -- Samples per Symbol (SPS) 
        GC_CCPS           : positive := f_default_ccps(GC_SPS);                   -- Carrier Cycles per Symbol (CCPS) 
        GC_PHASE_WIDTH    : positive := C_DEFAULT_PHASE_WIDTH;                    -- N accumulator width
        GC_ADDR_WIDTH     : positive := C_DEFAULT_ADDR_WIDTH;                     -- M LUT address = top M bits of the phase
        GC_CORR_THRESHOLD : positive := f_default_corr_threshold(GC_SAMPLE_WIDTH); -- threshold for classifying decision as trustworthy
        GC_KP             : integer  := f_default_kp(GC_SAMPLE_WIDTH, GC_SPS, GC_PHASE_WIDTH); -- loop proportional gain 2**-GC_KP
        GC_KI             : integer  := f_default_ki(GC_KP, GC_SPS);                          -- loop integral gain 2**-GC_KI
        GC_FREQ_LIMIT     : natural  := to_integer(f_nco_step(GC_CCPS, GC_SPS, GC_PHASE_WIDTH)) / 8;                       -- s_freq saturates at +-GC_FREQ_LIMIT step LSBs
        GC_DIFF_ENCODING  : boolean  := true; -- differential encoding in bpsk_tx, decoding in bpsk_rx
        GC_RESET_STAGES   : positive := 2     -- reset synchroniser length: reset release latency in clocks
    );
    port (
        clk          : in std_logic;  -- system clock
        clk_en       : in std_logic;  -- one sample per clk_en = '1'
        reset_n      : in std_logic;  -- async, active low; release synchronised inside
        tx_bit_data  : in std_logic;  -- bit to send, held until accepted
        tx_bit_valid : in std_logic;  -- tx_bit_data holds a bit to send
        tx_bit_ready : out std_logic; -- a bit is accepted at the next edge if tx_bit_valid = '1'
        rx_bit_data  : out std_logic; -- decoded bit, qualified by rx_bit_valid
        rx_bit_valid : out std_logic; -- one clk pulse per decoded bit
        rx_bit_trust : out std_logic  -- '1' when |correlation| >= GC_CORR_THRESHOLD
    );
end entity bpsk_modem;

architecture rtl of bpsk_modem is

    signal s_sample_data  : signed(GC_SAMPLE_WIDTH - 1 downto 0) := (others => '0');
    signal s_sample_valid : std_logic                            := '0';
    signal s_reset_n      : std_logic; -- reset_n with synchronous deassertion, for tx and rx

begin
    -- one synchroniser for tx and rx: both leave reset on the same clock edge, which the rx symbol timing relies on
    i_reset_sync : entity work.reset_sync
        generic map(
            GC_STAGES => GC_RESET_STAGES
        )
        port map(
            clk       => clk,
            rst_n_in  => reset_n,
            rst_n_out => s_reset_n
        );

    i_tx : entity work.bpsk_tx
        generic map(
            GC_SAMPLE_WIDTH => GC_SAMPLE_WIDTH,
            GC_SPS          => GC_SPS,
            GC_CCPS         => GC_CCPS,
            GC_PHASE_WIDTH  => GC_PHASE_WIDTH,
            GC_ADDR_WIDTH    => GC_ADDR_WIDTH,
            GC_DIFF_ENCODING => GC_DIFF_ENCODING
        )
        port map(
            clk          => clk,
            clk_en       => clk_en,
            reset_n      => s_reset_n,
            bit_data     => tx_bit_data,
            bit_valid    => tx_bit_valid,
            bit_ready    => tx_bit_ready,
            sample_data  => s_sample_data,
            sample_valid => s_sample_valid
        );

    i_rx : entity work.bpsk_rx
        generic map(
            GC_SAMPLE_WIDTH   => GC_SAMPLE_WIDTH,
            GC_SPS            => GC_SPS,
            GC_CCPS           => GC_CCPS,
            GC_PHASE_WIDTH    => GC_PHASE_WIDTH,
            GC_ADDR_WIDTH     => GC_ADDR_WIDTH,
            GC_CORR_THRESHOLD => GC_CORR_THRESHOLD,
            GC_KP             => GC_KP,
            GC_KI             => GC_KI,
            GC_FREQ_LIMIT     => GC_FREQ_LIMIT,
            GC_DIFF_ENCODING  => GC_DIFF_ENCODING
        )
        port map(
            clk          => clk,
            reset_n      => s_reset_n,
            sample_data  => s_sample_data,
            sample_valid => s_sample_valid,
            bit_data     => rx_bit_data,
            bit_valid    => rx_bit_valid,
            bit_trust    => rx_bit_trust
        );

end architecture;
