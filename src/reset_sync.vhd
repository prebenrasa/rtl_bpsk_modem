--------------------------------------------------------------------------------
-- Entity  : reset_sync
-- Purpose : Reset synchroniser: asynchronous assertion, synchronous deassertion
--           of an active-low reset, for the reset input of a clock domain.
--
-- Generics
--   GC_STAGES : flip-flops in the chain. Deassertion reaches rst_n_out on the
--               GC_STAGES-th rising edge after rst_n_in is released. Range >= 2.
--
-- Clock
--   clk : the domain the reset is released into. rising edge.
--
-- Reset
--   rst_n_in  : async. active low. May come from a pin or another clock domain.
--   rst_n_out : active low. Goes '0' as soon as rst_n_in goes '0', without a
--               clock edge (also for a pulse shorter than a clock period).
--               Goes '1' only on a rising edge of clk, GC_STAGES edges after
--               rst_n_in is released, so every register it resets leaves reset
--               on the same edge, with recovery and removal timing checked.
--
-- Notes
--   - Every chain register has ASYNC_REG, so Vivado places them together and
--     treats the first as a synchroniser for metastability.
--   - The input is asynchronous to clk: constrain it with a false path to the
--     chain (set_false_path -from [get_ports <rst_n_in port>]).
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;

entity reset_sync is
    generic (
        GC_STAGES : positive := 2 -- flip-flops in the delay line: release latency in clocks
    );
    port (
        clk       : in std_logic;
        rst_n_in  : in std_logic;
        rst_n_out : out std_logic
    );
end entity reset_sync;

architecture rtl of reset_sync is
    signal s_reset_dly : std_logic_vector(GC_STAGES - 1 downto 0) := (others => '0');

    attribute ASYNC_REG            : string;
    attribute ASYNC_REG of s_reset_dly : signal is "TRUE";
begin
    assert GC_STAGES >= 2
    report "reset_sync: GC_STAGES must be >= 2 for a metastability margin"
        severity failure;

    p_delayline : process (clk, rst_n_in)
    begin
        if rst_n_in = '0' then
            s_reset_dly <= (others => '0');
        elsif rising_edge(clk) then
            s_reset_dly <= s_reset_dly(s_reset_dly'high - 1 downto 0) & '1';
        end if;
    end process;

    rst_n_out <= s_reset_dly(s_reset_dly'high);

end architecture;
