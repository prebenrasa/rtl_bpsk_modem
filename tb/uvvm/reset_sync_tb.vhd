library ieee;
use ieee.std_logic_1164.all;

library uvvm_util;
context uvvm_util.uvvm_util_context;

use work.bpsk_tb_pkg.all;

entity reset_sync_tb is
    generic (
        GC_STAGES : positive := 2
    );
end entity reset_sync_tb;

architecture bhv of reset_sync_tb is
    -- entity signals
    signal clk       : std_logic := '0';
    signal clk_ena   : boolean   := false; -- clock stopped until the sequencer starts it
    signal rst_n_in  : std_logic := '0';
    signal rst_n_out : std_logic;

    -- tb helpers
    signal watchdog_ctrl : t_watchdog_ctrl := C_WATCHDOG_CTRL_DEFAULT; -- watchdog
begin
    clock_generator(clk, clk_ena, C_TCLK, "clk");
    watchdog_timer(watchdog_ctrl, 100 us, FAILURE, "reset_sync simulation hung");

    i_dut : entity work.reset_sync
        generic map(
            GC_STAGES => GC_STAGES
        )
        port map(
            clk       => clk,
            rst_n_in  => rst_n_in,
            rst_n_out => rst_n_out
        );

    -- release monitor: rst_n_out may only rise on a rising edge of clk (synchronous deassertion)
    p_release_monitor : process
    begin
        wait until rising_edge(rst_n_out);
        check_value(clk = '1' and clk'last_event = 0 ns, ERROR,
                    "rst_n_out released away from a rising edge of clk");
    end process;

    p_stimulus : process
        -- assert rst_n_in at the current time; rst_n_out must follow without a clock edge
        procedure assert_reset(constant msg : string) is
        begin
            rst_n_in <= '0';
            wait for 1 ns; -- well before any edge (callers keep C_MARGIN from the next one)
            check_value(rst_n_out, '0', ERROR, "rst_n_out not low 1 ns after rst_n_in: " & msg);
        end procedure;

        -- release rst_n_in at the current time; rst_n_out must go high on exactly the GC_STAGES-th edge after it
        procedure check_release(constant msg : string) is
            variable v_edges : natural := 0;
        begin
            rst_n_in <= '1';
            while v_edges <= GC_STAGES + 1 loop
                wait until rising_edge(clk);
                v_edges := v_edges + 1;
                wait for C_MARGIN;
                exit when rst_n_out = '1';
            end loop;
            check_value(v_edges, GC_STAGES, ERROR, "edges from release to rst_n_out high: " & msg);
        end procedure;

        variable v_phase : time;
    begin
        set_log_file_name("reset_sync_tb_log.txt");
        set_alert_file_name("reset_sync_tb_alert.txt");
        set_alert_stop_limit(ERROR, 0); -- see every failure, not just the first
        disable_log_msg(ID_POS_ACK);    -- don't log every passing check

        log(ID_LOG_HDR, "Config: GC_STAGES=" & to_string(GC_STAGES));

        log(ID_LOG_HDR, "Assertion without a clock");
        wait for C_TCLK;
        check_value(rst_n_out, '0', ERROR, "rst_n_out low at start (reset held)");
        rst_n_in <= '1';
        wait for 3 * C_TCLK; -- released, but no clock: the chain cannot shift
        check_value(rst_n_out, '0', ERROR, "rst_n_out stays low with rst_n_in released but no clock");
        clk_ena <= true;
        wait until rising_edge(clk);
        wait for C_MARGIN;
        assert_reset("clock running");
        clk_ena <= false;
        wait for 2 * C_TCLK;
        rst_n_in <= '1';
        wait for C_TCLK;
        assert_reset("clock stopped, chain cleared");
        clk_ena <= true;

        log(ID_LOG_HDR, "Deassertion takes GC_STAGES edges");
        wait until rising_edge(clk);
        wait for C_MARGIN;
        check_release("released C_MARGIN after an edge");

        log(ID_LOG_HDR, "Release at different phases of the clock");
        for k in 1 to 9 loop
            wait until rising_edge(clk);
            wait for C_MARGIN;
            assert_reset("phase " & to_string(k));
            wait until rising_edge(clk);
            v_phase := C_TCLK * k / 10;
            wait for v_phase;
            check_release("released " & to_string(v_phase) & " after an edge");
        end loop;

        log(ID_LOG_HDR, "Pulse shorter than a clock period");
        wait until rising_edge(clk);
        wait for C_MARGIN;
        rst_n_in <= '0';
        wait for C_TCLK / 4; -- ends before the next edge: no edge sees it
        check_value(rst_n_out, '0', ERROR, "rst_n_out low during a short pulse");
        check_release("after a C_TCLK/4 pulse");

        log(ID_LOG_HDR, "Short pulse with the clock stopped");
        clk_ena <= false;
        wait for 2 * C_TCLK;
        rst_n_in <= '0';
        wait for 1 ns;
        rst_n_in <= '1';
        wait for 1 ns;
        check_value(rst_n_out, '0', ERROR, "rst_n_out held low after a 1 ns pulse with no clock");
        wait for 3 * C_TCLK;
        check_value(rst_n_out, '0', ERROR, "rst_n_out still low until the clock runs");
        clk_ena <= true;
        for e in 1 to GC_STAGES loop
            wait until rising_edge(clk);
        end loop;
        wait for C_MARGIN;
        check_value(rst_n_out, '1', ERROR, "rst_n_out high after GC_STAGES edges once the clock runs");

        report_alert_counters(FINAL); -- prints "Simulation SUCCESS" or "Simulation FAILED"
        std.env.stop;
        wait;
    end process;
end architecture;
