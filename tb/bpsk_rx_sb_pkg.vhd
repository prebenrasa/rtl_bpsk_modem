--------------------------------------------------------------------------------
-- Scoreboard for bpsk_rx_tb: std_logic bits, '-' expected = don't care
-- (a symbol whose decision is within the DUT's quantisation error of zero)
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;

package bpsk_rx_sb_support_pkg is
    constant C_BIT_DONT_CARE : std_logic := '-';
    function f_bit_match(received : std_logic; expected : std_logic) return boolean;
end package;

package body bpsk_rx_sb_support_pkg is
    -- don't care matches anything; otherwise exact, so a received 'X' is a mismatch
    function f_bit_match(received : std_logic; expected : std_logic) return boolean is
    begin
        if expected = C_BIT_DONT_CARE then
            return true;
        end if;
        return received = expected;
    end function;
end package body;

library ieee;
use ieee.std_logic_1164.all;
use work.bpsk_rx_sb_support_pkg.all;

library bitvis_vip_scoreboard;

package bpsk_rx_sb_pkg is new bitvis_vip_scoreboard.generic_sb_pkg
    generic map(
        t_element         => std_logic,
        element_match     => f_bit_match,
        to_string_element => to_string);
        