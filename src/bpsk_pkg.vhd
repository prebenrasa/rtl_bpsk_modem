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
--               for a sample width.
--
-- Notes
--   - NCO internals come from nco_pkg: the step size is
--     f_nco_step(GC_CCPS, GC_SPS, GC_PHASE_WIDTH) and the latency C_NCO_LATENCY.
--   - Vivado only evaluates asserts with synth_design -assert. The checks still
--     stop simulation at elaboration.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use work.nco_pkg.all;

package bpsk_pkg is

    -- default generic values
    constant C_DEFAULT_SAMPLE_WIDTH : positive := 8;  -- L: sample and NCO amplitude width
    constant C_DEFAULT_SPS          : positive := 32; -- samples per symbol
    constant C_DEFAULT_PHASE_WIDTH  : positive := 24; -- N: NCO accumulator width
    constant C_DEFAULT_ADDR_WIDTH   : positive := 10; -- M: LUT address = top M bits of the phase

    -- default carrier cycles per symbol for a given GC_SPS
    function f_default_ccps(sps : positive) return positive;

    -- default trust threshold for a given GC_SAMPLE_WIDTH
    function f_default_corr_threshold(sample_width : positive) return positive;

    -- asserts Nyquist (2 * ccps < sps) and an exact NCO step; returns true
    function f_check_carrier(ccps : positive; sps : positive; phase_width : positive) return boolean;

end package bpsk_pkg;

package body bpsk_pkg is

    function f_default_ccps(sps : positive) return positive is
    begin
        return sps / 4; -- sps < 4 gives 0: out of range for positive, fails elaboration
    end function;

    function f_default_corr_threshold(sample_width : positive) return positive is
    begin
        return (2 ** (sample_width - 1) - 1) / 2; -- sample_width < 3 gives 0: out of range for positive
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

end package body bpsk_pkg;
