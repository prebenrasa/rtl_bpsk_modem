--------------------------------------------------------------------------------
-- Package : bpsk_tb_pkg
-- Purpose : Shared testbench constants, utilities and reference models for
--           bpsk_tx_tb, bpsk_rx_tb and bpsk_modem_tb.
--
-- Contents
--   Timing     : C_TCLK, C_MARGIN and the spec latencies C_TX_LATENCY,
--                C_RX_LATENCY, f_modem_latency.
--   Config     : t_bpsk_cfg holds a testbench's generics, so the models need
--                one argument instead of five. Build it once per testbench:
--                constant C_CFG : t_bpsk_cfg := f_bpsk_cfg(GC_SAMPLE_WIDTH,
--                    GC_SPS, GC_CCPS, GC_PHASE_WIDTH, GC_ADDR_WIDTH);
--   Utilities  : step, wait_enabled_edges, apply_reset. Signals are passed as
--                parameters; keep a one-line local wrapper in the process,
--                e.g. procedure step(n : positive := 1) is begin step(clk, n); end;
--   Carrier    : f_amplitude, f_step, f_step_is_exact, f_lut_sample,
--                f_carrier_sample, f_tx_sample: the sample the tx sends, bit
--                exact (LUT address = top GC_ADDR_WIDTH phase bits).
--   Encoding   : C_DIFF_REFERENCE, f_tx_symbol: the symbol sent for a bit, with or
--                without differential encoding; f_rx_bit: the bit the rx outputs
--                for a symbol (the caller keeps the state in both).
--   Correlator : t_symbol, f_add_sample, f_predict_bit: expected rx decision
--                from an ideal (untruncated) carrier, with a don't care when the
--                correlation is within the DUT's quantisation error of zero.
--   Scoreboard : C_BIT_DONT_CARE and f_bit_match for bpsk_bit_sb_pkg.
--   Stimulus   : not here. bit_stream_bfm_pkg drives the valid/ready bit input
--                (bpsk_tx_tb, bpsk_modem_tb), sample_stream_bfm_pkg the sample
--                input (bpsk_rx_tb, built on f_tx_sample).
--
-- Notes
--   - Independent of the RTL: nothing here uses bpsk_pkg or nco_pkg. Latencies
--     are the spec values from the entity headers, and the carrier model
--     computes its own step, so a bug in the shared RTL code cannot hide in the
--     expected values.
--   - The testbenches' generics are not visible here: every model takes a
--     t_bpsk_cfg.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

library uvvm_util;
context uvvm_util.uvvm_util_context;

package bpsk_tb_pkg is

    -- timing ------------------------------------------------------------------
    constant C_TCLK   : time := 10 ns;    -- clock period
    constant C_MARGIN : time := C_TCLK/4; -- settle time after an edge before checking or driving

    constant C_TX_LATENCY : natural := 3; -- tx: clocks from the edge that accepts a bit to its first valid sample
    constant C_RX_LATENCY : natural := 4; -- rx: clocks from the edge that takes the last sample of a symbol to bit_valid
    constant C_RESET_LATENCY : natural := 2; -- modem: edges from reset_n released to tx and rx out of reset (reset_sync)

    -- modem: clocks from the edge that accepts a bit to rx_bit_valid (clk_en = '1' every clock)
    function f_modem_latency(sps : positive) return natural;

    -- configuration -----------------------------------------------------------
    type t_bpsk_cfg is record
        sample_width : positive; -- L: sample and amplitude width
        sps          : positive; -- samples per symbol
        ccps         : positive; -- carrier cycles per symbol
        phase_width  : positive; -- N: NCO accumulator width
        addr_width   : positive; -- M: LUT address = top M bits of the phase
    end record;

    function f_bpsk_cfg(sample_width, sps, ccps, phase_width, addr_width : positive) return t_bpsk_cfg;

    -- utilities ---------------------------------------------------------------
    -- wait n rising edges, then C_MARGIN
    procedure step(signal clk : in std_logic; constant n : in positive := 1);

    -- wait until n edges have sampled clk_en = '1', each followed by C_MARGIN.
    -- clk_en is read just before each edge: a clk_en assigned by the caller in
    -- the same delta is not seen yet (drive clk_en from its own process)
    procedure wait_enabled_edges(signal clk : in std_logic; signal clk_en : in std_logic; constant n : in positive);

    -- reset_n low for one edge, released C_MARGIN after it; then release_edges more edges, e.g. C_RESET_LATENCY
    -- for a top with a reset synchroniser, after which the DUT is out of reset
    procedure apply_reset(signal clk : in std_logic; signal reset_n : out std_logic; constant release_edges : in natural := 0);

    -- carrier model (bit exact with the tx) -----------------------------------
    function f_amplitude(cfg     : t_bpsk_cfg) return integer;                                     -- peak sample value 2**(L-1) - 1
    function f_step(cfg          : t_bpsk_cfg) return unsigned;                                    -- NCO step ccps * 2**N / sps, N bits
    function f_step_is_exact(cfg : t_bpsk_cfg) return boolean;                                     -- step has no remainder: no phase drift
    function f_lut_sample(cfg : t_bpsk_cfg; phase : unsigned) return integer;                      -- sine LUT value for a phase
    function f_carrier_sample(cfg : t_bpsk_cfg; index : natural) return integer;                   -- carrier at sample index in a symbol
    function f_tx_sample(cfg : t_bpsk_cfg; bit_value : std_logic; index : natural) return integer; -- +carrier for '1', -carrier for '0'

    -- differential encoding ---------------------------------------------------
    -- symbol d(n) = b(n) xor d(n-1): the model's state is the previous symbol, not the previous bit.
    -- sets bit to C_DIFF_REFERENCE on reset.
    constant C_DIFF_REFERENCE : std_logic := '0'; -- d(-1): the symbol state of tx (and rx) after reset

    -- the symbol sent for bit_value: bit_value itself, or bit_value xor prev_symbol when encoding
    function f_tx_symbol(diff_encoding : boolean; bit_value : std_logic; prev_symbol : std_logic) return std_logic;

    -- the bit the rx outputs for a predicted symbol: the symbol itself, or symbol xor prev_symbol when
    -- decoding. 
    function f_rx_bit(diff_encoding : boolean; symbol : std_logic; prev_symbol : std_logic) return std_logic;

    -- correlator model --------------------------------------------------------
    type t_symbol is record
        corr    : real;    -- sum x_i * ref_i
        abs_sum : real;    -- sum |x_i|
        count   : natural; -- samples collected so far
    end record;

    constant C_SYMBOL_EMPTY : t_symbol := (corr => 0.0, abs_sum => 0.0, count => 0);

    function f_ideal_carrier(cfg : t_bpsk_cfg; index : natural) return real; -- untruncated carrier, LUT scale
    function f_eps_max(cfg : t_bpsk_cfg) return real;                        -- worst |LUT - ideal| per sample, LSB
    function f_add_sample(cfg : t_bpsk_cfg; sym : t_symbol; x : signed) return t_symbol;
    function f_predict_bit(cfg : t_bpsk_cfg; sym : t_symbol) return std_logic; -- '1', '0' or C_BIT_DONT_CARE

    -- scoreboard element match ------------------------------------------------
    constant C_BIT_DONT_CARE : std_logic := '-'; -- expected bit whose decision is within quantisation error of zero

    -- don't care matches anything; otherwise exact, so a received 'X' is a mismatch
    function f_bit_match(received : std_logic; expected : std_logic) return boolean;

end package bpsk_tb_pkg;

package body bpsk_tb_pkg is

    function f_modem_latency(sps : positive) return natural is
    begin
        return C_TX_LATENCY + sps + C_RX_LATENCY;
    end function;

    function f_bpsk_cfg(sample_width, sps, ccps, phase_width, addr_width : positive) return t_bpsk_cfg is
    begin
        return (sample_width => sample_width, sps => sps, ccps => ccps,
        phase_width => phase_width, addr_width => addr_width);
    end function;

    procedure step(signal clk : in std_logic; constant n : in positive := 1) is
    begin
        wait_num_rising_edge_plus_margin(clk, n, C_MARGIN);
    end procedure;

    procedure wait_enabled_edges(signal clk : in std_logic; signal clk_en : in std_logic; constant n : in positive) is
        variable v_count   : natural := 0;
        variable v_enabled : std_logic;
    begin
        while v_count < n loop
            v_enabled := clk_en; -- value the next edge will sample
            step(clk, 1);
            if v_enabled = '1' then
                v_count := v_count + 1;
            end if;
        end loop;
    end procedure;

    procedure apply_reset(signal clk : in std_logic; signal reset_n : out std_logic; constant release_edges : in natural := 0) is
    begin
        reset_n <= '0';
        step(clk, 1);
        reset_n <= '1';
        if release_edges > 0 then
            step(clk, release_edges);
        end if;
    end procedure;

    function f_amplitude(cfg : t_bpsk_cfg) return integer is
    begin
        return 2 ** (cfg.sample_width - 1) - 1;
    end function;

    -- computed in unsigned so any phase width works
    function f_step_num(cfg : t_bpsk_cfg) return unsigned is
    begin
        return shift_left(resize(to_unsigned(cfg.ccps, 32), cfg.phase_width + 32), cfg.phase_width);
    end function;

    function f_step(cfg : t_bpsk_cfg) return unsigned is
    begin
        return resize(f_step_num(cfg) / cfg.sps, cfg.phase_width);
    end function;

    function f_step_is_exact(cfg : t_bpsk_cfg) return boolean is
    begin
        return f_step_num(cfg) mod cfg.sps = 0;
    end function;

    function f_lut_sample(cfg : t_bpsk_cfg; phase : unsigned) return integer is
        constant C_PHASE : unsigned(phase'length - 1 downto 0) := phase;
        constant C_ADDR  : natural                             := to_integer(C_PHASE(C_PHASE'high downto C_PHASE'high - cfg.addr_width + 1));
    begin
        return integer(round(sin(MATH_2_PI * real(C_ADDR) / real(2 ** cfg.addr_width)) * real(f_amplitude(cfg))));
    end function;

    -- carrier phase restarts at 0 each symbol
    function f_carrier_sample(cfg : t_bpsk_cfg; index : natural) return integer is
        variable v_phase : unsigned(cfg.phase_width - 1 downto 0);
    begin
        -- index * step, low phase_width bits kept (= mod 2**phase_width)
        v_phase := resize(to_unsigned(index, 32) * f_step(cfg), cfg.phase_width);
        return f_lut_sample(cfg, v_phase);
    end function;

    function f_tx_sample(cfg : t_bpsk_cfg; bit_value : std_logic; index : natural) return integer is
    begin
        assert index < cfg.sps
        report "f_tx_sample: index " & to_string(index) & " outside symbol" severity failure;
        assert bit_value = '0' or bit_value = '1'
        report "f_tx_sample: bit_value not 0/1" severity failure;

        if bit_value = '1' then
            return f_carrier_sample(cfg, index);
        else
            return -f_carrier_sample(cfg, index);
        end if;
    end function;

    function f_tx_symbol(diff_encoding : boolean; bit_value : std_logic; prev_symbol : std_logic) return std_logic is
    begin
        if not diff_encoding then
            return bit_value;
        elsif bit_value = prev_symbol then -- written as a comparison, not with xor as in the RTL
            return '0';
        else
            return '1';
        end if;
    end function;

    function f_rx_bit(diff_encoding : boolean; symbol : std_logic; prev_symbol : std_logic) return std_logic is
    begin
        if not diff_encoding then
            return symbol;
        elsif symbol = C_BIT_DONT_CARE or prev_symbol = C_BIT_DONT_CARE then
            return C_BIT_DONT_CARE;
        elsif symbol = prev_symbol then -- unchanged polarity: bit '0'
            return '0';
        else
            return '1';
        end if;
    end function;

    function f_ideal_carrier(cfg : t_bpsk_cfg; index : natural) return real is
    begin
        return real(f_amplitude(cfg)) * sin(MATH_2_PI * real(cfg.ccps * index) / real(cfg.sps));
    end function;

    -- 0.5 amplitude rounding + phase truncated to the LUT address
    function f_eps_max(cfg : t_bpsk_cfg) return real is
    begin
        return 0.5 + real(f_amplitude(cfg)) * MATH_2_PI / real(2 ** cfg.addr_width);
    end function;

    function f_add_sample(cfg : t_bpsk_cfg; sym : t_symbol; x : signed) return t_symbol is
        variable v_symbol : t_symbol := sym;
    begin
        v_symbol.corr    := sym.corr + real(to_integer(x)) * f_ideal_carrier(cfg, sym.count);
        v_symbol.abs_sum := sym.abs_sum + abs(real(to_integer(x)));
        v_symbol.count   := sym.count + 1;
        return v_symbol;
    end function;

    function f_predict_bit(cfg : t_bpsk_cfg; sym : t_symbol) return std_logic is
    begin
        if abs(sym.corr) <= sym.abs_sum * f_eps_max(cfg) then
            return C_BIT_DONT_CARE;
        elsif sym.corr > 0.0 then
            return '1';
        else
            return '0';
        end if;
    end function;

    function f_bit_match(received : std_logic; expected : std_logic) return boolean is
    begin
        if expected = C_BIT_DONT_CARE then
            return true;
        end if;
        return received = expected;
    end function;

end package body bpsk_tb_pkg;
