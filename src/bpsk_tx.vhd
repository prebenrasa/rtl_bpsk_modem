--------------------------------------------------------------------------------
-- Entity  : bpsk_tx
-- Purpose : For an input bit, modulates a sine wave and outputs a defined amount of samples per symbol
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
--   clk_en : Each clock with clk_en = '1' produces one output
--            sample of the current symbol, so a symbol lasts GC_SPS clk_en
--            pulses.
--            While clk_en = '0':
--              - the symbol position and the bit being sent are held
--              - bit_ready is '0', so no bit is accepted
--              - from the next clock, sample_valid = '0' and sample_data = 0
--
-- Reset
--   async. active high.
--   state after reset: bpsk_tx is idle and waiting for bit input . 
--                      A symbol being sent is abandoned; its remaining samples are not
--                      output.
--
-- Input handshake 
--   A bit is accepted at a rising edge where bit_valid = '1' and bit_ready = '1'.
--   bit_ready = clk_en and (idle or last sample of symbol), so back-to-back
--   bits produce symbols with no gap. bit_ready depends combinationally on clk_en 
--   and not on bit_valid.
--   Sender: hold bit_valid and bit_data stable until accepted. bit_valid must
--   not depend on bit_ready.
--
-- Output
--   sample_data is registered and qualified by sample_valid: one sample per clk_en
--   while sending, with bit 1 = +sin and bit 0 = -sin.
--   When idle or clk_en = '0': sample_valid = '0' and sample_data = 0.
--   No backpressure: the sink must accept every valid sample.
--
-- Timing (clk_en = '1' every clock)
--   Latency : 3 clocks, counted from the edge that accepts a bit to the edge where
--             its first sample appears on sample_data (sample_valid = '1').
--             The NCO pipeline has a delay of 2 clocks.
--   Rate    : one bit per GC_SPS clk_en pulses. Back-to-back bits have no gap.
--
-- Notes
--   - The carrier restarts at phase 0 for every symbol: the NCO only advances
--     on sample ticks (clk_en = s_tick), so it is stopped while idle and the
--     first sample of each symbol is 0. Back-to-back symbols stay continuous
--     because the integer-step assert makes each symbol exactly GC_CCPS
--     carrier cycles, returning the accumulator to 0
--   - The carrier assumes an integer NCO step (see GC_CCPS). Otherwise the
--     carrier phase drifts relative to the symbol boundaries.
--   - Verified by tb/bpsk_tx_tb.vhd (see makefile for configurations).
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity bpsk_tx is
    generic (
        GC_SAMPLE_WIDTH : positive := 8;          -- Bit width of tx output samples and NCO L output amplitude width
        GC_SPS          : positive := 32;         -- Samples per Symbol (SPS) 
        GC_CCPS         : positive := (GC_SPS/4); -- Carrier Cycles per Symbol (CCPS) 
        GC_PHASE_WIDTH  : positive := 24;         -- N accumulator width
        GC_ADDR_WIDTH   : positive := 10          -- M LUT address = top M bits of the phase
    );
    port (
        clk          : in std_logic;                             -- system clock
        clk_en       : in std_logic;                             -- one sample per clk_en = '1'
        reset        : in std_logic;                             -- async, active high
        bit_data     : in std_logic;                             -- bit to send, held while bit_valid = '1'
        bit_valid    : in std_logic;                             -- bit_data holds a bit to send
        bit_ready    : out std_logic;                            -- a bit is accepted at the next edge if bit_valid = '1'
        sample_data  : out signed(GC_SAMPLE_WIDTH - 1 downto 0); -- modulated sample, zero when not valid
        sample_valid : out std_logic                             -- sample_data holds a valid sample
    );
begin
    assert 2 * GC_CCPS < GC_SPS
    report "Nyquist theorem: Need more than 2 samples per carrier cycle. Increase GC_SPS and/or decrease GC_CCPS" severity failure;
end entity bpsk_tx;

architecture rtl of bpsk_tx is
    -- carrier, computed in unsigned so any GC_PHASE_WIDTH works
    constant C_STEP_NUM : unsigned(GC_PHASE_WIDTH + 31 downto 0) :=
        shift_left(resize(to_unsigned(GC_CCPS, 32), GC_PHASE_WIDTH + 32), GC_PHASE_WIDTH);
    constant C_STEP_SIZE   : unsigned(GC_PHASE_WIDTH - 1 downto 0) := resize(C_STEP_NUM / GC_SPS, GC_PHASE_WIDTH);
    constant C_NCO_LATENCY : natural                               := 2; -- clocks from NCO clk_en to its valid sine_data. Must match NCO

    constant C_SAMPLE_DEFAULT : signed(GC_SAMPLE_WIDTH - 1 downto 0) := (others => '0');

    -- control (reset) signals
    signal s_count : integer range 0 to GC_SPS - 1 := 0;   -- sample index within current symbol
    signal s_busy  : std_logic                     := '0'; -- '0' when waiting for symbol. '1' when a symbol is being transmitted

    -- decoded control (combinational)
    signal s_tick   : std_logic; -- this cycle a sample of the current symbol is being produced
    signal s_last   : std_logic; -- this sample tick is the last of the current symbol
    signal s_ready  : std_logic; -- a bit can be taken at the next rising edge
    signal s_accept : std_logic; -- a bit is taken at the next rising edge

    -- datapath
    signal s_bit_data : std_logic; -- bit being transmitted

    -- delay alignment with NCO
    signal s_bit_data_dly : std_logic_vector(C_NCO_LATENCY - 1 downto 0);

    -- NCO
    signal s_sine_valid : std_logic;
    signal s_sine_data  : signed(GC_SAMPLE_WIDTH - 1 downto 0);

    -- output
    signal s_sample_data  : signed(GC_SAMPLE_WIDTH - 1 downto 0) := C_SAMPLE_DEFAULT;
    signal s_sample_valid : std_logic                            := '0';

begin
    assert C_STEP_NUM mod GC_SPS = 0
        report "step size is not an integer: GC_CCPS * 2**GC_PHASE_WIDTH must be a multiple of GC_SPS"
        severity failure;

    -- handshake: ready when idle, and on last sample of symbol to allow zero-gap after completed transmission
    s_ready <= clk_en and (not s_busy or s_last);
    s_last  <= '1' when s_busy = '1' and (s_count = GC_SPS - 1) else
        '0';
    s_accept <= bit_valid and s_ready;
    s_tick   <= clk_en and s_busy;

    -- control: symbol state and sample counter.
    p_ctrl : process (clk, reset)
    begin
        if reset = '1' then
            s_count <= 0;
            s_busy  <= '0';
        elsif rising_edge(clk) then
            if s_accept = '1' then -- new symbol is being processed. From idle or straight after last bit
                s_busy  <= '1';
                s_count <= 0;
            elsif s_tick = '1' then -- current symbol is being processed.
                if s_last = '1' then
                    s_count <= 0;
                    s_busy  <= '0';
                else
                    s_count <= s_count + 1;
                end if;
            end if;
        end if;
    end process;

    -- datapath: the bit being transmitted.
    p_bit_data : process (clk)
    begin
        if rising_edge(clk) then
            if s_accept = '1' then
                s_bit_data <= bit_data;
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
            clk_en     => s_tick, -- carrier advances only while sending: phase 0 at each symbol start
            reset      => reset,
            step_size  => C_STEP_SIZE,
            sine_valid => s_sine_valid,
            sine_data  => s_sine_data
        );

    -- alignment: delay data by the NCO latency     
    p_align_data : process (clk)
    begin
        if rising_edge(clk) then
            s_bit_data_dly <= s_bit_data_dly(s_bit_data_dly'high - 1 downto 0) & s_bit_data;
        end if;
    end process;

    -- output: 1 = +sine, 0 = -sine, zero when idle. 
    p_output : process (clk, reset)
    begin
        if reset = '1' then
            s_sample_data  <= C_SAMPLE_DEFAULT;
            s_sample_valid <= '0';
        elsif rising_edge(clk) then
            s_sample_valid <= s_sine_valid;
            if s_sine_valid = '0' then
                s_sample_data <= C_SAMPLE_DEFAULT;
            elsif s_bit_data_dly(s_bit_data_dly'high) = '1' then
                s_sample_data <= s_sine_data;
            else
                s_sample_data <= - s_sine_data;
            end if;
        end if;
    end process;

    sample_valid <= s_sample_valid;
    bit_ready    <= s_ready;
    sample_data  <= s_sample_data;

end architecture;
