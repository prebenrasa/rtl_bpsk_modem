library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity bpsk_modem is
    generic (
        GC_SAMPLE_WIDTH : positive := 8;          -- Bit width of tx output samples and NCO L output amplitude width
        GC_SPS          : positive := 32;         -- Samples per Symbol (SPS) 
        GC_CCPS         : positive := (GC_SPS/4); -- Carrier Cycles per Symbol (CCPS) 
        GC_PHASE_WIDTH  : positive := 24;         -- N accumulator width
        GC_ADDR_WIDTH   : positive := 10;          -- M LUT address = top M bits of the phase
        GC_CORR_THRESHOLD : positive := (2 ** (GC_SAMPLE_WIDTH - 1) - 1)/2 -- threshold for classifying decision as trustworthy
    );
    port (
        clk         : in std_logic;  -- system clock
        clk_en      : in std_logic;  -- one sample per clk_en = '1'
        reset       : in std_logic;  -- async, active high
        tx_bit_data  : in std_logic;  -- bit to send, held while bit_valid = '1'
        tx_bit_valid : in std_logic;  -- bit_data holds a bit to send
        tx_bit_ready  : out std_logic; -- modulated sample, zero when not valid
        rx_bit_data  : out std_logic; -- modulated sample, zero when not valid
        rx_bit_valid : out std_logic;  -- sample_data holds a valid sample
        rx_bit_trust : out std_logic  -- sample_data holds a valid sample
    );
end entity bpsk_modem;

architecture rtl of bpsk_modem is

    signal s_sample_data : signed(GC_SAMPLE_WIDTH - 1 downto 0) := (others => '0') ;
    signal s_sample_valid : STD_LOGIC := '0';

begin
    i_tx : entity work.bpsk_tx
     generic map(
        GC_SAMPLE_WIDTH => GC_SAMPLE_WIDTH,
        GC_SPS => GC_SPS,
        GC_CCPS => GC_CCPS,
        GC_PHASE_WIDTH => GC_PHASE_WIDTH,
        GC_ADDR_WIDTH => GC_ADDR_WIDTH
    )
     port map(
        clk => clk,
        clk_en => clk_en,
        reset => reset,
        bit_data => tx_bit_data,
        bit_valid => tx_bit_valid,
        bit_ready => tx_bit_ready,
        sample_data => s_sample_data,
        sample_valid => s_sample_valid
    );

    i_rx : entity work.bpsk_rx
     generic map(
        GC_SAMPLE_WIDTH => GC_SAMPLE_WIDTH,
        GC_SPS => GC_SPS,
        GC_CCPS => GC_CCPS,
        GC_PHASE_WIDTH => GC_PHASE_WIDTH,
        GC_ADDR_WIDTH => GC_ADDR_WIDTH,
        GC_CORR_THRESHOLD => GC_CORR_THRESHOLD
    )
     port map(
        clk => clk,
        reset => reset,
        sample_data => s_sample_data,
        sample_valid => s_sample_valid,
        bit_data => rx_bit_data,
        bit_valid => rx_bit_valid,
        bit_trust => rx_bit_trust
    );

end architecture;
