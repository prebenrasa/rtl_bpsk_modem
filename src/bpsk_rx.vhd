--------------------------------------------------------------------------------
-- Entity  : bpsk_rx
-- Purpose : For an input stream, demodulates a sine wave and outputs the encoded bit stream
--
-- Generics
--   GC_SAMPLE_WIDTH : width of sample_data in bits (two's complement), and the
--                     NCO amplitude width L. Range >= 2.
--   GC_SPS          : samples per symbol: one bit lasts GC_SPS clk_en pulses.
--                     Must satisfy 2*GC_CCPS < GC_SPS (Nyquist, asserted).
--   GC_CCPS         : carrier cycles per symbol. Carrier frequency =
--                     GC_CCPS / GC_SPS cycles per sample. Range >= 1.
--                     The NCO step GC_CCPS * 2**GC_PHASE_WIDTH / GC_SPS must be
--                     an integer to ensure no phase drift.
--   GC_PHASE_WIDTH   : NCO phase accumulator width N. Sets frequency resolution.
--   GC_ADDR_WIDTH    : sine LUT address width M (2**M entries), taken from the
--                     top M bits of the phase. Must be <= GC_PHASE_WIDTH.
--
-- Clock and enable
--   clk    : single clock domain. rising edge.
--   clk_en : Each clock with clk_en = '1'.
--
-- Reset
--   async. active high.
--   state after reset: bpsk_rx is idle and waiting for bit input . 
--                      A symbol being received is abandoned.
--
-- Input handshake 
--   one sample per clk_en and sample_valid. no backpressure.
--
-- Output
--   bit valid is a one clk pulse. bit_data holds its value until the next output. 
--   
--
-- Timing (clk_en = '1' every clock)
--   Latency : 2 clocks from the edge that takes the last symbol
--   Rate    : one bit per GC_SPS accepted samples
--
-- Notes
--   - The carrier assumes an integer NCO step (see GC_CCPS). Otherwise the
--     carrier phase drifts relative to the symbol boundaries.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity bpsk_rx is
    generic (
        GC_SAMPLE_WIDTH : positive := 8;          -- Bit width of tx output samples and NCO L output amplitude width
        GC_SPS          : positive := 32;         -- Samples per Symbol (SPS) 
        GC_CCPS         : positive := (GC_SPS/4); -- Carrier Cycles per Symbol (CCPS) 
        GC_PHASE_WIDTH  : positive := 24;         -- N accumulator width
        GC_ADDR_WIDTH   : positive := 10          -- M LUT address = top M bits of the phase
    );
    port (
        clk          : in std_logic;
        clk_en       : in std_logic;
        reset        : in std_logic;
        sample_data  : in signed(GC_SAMPLE_WIDTH - 1 downto 0);
        sample_valid : in std_logic;
        bit_data     : out std_logic;
        bit_valid    : out std_logic
    );
begin
    assert 2 * GC_CCPS < GC_SPS
    report "Nyquist theorem: Need more than 2 samples per carrier cycle. Increase GC_SPS and/or decrease GC_CCPS" severity failure;
end entity bpsk_rx;

architecture rtl of bpsk_rx is
    -- carrier, computed in unsigned so any GC_PHASE_WIDTH works
    constant C_STEP_NUM : unsigned(GC_PHASE_WIDTH + 31 downto 0) :=
    shift_left(resize(to_unsigned(GC_CCPS, 32), GC_PHASE_WIDTH + 32), GC_PHASE_WIDTH);
        constant C_STEP_SIZE   : unsigned(GC_PHASE_WIDTH - 1 downto 0) := resize(C_STEP_NUM / GC_SPS, GC_PHASE_WIDTH);
    constant C_NCO_LATENCY : natural                               := 2; -- clocks from NCO clk_en to its valid sine_data. Must match NCO

    -- control (reset) signals
    signal s_count : integer range 0 to GC_SPS - 1 := 0; -- sample index within current symbol

    -- decoded control (combinational)
    signal s_last      : std_logic; -- this sample tick is the last of the current symbol
    signal s_sample_en : std_logic; -- a sample is taken at the next rising edge

    -- datapath and delay alignment with NCO
    type signed_array_t is array (C_NCO_LATENCY - 1 downto 0) of signed(GC_SAMPLE_WIDTH - 1 downto 0);
    signal s_sample_data_dly : signed_array_t                               := (others => (others => '0'));
    signal s_last_dly        : std_logic_vector(C_NCO_LATENCY - 1 downto 0) := (others => '0');

    -- NCO
    signal s_sine_valid : std_logic;
    signal s_sine_data  : signed(GC_SAMPLE_WIDTH - 1 downto 0);

    -- output 
    signal s_decision_accumulator : signed(2 * GC_SAMPLE_WIDTH + integer(ceil(log2(real(GC_SPS)))) - 1 downto 0) := (others => '0');
    signal s_bit_data             : std_logic;
    signal s_bit_valid            : std_logic;
begin
    assert C_STEP_NUM mod GC_SPS = 0
        report "NCO step GC_CCPS * 2**GC_PHASE_WIDTH / GC_SPS is not an integer: carrier phase drifts" severity failure;

    s_sample_en <= clk_en and sample_valid;
    s_last      <= '1' when (s_count = GC_SPS - 1) else
    '0';

    -- control: sample state and sample counter.
    p_ctrl : process (clk, reset)
    begin
        if reset = '1' then
            s_count <= 0;
        elsif rising_edge(clk) then
            if s_sample_en = '1' then -- current sample is being processed.
                if s_last = '1' then
                    s_count <= 0;
                else
                    s_count <= s_count + 1;
                end if;
            end if;
        end if;
    end process;

    i_nco : entity work.nco
        generic map(
            GC_PHASE_WIDTH  => GC_PHASE_WIDTH,
            GC_ADDR_WIDTH   => GC_ADDR_WIDTH,
            GC_SAMPLE_WIDTH => GC_SAMPLE_WIDTH
        )
        port map(
            clk        => clk,
            clk_en     => s_sample_en, -- carrier advances only while receiving: phase 0 at each symbol start (if tx and rx are reset together)
            reset      => reset,
            step_size  => C_STEP_SIZE,
            sine_valid => s_sine_valid,
            sine_data  => s_sine_data
        );

    -- sample and alignment: sample and delay the received sample by the NCO latency     
    p_sample_align_data : process (clk)
    begin
        if rising_edge(clk) then
            s_sample_data_dly <= s_sample_data_dly(s_sample_data_dly'high - 1 downto 0) & sample_data;
        end if;
    end process;

    -- alignment: delay ctrl by the NCO latency     
    p_align_ctrl : process (clk)
    begin
        if rising_edge(clk) then
            s_last_dly <= s_last_dly(s_last_dly'high - 1 downto 0) & (s_last and s_sample_en);
        end if;
    end process;

    -- output: use correlator to decide bit value --> sum of sample × local carrier over one symbol
    -- decision rule: corr ? 0 --> '1', corr < 0 --> '0', tie (corr = 0) gives '1';
    p_output : process (clk, reset)
        variable v_sum : signed(s_decision_accumulator'range); -- combinational: acc + this cycle's product
    begin
        if reset = '1' then
            s_bit_data             <= '0';
            s_bit_valid            <= '0';
            s_decision_accumulator <= (others => '0');
        elsif rising_edge(clk) then
            s_bit_valid <= '0';
            if s_sine_valid = '1' then
                v_sum := s_decision_accumulator + s_sample_data_dly(s_sample_data_dly'high) * s_sine_data;
                if s_last_dly(s_last_dly'high) then
                    s_bit_data             <= not v_sum(v_sum'high);
                    s_bit_valid            <= '1';
                    s_decision_accumulator <= (others => '0');
                else
                    s_decision_accumulator <= v_sum;
                end if;
            end if;
        end if;
    end process;

    bit_data  <= s_bit_data;
    bit_valid <= s_bit_valid;

end architecture;
