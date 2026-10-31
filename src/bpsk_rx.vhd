--------------------------------------------------------------------------------
-- Entity  : bpsk_rx
-- Purpose : For an input stream, demodulates a sine wave and outputs the encoded bit stream
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
--
-- Clock and enable
--   clk    : single clock domain. rising edge.
--   No clock enable: the input is paced by sample_valid.
--
-- Reset
--   async. active high.
--   state after reset: bpsk_rx is idle and waiting for samples. 
--                      A symbol being received is abandoned.
--
-- Input handshake 
--   one sample per sample_valid. no backpressure.
--
-- Output
--   bit_valid is a one clk pulse. bit_data holds its value until the next output. 
--   bit_trust is updated with bit_data: '1' when |correlation| >= GC_CORR_THRESHOLD.
--   
--
-- Timing (valid every clock)
--   Latency : 4 clocks from the edge that takes the last sample of a symbol
--   Rate    : one bit per GC_SPS accepted samples
--
-- Notes
--   - Samples are qualified by sample valid strobe from upstream.
--   - The carrier assumes an integer NCO step (see GC_CCPS). Otherwise the
--     carrier phase drifts relative to the symbol boundaries.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity bpsk_rx is
    generic (
        GC_SAMPLE_WIDTH   : positive := 8;                                 -- Bit width of received samples and NCO L output amplitude width
        GC_SPS            : positive := 32;                                -- Samples per Symbol (SPS) 
        GC_CCPS           : positive := (GC_SPS/4);                        -- Carrier Cycles per Symbol (CCPS) 
        GC_PHASE_WIDTH    : positive := 24;                                -- N accumulator width
        GC_ADDR_WIDTH     : positive := 10;                                -- M LUT address = top M bits of the phase
        GC_CORR_THRESHOLD : positive := (2 ** (GC_SAMPLE_WIDTH - 1) - 1)/2 -- threshold for classifying decision as trustworthy
    );
    port (
        clk          : in std_logic;
        reset        : in std_logic;
        sample_data  : in signed(GC_SAMPLE_WIDTH - 1 downto 0);
        sample_valid : in std_logic;
        bit_data     : out std_logic;
        bit_valid    : out std_logic;
        bit_trust    : out std_logic
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
    constant C_ACC_WIDTH   : natural                               := 2 * GC_SAMPLE_WIDTH + integer(ceil(log2(real(GC_SPS))));

    -- control (reset) signals
    signal s_count : integer range 0 to GC_SPS - 1 := 0; -- sample index within current symbol

    -- decoded control (combinational)
    signal s_last  : std_logic; -- this sample tick is the last of the current symbol
    signal s_first : std_logic; -- this sample tick is the first of the current symbol

    -- datapath and delay alignment with NCO
    type signed_array_t is array (C_NCO_LATENCY - 1 downto 0) of signed(GC_SAMPLE_WIDTH - 1 downto 0);
    signal s_sample_data_dly : signed_array_t                               := (others => (others => '0'));
    signal s_last_dly        : std_logic_vector(C_NCO_LATENCY - 1 downto 0) := (others => '0');
    signal s_first_dly       : std_logic_vector(C_NCO_LATENCY - 1 downto 0) := (others => '0');

    -- NCO
    signal s_sine_valid : std_logic;
    signal s_sine_data  : signed(GC_SAMPLE_WIDTH - 1 downto 0);

    -- bit decision
    signal s_decision_product     : signed(2 * GC_SAMPLE_WIDTH - 1 downto 0) := (others => '0');
    signal s_decision_accumulator : signed(C_ACC_WIDTH - 1 downto 0)         := (others => '0');
    signal s_decision_done        : std_logic                                := '0'; -- high when s_decision_accumulator holds new symbol
    signal s_sine_valid_m         : std_logic                                := '0'; -- registers sine_valid value during multiply stage
    signal s_last_m               : std_logic                                := '0'; -- registers last value during multiply stage
    signal s_first_m               : std_logic                                := '0'; -- registers first value during multiply stage

    -- output 
    signal s_bit_data  : std_logic;
    signal s_bit_valid : std_logic;
    signal s_bit_trust : std_logic;
begin
    assert C_STEP_NUM mod GC_SPS = 0
    report "NCO step GC_CCPS * 2**GC_PHASE_WIDTH / GC_SPS is not an integer: carrier phase drifts" severity failure;

    s_last <= '1' when (s_count = GC_SPS - 1) else
        '0';
    s_first <= '1' when (s_count = 0) else
        '0';

    -- control: sample counter.
    p_ctrl : process (clk, reset)
    begin
        if reset = '1' then
            s_count <= 0;
        elsif rising_edge(clk) then
            if sample_valid = '1' then -- current sample is being processed.
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
            clk_en     => sample_valid, -- carrier advances only while receiving: phase 0 at each symbol start (if tx and rx are reset together)
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
            s_last_dly  <= s_last_dly(s_last_dly'high - 1 downto 0) & (s_last and sample_valid);
            s_first_dly <= s_first_dly(s_first_dly'high - 1 downto 0) & (s_first and sample_valid);
        end if;
    end process;

    -- stage 2: accumulate
    p_decision_data : process (clk)
    begin
        if rising_edge(clk) then
            s_decision_product <= s_sample_data_dly(s_sample_data_dly'high) * s_sine_data;

            if s_sine_valid_m then
                if s_first_m then
                    s_decision_accumulator <= resize(s_decision_product, s_decision_accumulator'length);
                else 
                    s_decision_accumulator <= s_decision_accumulator + s_decision_product;
                end if;
            end if;
        end if;
    end process;

    -- output: use correlator to decide bit value --> sum of sample x local carrier over one symbol
    -- decision rule: corr > 0 --> '1', corr < 0 --> '0', tie (corr = 0) gives '1';
    p_output : process (clk, reset)
    begin
        if reset = '1' then
            s_bit_data             <= '0';
            s_bit_valid            <= '0';
            s_bit_trust            <= '0';
            s_decision_done        <= '0';
            s_sine_valid_m         <= '0';
            s_last_m               <= '0';
            s_first_m               <= '0';
        elsif rising_edge(clk) then
            -- stage 1: multiply and register ctrl and data signals in the current cycle
            s_sine_valid_m <= s_sine_valid;
            s_last_m       <= s_sine_valid and s_last_dly(s_last_dly'high);
            s_first_m       <= s_sine_valid and s_first_dly(s_first_dly'high);

            s_decision_done <= s_sine_valid_m and s_last_m;

            -- stage 3: decision
            s_bit_valid <= s_decision_done;
            if s_decision_done = '1' then
                s_bit_data <= not s_decision_accumulator(s_decision_accumulator'high);
                if s_decision_accumulator < GC_CORR_THRESHOLD and s_decision_accumulator > (-GC_CORR_THRESHOLD) then
                    s_bit_trust <= '0';
                else
                    s_bit_trust <= '1';
                end if;
            end if;
        end if;
    end process;

    bit_trust <= s_bit_trust;
    bit_data  <= s_bit_data;
    bit_valid <= s_bit_valid;

end architecture;
