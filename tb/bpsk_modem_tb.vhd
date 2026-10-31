library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

library uvvm_util;
context uvvm_util.uvvm_util_context;

library bitvis_vip_scoreboard;
use bitvis_vip_scoreboard.generic_sb_support_pkg.all;
use work.bpsk_rx_sb_support_pkg.all;

entity bpsk_modem_tb is
    generic (
        GC_SAMPLE_WIDTH   : positive := 8;
        GC_SPS            : positive := 32;
        GC_CCPS           : positive := 8;
        GC_PHASE_WIDTH    : positive := 24;
        GC_ADDR_WIDTH     : positive := 8;
        GC_CORR_THRESHOLD : positive := (2 ** (GC_SAMPLE_WIDTH - 1) - 1)/2
    );
end entity bpsk_modem_tb;

architecture bhv of bpsk_modem_tb is
    -- constants
    constant C_TCLK : time := 10 ns;

    constant C_NCO_LATENCY   : natural := 2;                                    -- clocks from NCO clk_en to its valid sine_data
    constant C_RX_LATENCY    : natural := C_NCO_LATENCY + 2;                    -- rx: clocks from the edge that takes the last sample of a symbol to bit_valid
    constant C_TX_LATENCY    : natural := 1 + C_NCO_LATENCY;                    -- tx: clocks from the edge that accepts a bit to its first valid sample
    constant C_MODEM_LATENCY : natural := C_RX_LATENCY + C_TX_LATENCY + GC_SPS; -- clocks from the edge that accepts a bit to rx_bit_valid

    -- computed in unsigned so any GC_PHASE_WIDTH works
    constant C_STEP_NUM : unsigned(GC_PHASE_WIDTH + 31 downto 0) :=
    shift_left(resize(to_unsigned(GC_CCPS, 32), GC_PHASE_WIDTH + 32), GC_PHASE_WIDTH);
    constant C_STEP_SIZE : unsigned(GC_PHASE_WIDTH - 1 downto 0) := resize(C_STEP_NUM / GC_SPS, GC_PHASE_WIDTH);
    constant C_AMPLITUDE : integer                               := 2 ** (GC_SAMPLE_WIDTH - 1) - 1;

    -- entity signals
    signal clk    : std_logic := '0';
    signal clk_en : std_logic := '0';
    signal reset  : std_logic := '1';

    signal tx_bit_data, rx_bit_data, tx_bit_valid, rx_bit_valid, tx_bit_ready, rx_bit_trust : std_logic := '0';

    -- tb helpers
    signal s_en_pattern : std_logic_vector(0 to 3) := "1111"; -- cycled one bit per clock

    shared variable sb   : work.bpsk_rx_sb_pkg.t_generic_sb;           -- scoreboard
    signal watchdog_ctrl : t_watchdog_ctrl := C_WATCHDOG_CTRL_DEFAULT; -- watchdog

begin
    clock_generator(clk, C_TCLK);
    watchdog_timer(watchdog_ctrl, GC_SPS ** 2 * 100 * C_TCLK, FAILURE, "bpsk_modem simulation hung");

    i_dut : entity work.bpsk_modem
        generic map(
            GC_SAMPLE_WIDTH   => GC_SAMPLE_WIDTH,
            GC_SPS            => GC_SPS,
            GC_CCPS           => GC_CCPS,
            GC_PHASE_WIDTH    => GC_PHASE_WIDTH,
            GC_ADDR_WIDTH     => GC_ADDR_WIDTH,
            GC_CORR_THRESHOLD => GC_CORR_THRESHOLD
        )
        port map(
            clk          => clk,
            clk_en       => clk_en,
            reset        => reset,
            tx_bit_data  => tx_bit_data,
            tx_bit_valid => tx_bit_valid,
            tx_bit_ready => tx_bit_ready,
            rx_bit_data  => rx_bit_data,
            rx_bit_valid => rx_bit_valid,
            rx_bit_trust => rx_bit_trust
        );

    p_clk_en : process
        variable v_i : natural := 0;
    begin
        wait until rising_edge(clk);
        clk_en <= s_en_pattern(v_i);
        v_i := (v_i + 1) mod s_en_pattern'length;
    end process;

    -- input monitor: detects accepted input bits and passes them to scoreboard
    p_in_monitor : process
        variable v_pending     : boolean := false; -- valid seen without ready
        variable v_pending_bit : std_logic;
    begin
        wait until rising_edge(clk);
        -- discard waiting bits in scoreboard
        if reset = '1' then
            v_pending := false;
            if not sb.is_empty(VOID) then
                sb.flush("bits in flight are discarded by reset");
            end if;
        else
            -- once valid, hold valid and data until accepted
            if v_pending then
                check_value(tx_bit_valid, '1', ERROR, "bit_valid dropped before transfer");
                check_value(tx_bit_data, v_pending_bit, ERROR, "bit_data changed before transfer");
            end if;

            -- check bit_data hasn't changed and pass accepted bit to model
            if tx_bit_valid = '1' and tx_bit_ready = '1' then
                check_value(not is_x(tx_bit_data), ERROR, "bit_data unknown at transfer");
                sb.add_expected(tx_bit_data);
                v_pending := false;
            elsif tx_bit_valid = '1' then
                v_pending     := true;
                v_pending_bit := tx_bit_data;
            end if;
        end if;
    end process;
    p_out_monitor : process
    begin
        wait until rising_edge(clk);
        -- check reset behaviour
        if reset = '1' then
            wait for C_TCLK/4; -- avoids immediate failure at start of simulation
            check_value(rx_bit_data, '0', "bit_data not low after reset");
            check_value(rx_bit_valid, '0', "bit_valid not low after reset");
        else
            check_value(not is_x(rx_bit_data), ERROR, "bit_data unknown");
            check_value(not is_x(rx_bit_valid), ERROR, "bit_valid unknown");
        end if;

        -- check symbol decoding
        if rx_bit_valid = '1' then
            sb.check_received(rx_bit_data);
            check_value(rx_bit_trust, '1', TB_FAILURE, "Bit correlation low for noiseless input");
        end if;
    end process;

    p_stimulus : process
        procedure step(constant n : positive := 1) is
        begin
            wait_num_rising_edge_plus_margin(clk, n, C_TCLK/4);
        end procedure;
        procedure wait_enabled_edges(constant n : positive) is
            variable v_count                        : natural := 0;
            variable v_enabled                      : std_logic;
        begin
            while v_count < n loop
                v_enabled := clk_en; -- value the next edge will sample
                step(1);
                if v_enabled = '1' then
                    v_count := v_count + 1;
                end if;
            end loop;
        end procedure;
        procedure apply_reset is
        begin
            reset <= '1';
            step(1);
            reset <= '0';
        end procedure;
        procedure release_input is
        begin
            tx_bit_valid <= '0';
        end procedure;
        procedure send_bit (constant bit_value : std_logic) is
        begin
            tx_bit_data  <= bit_value;
            tx_bit_valid <= '1';
            loop wait until rising_edge(clk);
                exit when tx_bit_ready = '1';
            end loop;
            release_input;
        end procedure;
        procedure send_bits(constant bits : std_logic_vector) is
        begin
            for i in bits'range loop
                send_bit(bits(i));
            end loop;
        end procedure;
        procedure drain is                                        -- wait for every expected bit, but at most C_DRAIN_LIMIT enabled edges
            constant C_DRAIN_LIMIT : positive := C_MODEM_LATENCY + 2; -- latency + margin
            variable v_edges       : natural  := 0;
        begin
            while not sb.is_empty(VOID) and v_edges < C_DRAIN_LIMIT loop
                wait_enabled_edges(1);
                v_edges := v_edges + 1;
            end loop;
            check_value(sb.is_empty(VOID), ERROR,
            "drain timeout: " & to_string(sb.get_pending_count(VOID)) &
            " expected bit(s) not received within " & to_string(C_DRAIN_LIMIT) & " enabled edges");
            wait_enabled_edges(C_MODEM_LATENCY + 1); -- room for a stray extra bit
            check_value(rx_bit_valid, '0', ERROR, "bit_valid high when no bit is expected");
        end procedure;
    begin
        set_log_file_name("bpsk_modem_tb_log.txt");
        set_alert_file_name("bpsk_modem_tb_alert.txt");
        set_alert_stop_limit(ERROR, 0);    -- see every failure, not just the first
        set_alert_stop_limit(TB_ERROR, 0); -- the scoreboard reports a stray valid as TB_ERROR
        disable_log_msg(ID_POS_ACK);       -- don't log every passing check

        sb.config(C_SB_CONFIG_DEFAULT);
        sb.set_scope("BPSK_MODEM SB");
        sb.enable(VOID);
        sb.disable_log_msg(ID_DATA); -- don't log every add/check

        log(ID_LOG_HDR, "Config: SPS=" & to_string(GC_SPS) & " CCPS=" & to_string(GC_CCPS)); -- log config

        s_en_pattern <= "1111";

        log(ID_LOG_HDR, "Reset, then recover");
        apply_reset;
        check_value(rx_bit_data, '0', ERROR, "bit_data low after reset");
        check_value(rx_bit_valid, '0', ERROR, "bit_valid low after reset");
        check_value(tx_bit_ready, '1', ERROR, "bit_ready high after reset");
        send_bit('1');
        drain;

        log(ID_LOG_HDR, "Latency");
        send_bit('1');
        for i in 1 to C_MODEM_LATENCY loop
            check_value(rx_bit_valid, '0', ERROR, "valid low during latency i=" & to_string(i));
            step(1);
        end loop;
        check_value(rx_bit_valid, '1', ERROR, "valid high after latency");
        drain;

        log(ID_LOG_HDR, "High bit back-to-back input");
        send_bits("11");
        drain;
        log(ID_LOG_HDR, "Low bit back-to-back input");
        send_bits("00");
        drain;
        log(ID_LOG_HDR, "High-Low-High bit back-to-back input");
        send_bits("101");
        drain;

        log(ID_LOG_HDR, "Reset at every position in symbol, then recover");
        for i in 0 to C_MODEM_LATENCY + 2 loop
            send_bit('1');
            if i > 0 then
                step(i);
            end if;
            apply_reset;
            check_value(rx_bit_valid, '0', ERROR, "valid low after reset, i=" & to_string(i));
            check_value(rx_bit_data, '0', ERROR, "sample default after reset, i=" & to_string(i));
            check_value(tx_bit_ready, '1', ERROR, "ready high after reset, i=" & to_string(i));
            send_bit('0');
            drain;
        end loop;

        log(ID_LOG_HDR, "clk_en patterns");
        for i in 0 to 2 loop
            case i is
                when 0      => s_en_pattern      <= "1010";
                when 1      => s_en_pattern      <= "1101";
                when others => s_en_pattern <= "1000";
            end case;
            send_bits("0101");
            drain;
        end loop;
        s_en_pattern <= "1111";

        sb.report_counters(VOID);
        report_alert_counters(FINAL); -- prints "Simulation SUCCESS" or "Simulation FAILED"
        std.env.stop;
        wait;
    end process;
end architecture;
