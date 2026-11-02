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
--   GC_KP            : Costas loop proportional gain as a shift: the phase error
--                     enters the NCO step scaled by 2**-GC_KP (in step LSBs,
--                     kept with C_FRAC_WIDTH fraction bits). Negative values
--                     shift left. Default: about a quarter of the phase error
--                     corrected per symbol (2*L + 2*log2(SPS) - N + 1).
--   GC_KI            : Costas loop integral gain as a shift: the phase error is
--                     added to the frequency correction scaled by 2**-GC_KI.
--                     Larger than GC_KP. Default: GC_KP + 4 + log2(SPS) (f_default_ki).
--   GC_FREQ_LIMIT    : pull-in range of the frequency correction, in NCO step
--                     LSBs: s_freq and the total correction (proportional +
--                     s_freq) saturate at +-GC_FREQ_LIMIT instead of
--                     wrapping. Default: an eighth of the nominal step
--                     (+-12.5 % of the carrier frequency).
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
-- Timing (sample_valid every clock)
--   Latency : 4 clocks from the edge that takes the last sample of a symbol
--   Rate    : one bit per GC_SPS accepted samples
--
-- Notes
--   - Samples are qualified by sample valid strobe from upstream.
--   - Carrier phase is recovered by a Costas loop: every valid sample, the
--     error sign(I) * Q adjusts the NCO step, with I and Q the moving sums of
--     sample * carrier over the last GC_SPS samples. It locks
--     at 0 or 180 degrees; at 180 degrees every bit is inverted.
--   - Loop precision: the loop filter keeps C_FRAC_WIDTH = max(GC_KP, GC_KI)
--     fraction bits below the step LSB. The rx NCO accumulator is GC_PHASE_WIDTH + C_FRAC_WIDTH bits wide
--     and takes the full-precision step.
--   - Symbol timing is not recovered: symbol boundaries follow from the sample
--     counter, so tx and rx must be reset together.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

use work.bpsk_pkg.all;
use work.nco_pkg.all;

entity bpsk_rx is
    generic (
        GC_SAMPLE_WIDTH   : positive := C_DEFAULT_SAMPLE_WIDTH;                                     -- Bit width of received samples and NCO L output amplitude width
        GC_SPS            : positive := C_DEFAULT_SPS;                                              -- Samples per Symbol (SPS) 
        GC_CCPS           : positive := f_default_ccps(GC_SPS);                                     -- Carrier Cycles per Symbol (CCPS) 
        GC_PHASE_WIDTH    : positive := C_DEFAULT_PHASE_WIDTH;                                      -- N accumulator width
        GC_ADDR_WIDTH     : positive := C_DEFAULT_ADDR_WIDTH;                                       -- M LUT address = top M bits of the phase
        GC_CORR_THRESHOLD : positive := f_default_corr_threshold(GC_SAMPLE_WIDTH);                  -- threshold for classifying decision as trustworthy
        GC_KP             : integer  := f_default_kp(GC_SAMPLE_WIDTH, GC_SPS, GC_PHASE_WIDTH);      -- loop proportional gain 2**-GC_KP
        GC_KI             : integer  := f_default_ki(GC_KP, GC_SPS);                                -- loop integral gain 2**-GC_KI
        GC_FREQ_LIMIT     : natural  := to_integer(f_nco_step(GC_CCPS, GC_SPS, GC_PHASE_WIDTH)) / 8 -- s_freq saturates at +-GC_FREQ_LIMIT step LSBs
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
end entity bpsk_rx;

architecture rtl of bpsk_rx is
    -- check carrier generics
    constant C_CARRIER_OK : boolean := f_check_carrier(GC_CCPS, GC_SPS, GC_PHASE_WIDTH);

    constant C_STEP_SIZE  : unsigned(GC_PHASE_WIDTH - 1 downto 0) := f_nco_step(GC_CCPS, GC_SPS, GC_PHASE_WIDTH);
    constant C_ACC_WIDTH  : natural                               := 2 * GC_SAMPLE_WIDTH + integer(ceil(log2(real(GC_SPS))));
    constant C_FRAC_WIDTH : natural                               := maximum(0, maximum(GC_KP, GC_KI));
    constant C_FREQ_WIDTH : natural                               := GC_PHASE_WIDTH + C_FRAC_WIDTH; -- s_freq and the rx NCO accumulator: N + F bits

    -- nominal step in the NCO's N + F format: C_FRAC_WIDTH fraction bits below the step LSB
    constant C_STEP_SIZE_Q : unsigned(C_FREQ_WIDTH - 1 downto 0) := shift_left(resize(C_STEP_SIZE, C_FREQ_WIDTH), C_FRAC_WIDTH);

    -- control (reset) signals
    signal s_count : integer range 0 to GC_SPS - 1 := 0; -- sample index within current symbol

    -- decoded control (combinational)
    signal s_last : std_logic; -- this sample tick is the last of the current symbol

    -- datapath and delay alignment with NCO
    type signed_array_t is array (natural range <>) of signed;
    signal s_sample_data_dly : signed_array_t(C_NCO_LATENCY - 1 downto 0)(GC_SAMPLE_WIDTH - 1 downto 0) := (others => (others => '0'));
    signal s_last_dly        : std_logic_vector(C_NCO_LATENCY - 1 downto 0)                             := (others => '0');

    -- NCO
    signal s_step_size  : unsigned(C_FREQ_WIDTH - 1 downto 0) := C_STEP_SIZE_Q;
    signal s_sine_valid : std_logic;
    signal s_sine_data  : signed(GC_SAMPLE_WIDTH - 1 downto 0);
    signal s_cos_data   : signed(GC_SAMPLE_WIDTH - 1 downto 0);

    -- costas loop
    signal s_freq          : signed(C_FREQ_WIDTH - 1 downto 0)                                     := (others => '0');
    signal s_error         : signed(C_ACC_WIDTH - 1 downto 0)                                      := (others => '0');
    signal s_error_valid   : std_logic                                                             := '0';
    signal s_sine_prod_dly : signed_array_t(GC_SPS - 1 downto 0)(2 * GC_SAMPLE_WIDTH - 1 downto 0) := (others => (others => '0'));
    signal s_cos_prod_dly  : signed_array_t(GC_SPS - 1 downto 0)(2 * GC_SAMPLE_WIDTH - 1 downto 0) := (others => (others => '0'));
    signal s_prod_i        : integer range 0 to GC_SPS - 1                                         := 0;
    signal s_acc_valid     : std_logic                                                             := '0'; -- high when the moving sums hold a new sample
    signal s_window_full   : std_logic                                                             := '0'; -- high once all GC_SPS buffer entries were written since reset

    -- bit decision
    signal s_sine_product     : signed(2 * GC_SAMPLE_WIDTH - 1 downto 0) := (others => '0');
    signal s_sine_accumulator : signed(C_ACC_WIDTH - 1 downto 0)         := (others => '0');
    signal s_cos_product      : signed(2 * GC_SAMPLE_WIDTH - 1 downto 0) := (others => '0');
    signal s_cos_accumulator  : signed(C_ACC_WIDTH - 1 downto 0)         := (others => '0');
    signal s_decision_done    : std_logic                                := '0'; -- high when s_sine_accumulator and s_cos_accumulator hold a new symbol
    signal s_sine_valid_m     : std_logic                                := '0'; -- registers sine_valid value during multiply stage
    signal s_last_m           : std_logic                                := '0'; -- registers last value during multiply stage

    -- output 
    signal s_bit_data  : std_logic;
    signal s_bit_valid : std_logic;
    signal s_bit_trust : std_logic;
begin

    assert GC_FREQ_LIMIT < 2 ** (GC_PHASE_WIDTH - 1)
    report "GC_FREQ_LIMIT must fit in s_freq (below 2**(GC_PHASE_WIDTH-1))"
        severity failure;
    -- in unsigned: C_STEP_SIZE + GC_FREQ_LIMIT can exceed integer'high for GC_PHASE_WIDTH = 31
    assert GC_FREQ_LIMIT <= C_STEP_SIZE and
    resize(C_STEP_SIZE, GC_PHASE_WIDTH + 1) + GC_FREQ_LIMIT < shift_left(to_unsigned(1, GC_PHASE_WIDTH + 1), GC_PHASE_WIDTH)
    report "GC_FREQ_LIMIT: the NCO step C_STEP_SIZE +- GC_FREQ_LIMIT must stay within 0 .. 2**GC_PHASE_WIDTH - 1"
        severity failure;
    -- f_scale resizes the scaled error without saturating: e * 2**-K has C_ACC_WIDTH - K integer bits,
    -- which must fit in the GC_PHASE_WIDTH integer bits of the step (and of s_freq above its fraction bits)
    assert C_ACC_WIDTH - minimum(GC_KP, GC_KI) <= GC_PHASE_WIDTH
    report "GC_KP / GC_KI too small: the scaled phase error (C_ACC_WIDTH - K bits) overflows GC_PHASE_WIDTH bits"
        severity failure;

    s_last <= '1' when (s_count = GC_SPS - 1) else
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
            GC_PHASE_WIDTH  => C_FREQ_WIDTH, -- N + F: the accumulator carries the loop's fraction bits into the phase every sample
            GC_ADDR_WIDTH   => GC_ADDR_WIDTH,
            GC_SAMPLE_WIDTH => GC_SAMPLE_WIDTH
        )
        port map(
            clk        => clk,
            clk_en     => sample_valid, -- carrier advances only while receiving; its phase is steered by the Costas loop via s_step_size
            reset      => reset,
            step_size  => s_step_size,
            sine_valid => s_sine_valid,
            sine_data  => s_sine_data,
            cos_data   => s_cos_data
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
            s_last_dly <= s_last_dly(s_last_dly'high - 1 downto 0) & (s_last and sample_valid);
        end if;
    end process;

    -- multiply, and the product buffers of the moving sums. No reset on purpose: a reset blocks mapping
    -- the buffers to LUTRAM. Instead, s_window_full keeps stale entries out of the sums after a reset.
    p_decision_storage : process (clk)
    begin
        if rising_edge(clk) then
            s_sine_product <= s_sample_data_dly(s_sample_data_dly'high) * s_sine_data;
            s_cos_product  <= s_sample_data_dly(s_sample_data_dly'high) * s_cos_data;
            if s_sine_valid_m = '1' then
                s_sine_prod_dly(s_prod_i) <= s_sine_product;
                s_cos_prod_dly(s_prod_i)  <= s_cos_product;
            end if;
        end if;
    end process;

    -- moving sum over the last GC_SPS products (ring buffer: add the new product, subtract the one
    -- GC_SPS samples old; nothing is subtracted until the buffer is full after reset).
    -- At the last sample of a symbol it is that symbol's correlation.
    p_i_decision_data : process (clk, reset)
    begin
        if reset = '1' then
            s_sine_accumulator <= (others => '0');
            s_prod_i           <= 0;
            s_acc_valid        <= '0';
            s_window_full      <= '0';
        elsif rising_edge(clk) then
            s_acc_valid <= s_sine_valid_m;
            if s_sine_valid_m = '1' then
                if s_window_full = '1' then
                    s_sine_accumulator <= s_sine_accumulator + s_sine_product - s_sine_prod_dly(s_prod_i);
                else
                    s_sine_accumulator <= s_sine_accumulator + s_sine_product;
                end if;

                if s_prod_i = GC_SPS - 1 then -- explicit wrap: no mod logic when GC_SPS is not a power of two
                    s_prod_i      <= 0;
                    s_window_full <= '1';
                else
                    s_prod_i <= s_prod_i + 1;
                end if;
            end if;
        end if;
    end process;

    p_q_decision_data : process (clk, reset)
    begin
        if reset = '1' then
            s_cos_accumulator <= (others => '0');
        elsif rising_edge(clk) then
            if s_sine_valid_m = '1' then
                if s_window_full = '1' then
                    s_cos_accumulator <= s_cos_accumulator + s_cos_product - s_cos_prod_dly(s_prod_i);
                else
                    s_cos_accumulator <= s_cos_accumulator + s_cos_product;
                end if;
            end if;
        end if;
    end process;

    p_costas_loop : process (clk, reset)
        variable v_i_term : signed(C_FREQ_WIDTH - 1 downto 0); -- integral increment, C_FRAC_WIDTH fraction bits
        variable v_freq   : signed(C_FREQ_WIDTH - 1 downto 0); -- new s_freq, also used by stage 3 in the same edge
        variable v_p_term : signed(C_FREQ_WIDTH - 1 downto 0); -- proportional correction, C_FRAC_WIDTH fraction bits
    begin
        if reset = '1' then
            s_error       <= (others => '0');
            s_freq        <= (others => '0');
            s_step_size   <= C_STEP_SIZE_Q;
            s_error_valid <= '0';
        elsif rising_edge(clk) then
            if s_acc_valid = '1' then
                -- stage 1: compute e
                if s_sine_accumulator(s_sine_accumulator'high) = '0' then -- I >= 0
                    s_error <= s_cos_accumulator;
                else
                    s_error <= - s_cos_accumulator;
                end if;
            end if;

            s_error_valid <= s_acc_valid;
            if s_error_valid = '1' then
                -- stage 2: integral path, accumulated with C_FRAC_WIDTH fraction bits, saturated at +-GC_FREQ_LIMIT
                v_i_term := f_scale(s_error, GC_KI - C_FRAC_WIDTH, C_FREQ_WIDTH);
                v_freq   := f_add_sat(s_freq, v_i_term, GC_FREQ_LIMIT, C_FREQ_WIDTH, C_FRAC_WIDTH);
                s_freq <= v_freq;

                -- stage 3: step = nominal + proportional + integral, all with C_FRAC_WIDTH fraction bits;
                -- No rounding to N bits: the NCO accumulator takes the fraction and carries it into the phase.
                -- correction is saturated within C_STEP_SIZE +- GC_FREQ_LIMIT
                v_p_term := f_scale(s_error, GC_KP - C_FRAC_WIDTH, C_FREQ_WIDTH);
                s_step_size <= C_STEP_SIZE_Q + unsigned(f_add_sat(v_p_term, v_freq, GC_FREQ_LIMIT, C_FREQ_WIDTH, C_FRAC_WIDTH));
            end if;
        end if;
    end process;

    -- output: use correlator to decide bit value --> sum of sample x local carrier over one symbol
    -- decision rule: corr > 0 --> '1', corr < 0 --> '0', tie (corr = 0) gives '1';
    p_output : process (clk, reset)
    begin
        if reset = '1' then
            s_bit_data      <= '0';
            s_bit_valid     <= '0';
            s_bit_trust     <= '0';
            s_decision_done <= '0';
            s_sine_valid_m  <= '0';
            s_last_m        <= '0';
        elsif rising_edge(clk) then
            -- stage 1: ctrl and data for multiply stage (in p_i_decision_data and p_q_decision_data)
            s_sine_valid_m <= s_sine_valid;
            s_last_m       <= s_sine_valid and s_last_dly(s_last_dly'high);

            -- stage 2: accumulate is done and accmulator holds the symbol correlation
            s_decision_done <= s_sine_valid_m and s_last_m;

            -- stage 3: decision
            s_bit_valid <= s_decision_done;
            if s_decision_done = '1' then
                s_bit_data <= not s_sine_accumulator(s_sine_accumulator'high);
                if s_sine_accumulator < GC_CORR_THRESHOLD and s_sine_accumulator > (-GC_CORR_THRESHOLD) then
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
