--------------------------------------------------------------------------------
-- Package : bpsk_pkg
-- Purpose : Shared defaults and carrier checks for bpsk_tx, bpsk_rx and
--           bpsk_modem.
--
-- Contents
--   Defaults  : C_DEFAULT_* generic values. Use as e.g.
--               GC_SPS : positive := C_DEFAULT_SPS
--               (derived defaults such as GC_CCPS and GC_CORR_THRESHOLD depend
--               on the entity's own generics, so they are functions).
--   Checks    : f_check_carrier asserts the carrier generics (severity failure)
--               and returns true. Call it in a constant declaration so the
--               check runs at elaboration:
--               constant C_CARRIER_OK : boolean := f_check_carrier(...);
--   Threshold : f_default_corr_threshold returns the default trust threshold
--               for |correlation| >= threshold, A**2 / 2 (one sample's worth,
--               independent of GC_SPS). Used by bpsk_rx.
--               f_default_trust_log2 is an alternative: the threshold as a
--               power of two, 2**k, k nearest to log2(full-scale correlation /
--               2**fraction_shift). Not used by bpsk_rx.
--
-- Notes
--   - NCO internals come from nco_pkg: the step size is
--     f_nco_step(GC_CCPS, GC_SPS, GC_PHASE_WIDTH) and the latency C_NCO_LATENCY.
--   - Vivado only evaluates asserts with synth_design -assert. The checks still
--     stop simulation at elaboration.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use work.nco_pkg.all;

package bpsk_pkg is

    -- default generic values
    constant C_DEFAULT_SAMPLE_WIDTH : positive := 8;  -- L: sample and NCO amplitude width
    constant C_DEFAULT_SPS          : positive := 32; -- samples per symbol
    constant C_DEFAULT_PHASE_WIDTH  : positive := 24; -- N: NCO accumulator width
    constant C_DEFAULT_ADDR_WIDTH   : positive := 10; -- M: LUT address = top M bits of the phase

    -- default carrier cycles per symbol for a given GC_SPS
    function f_default_ccps(sps : positive) return positive;

    -- alternative (not used by bpsk_rx): trust threshold as a power of two: untrusted when |correlation| < 2**k, with k the
    -- nearest integer to log2(full scale / 2**fraction_shift); full scale = A * A * sps / 2,
    -- A = 2**(sample_width-1) - 1. Within a factor sqrt(2) of the exact fraction.
    function f_default_trust_log2(sample_width : positive; sps : positive; fraction_shift : natural := 1) return natural;

    -- default integer trust threshold A**2 / 2 for a given GC_SAMPLE_WIDTH
    function f_default_corr_threshold(sample_width : positive) return positive;

    -- default Costas loop proportional gain shift (2**-kp): about a quarter of the phase error
    -- corrected per symbol, 2*L + 2*ceil(log2(SPS)) - N + 1
    function f_default_kp(sample_width : positive; sps : positive; phase_width : positive) return integer;

    -- default Costas loop integral gain shift (2**-ki): kp + 4 (near critical damping), plus
    -- ceil(log2(SPS)) since the integral path updates every sample instead of once per symbol
    function f_default_ki(kp : integer; sps : positive) return integer;

    -- asserts Nyquist (2 * ccps < sps) and an exact NCO step; returns true
    function f_check_carrier(ccps : positive; sps : positive; phase_width : positive) return boolean;

    function f_scale(e : signed; shift : integer; width : positive) return signed;

    -- x clamped to -limit .. +limit, resized to width; limit must fit in both x and width.
    -- x has frac_width fraction bits: limit is in integer units and is shifted left by frac_width
    function f_saturate(x : signed; limit : natural; width : positive; frac_width : natural := 0) return signed;

    -- a + b, saturated with f_saturate: the sum is computed one bit wider than the wider operand, so it
    -- cannot wrap before it is clamped. a and b must have the same frac_width.
    function f_add_sat(a, b : signed; limit : natural; width : positive; frac_width : natural := 0) return signed;
end package bpsk_pkg;

package body bpsk_pkg is

    function f_default_ccps(sps : positive) return positive is
    begin
        return sps / 4; -- sps < 4 gives 0: out of range for positive, fails elaboration
    end function;

    function f_default_trust_log2(sample_width : positive; sps : positive; fraction_shift : natural := 1) return natural is
        constant C_AMPLITUDE : real                                                                     := real(2 ** (sample_width - 1) - 1); -- tx and carrier amplitude A
    begin
        -- log2(A * A * sps / 2) - fraction_shift, rounded; real arithmetic runs at elaboration only
        return integer(round(2.0 * log2(C_AMPLITUDE) + log2(real(sps)))) - 1 - fraction_shift;
    end function;

    function f_default_corr_threshold(sample_width : positive) return positive is
    begin
        return ((2 ** (sample_width - 1) - 1)) ** 2 / 2; -- sample_width < 3 gives 0: out of range for positive
    end function;

    function f_default_kp(sample_width : positive; sps : positive; phase_width : positive) return integer is
    begin
        return 2 * sample_width + 2 * integer(ceil(log2(real(sps)))) - phase_width + 1;
    end function;

    function f_default_ki(kp : integer; sps : positive) return integer is
    begin
        return kp + 4 + integer(ceil(log2(real(sps))));
    end function;

    function f_check_carrier(ccps : positive; sps : positive; phase_width : positive) return boolean is
    begin
        assert 2 * ccps < sps
        report "Nyquist theorem: Need more than 2 samples per carrier cycle. Increase GC_SPS and/or decrease GC_CCPS"
            severity failure;
        assert f_nco_step_is_exact(ccps, sps, phase_width)
        report "NCO step GC_CCPS * 2**GC_PHASE_WIDTH / GC_SPS is not an integer: carrier phase drifts"
            severity failure;
        return true;
    end function;

    -- e * 2**-shift, resized to width; shift < 0 shifts left. Right-shifts before resizing to keep the top bits.
    -- A right shift rounds to nearest: plain shift_right rounds toward -inf, which biases a loop integrator
    function f_scale(e : signed; shift : integer; width : positive) return signed is
        variable v_e : signed(e'length downto 0); -- one bit wider: adding the half LSB cannot overflow
    begin
        if shift > 0 then
            v_e := resize(e, v_e'length) + shift_left(to_signed(1, v_e'length), shift - 1);
            return resize(shift_right(v_e, shift), width);
        elsif shift = 0 then
            return resize(e, width);
        else
            return shift_left(resize(e, width), -shift);
        end if;
    end function;

    -- compare at the width of x, so a sum computed with a guard bit is clamped before it is narrowed;
    -- the limit is shifted in signed, so limit * 2**frac_width may exceed integer'high
    function f_saturate(x : signed; limit : natural; width : positive; frac_width : natural := 0) return signed is
        constant C_LIMIT : signed(x'length - 1 downto 0)                                        := shift_left(to_signed(limit, x'length), frac_width);
    begin
        if x > C_LIMIT then
            return resize(C_LIMIT, width);
        elsif x <- C_LIMIT then
            return resize(-C_LIMIT, width);
        else
            return resize(x, width);
        end if;
    end function;

    function f_add_sat(a, b : signed; limit : natural; width : positive; frac_width : natural := 0) return signed is
        constant C_SUM_WIDTH : positive                                                           := maximum(a'length, b'length) + 1; -- guard bit
    begin
        return f_saturate(resize(a, C_SUM_WIDTH) + resize(b, C_SUM_WIDTH), limit, width, frac_width);
    end function;

end package body bpsk_pkg;
