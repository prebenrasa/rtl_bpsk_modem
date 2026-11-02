library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.bpsk_pkg.all;

entity bpsk_channel_harness is
    generic (
        GC_SAMPLE_WIDTH   : positive := C_DEFAULT_SAMPLE_WIDTH;                   -- Bit width of transmitted and received samples and NCO L output amplitude width
        GC_SPS            : positive := C_DEFAULT_SPS;                            -- Samples per Symbol (SPS)
        GC_CCPS           : positive := f_default_ccps(GC_SPS);                   -- Carrier Cycles per Symbol (CCPS)
        GC_PHASE_WIDTH    : positive := C_DEFAULT_PHASE_WIDTH;                    -- N accumulator width
        GC_ADDR_WIDTH     : positive := C_DEFAULT_ADDR_WIDTH;                     -- M LUT address = top M bits of the phase
        GC_TRUST_LOG2     : natural  := f_default_trust_log2(sample_width => GC_SAMPLE_WIDTH, sps => GC_SPS) -- untrusted when |correlation| < 2**GC_TRUST_LOG2
    );
    port (
        clk             : in std_logic;                             -- system clock
        clk_en          : in std_logic;                             -- one tx sample per clk_en = '1'
        reset           : in std_logic;                             -- async, active high
        tx_bit_data     : in std_logic;                             -- bit to send, held until accepted
        tx_bit_valid    : in std_logic;                             -- tx_bit_data holds a bit to send
        tx_bit_ready    : out std_logic;                            -- a bit is accepted at the next edge if tx_bit_valid = '1'
        tx_sample_data  : out signed(GC_SAMPLE_WIDTH - 1 downto 0); -- modulated sample to the channel, zero when not valid
        tx_sample_valid : out std_logic;                            -- tx_sample_data holds a valid sample
        rx_sample_data  : in signed(GC_SAMPLE_WIDTH - 1 downto 0);  -- sample from the channel
        rx_sample_valid : in std_logic;                             -- rx_sample_data holds a valid sample
        rx_bit_data     : out std_logic;                            -- decoded bit, qualified by rx_bit_valid
        rx_bit_valid    : out std_logic;                            -- one clk pulse per decoded bit
        rx_bit_trust    : out std_logic                             -- '1' when |correlation| >= 2**GC_TRUST_LOG2
    );
end entity bpsk_channel_harness;

architecture rtl of bpsk_channel_harness is
begin
    i_tx : entity work.bpsk_tx
        generic map(
            GC_SAMPLE_WIDTH => GC_SAMPLE_WIDTH,
            GC_SPS          => GC_SPS,
            GC_CCPS         => GC_CCPS,
            GC_PHASE_WIDTH  => GC_PHASE_WIDTH,
            GC_ADDR_WIDTH   => GC_ADDR_WIDTH
        )
        port map(
            clk          => clk,
            clk_en       => clk_en,
            reset        => reset,
            bit_data     => tx_bit_data,
            bit_valid    => tx_bit_valid,
            bit_ready    => tx_bit_ready,
            sample_data  => tx_sample_data,
            sample_valid => tx_sample_valid
        );

    i_rx : entity work.bpsk_rx
        generic map(
            GC_SAMPLE_WIDTH   => GC_SAMPLE_WIDTH,
            GC_SPS            => GC_SPS,
            GC_CCPS           => GC_CCPS,
            GC_PHASE_WIDTH    => GC_PHASE_WIDTH,
            GC_ADDR_WIDTH     => GC_ADDR_WIDTH,
            GC_TRUST_LOG2     => GC_TRUST_LOG2
        )
        port map(
            clk          => clk,
            reset        => reset,
            sample_data  => rx_sample_data,
            sample_valid => rx_sample_valid,
            bit_data     => rx_bit_data,
            bit_valid    => rx_bit_valid,
            bit_trust    => rx_bit_trust
        );

end architecture;
