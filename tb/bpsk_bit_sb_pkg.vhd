--------------------------------------------------------------------------------
-- Scoreboard for decoded bits, shared by bpsk_rx_tb and bpsk_modem_tb:
-- std_logic bits, '-' expected = don't care. Match rule: f_bit_match in bpsk_tb_pkg.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use work.bpsk_tb_pkg.all;

library bitvis_vip_scoreboard;

package bpsk_bit_sb_pkg is new bitvis_vip_scoreboard.generic_sb_pkg
    generic map(
        t_element         => std_logic,
        element_match     => f_bit_match,
        to_string_element => to_string);
