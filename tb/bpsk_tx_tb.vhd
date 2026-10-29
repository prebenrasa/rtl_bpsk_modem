library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

library uvvm_util;
context uvvm_util.uvvm_util_context;

library bitvis_vip_scoreboard;
use bitvis_vip_scoreboard.generic_sb_support_pkg.all;

entity bpsk_tx_tb is
    generic (
        GC_SAMPLE_WIDTH : positive := 8;
        GC_SPS          : positive := 8;
        GC_CCPS         : positive := 2;
        GC_PHASE_WIDTH  : positive := 8;
        GC_ADDR_WIDTH   : positive := 4
    );
end entity bpsk_tx_tb;

architecture bhv of bpsk_tx_tb is
    -- constants
    constant C_TCLK       : time    := 10 ns;
    constant C_TX_LATENCY : natural := 1; -- number of clock cycles from edge bit is accepted to valid output

    constant C_SAMPLE_DEFAULT : signed(GC_SAMPLE_WIDTH - 1 downto 0) := (others => '0');
    constant C_SAMPLE_LOW     : signed(GC_SAMPLE_WIDTH - 1 downto 0) := (others => '1');
    constant C_SAMPLE_HIGH    : signed(GC_SAMPLE_WIDTH - 1 downto 0) := to_signed(1, GC_SAMPLE_WIDTH);

    -- entity signals
    signal clk    : std_logic := '0';
    signal clk_en : std_logic := '0';
    signal reset  : std_logic := '1';

    signal bit_data, bit_valid, bit_ready, sample_valid : std_logic := '0';
    signal sample_data                                  : signed(GC_SAMPLE_WIDTH - 1 downto 0);

    -- tb helpers
    signal s_last_run_length : natural                  := 0;
    signal s_run_count       : natural                  := 0;
    signal s_en_pattern      : std_logic_vector(0 to 3) := "1111"; -- cycled one bit per clock

    shared variable sb   : bitvis_vip_scoreboard.int_sb_pkg.t_generic_sb; -- scoreboard
    signal watchdog_ctrl : t_watchdog_ctrl := C_WATCHDOG_CTRL_DEFAULT;    -- watchdog

    function f_expected(constant bit_value : std_logic) return integer is
    begin
        if bit_value = '1' then
            return to_integer(C_SAMPLE_HIGH);
        else
            return to_integer(C_SAMPLE_LOW);
        end if;
    end function;
    procedure add_expected_bit (constant bit_value : std_logic) is
    begin
        for i in 0 to GC_SPS - 1 loop
            sb.add_expected(f_expected(bit_value));
        end loop;
    end procedure;
begin
    clock_generator(clk, C_TCLK);
    watchdog_timer(watchdog_ctrl, 50 us, FAILURE, "bpsk_tx simulation hung");

    i_dut : entity work.bpsk_tx
        generic map(
            GC_SAMPLE_WIDTH => GC_SAMPLE_WIDTH,
            GC_SPS          => GC_SPS,
            GC_CCPS         => GC_CCPS,
            GC_PHASE_WIDTH  => GC_PHASE_WIDTH,
            GC_ADDR_WIDTH   => GC_ADDR_WIDTH
        )
        port map(
            clk          => clk,
            clk_en       => clk_en,
            reset        => reset,
            bit_data     => bit_data,
            bit_valid    => bit_valid,
            bit_ready    => bit_ready,
            sample_data  => sample_data,
            sample_valid => sample_valid
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
        -- discard waiting samples in scoreboard
        if reset = '1' then
            v_pending := false;
            if not sb.is_empty(VOID) then
                sb.flush("samples in flight are discarded by reset");
            end if;
        else
            -- once valid, hold valid and data until accepted
            if v_pending then
                check_value(bit_valid, '1', ERROR, "bit_valid dropped before transfer");
                check_value(bit_data, v_pending_bit, ERROR, "bit_data changed before transfer");
            end if;

            -- check bit_data hasn't changed and pass accepted bit to model
            if bit_ready = '1' and bit_valid = '1' then
                check_value(not is_x(bit_data), ERROR, "bit_data unknown at transfer");
                add_expected_bit(bit_data);
                v_pending := false;
            elsif bit_valid = '1' then
                v_pending     := true;
                v_pending_bit := bit_data;
            end if;
        end if;
    end process;

    -- output monitor: track number of valid samples and check valid samples against scoreboard
    p_out_monitor : process
        variable v_run_length : natural                                     := 0;
        variable v_en_dly     : std_logic_vector(C_TX_LATENCY - 1 downto 0) := ((others => '0'));
    begin
        wait until rising_edge(clk);

        --scoreboard
        if reset = '0' and sample_valid = '1' then
            sb.check_received(to_integer(sample_data));
        end if;

        -- idle rule: sample_data is 0 whenever sample_valid is low 
        if sample_valid = '0' then
            check_value(sample_data, C_SAMPLE_DEFAULT, ERROR, "sample_data not zero while sample_valid = '0'");
        end if;

        -- track transmission
        if reset = '1' then
            v_run_length := 0;
        elsif v_en_dly(v_en_dly'high) = '1' then
            if sample_valid = '1' then -- transmission initiated/ongoing
                v_run_length := v_run_length + 1;
            elsif v_run_length > 0 then -- transmission ended
                s_last_run_length <= v_run_length;
                s_run_count       <= s_run_count + 1;
                v_run_length := 0;
            end if;
        end if;

        -- shift clk_en
        v_en_dly := v_en_dly(v_en_dly'high - 1 downto 0) & clk_en;
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

        procedure send_bit (constant bit_value : std_logic) is
        begin
            bit_data  <= bit_value;
            bit_valid <= '1';
            loop wait until rising_edge(clk);
                exit when bit_ready = '1';
            end loop;
            bit_valid <= '0';
        end procedure;

        procedure apply_reset is
        begin
            reset <= '1';
            step(1);
            reset <= '0';
        end procedure;

        procedure drain is -- wait until every expected sample has arrived, then check nothing else follows
        begin
            loop
                step(1);
                exit when sb.is_empty(VOID);
            end loop;
            wait_enabled_edges(C_TX_LATENCY + 1); -- room for a stray extra sample
            check_value(sb.is_empty(VOID), ERROR, "every expected sample was received");
            check_value(sample_valid, '0', ERROR, "valid low when idle");
        end procedure;
        variable v_run_count_before : integer := 0;
    begin
        set_log_file_name("bpsk_tx_tb_log.txt");
        set_alert_file_name("bpsk_tx_tb_alert.txt");
        set_alert_stop_limit(ERROR, 0);    -- see every failure, not just the first
        set_alert_stop_limit(TB_ERROR, 0); -- the scoreboard reports a stray valid as TB_ERROR
        disable_log_msg(ID_POS_ACK);       -- don't log every passing check

        sb.config(C_SB_CONFIG_DEFAULT);
        sb.set_scope("BPSK_TX SB");
        sb.enable(VOID);
        sb.disable_log_msg(ID_DATA); -- don't log every add/check

        log(ID_LOG_HDR, "Config: SPS=" & to_string(GC_SPS) & " CCPS=" & to_string(GC_CCPS)); -- log config

        s_en_pattern <= "1111";

        log(ID_LOG_HDR, "Reset, then recover");
        apply_reset;
        check_value(sample_valid, '0', ERROR, "valid low after reset");
        check_value(bit_ready, '1', ERROR, "bit_ready high after reset");
        send_bit('1');
        drain;

        log(ID_LOG_HDR, "Latency");
        send_bit('1');
        for i in 1 to C_TX_LATENCY loop
            check_value(sample_valid, '0', ERROR, "valid low during latency");
            step(1);
        end loop;
        check_value(sample_valid, '1', ERROR, "valid high after latency");
        drain;

        log(ID_LOG_HDR, "High bit back-to-back input");
        v_run_count_before := s_run_count;
        send_bit('1');
        send_bit('1');
        drain;
        check_value(s_run_count, v_run_count_before + 1, ERROR, "Incorrect run count");
        check_value(s_last_run_length, 2 * GC_SPS, ERROR, "Incorrect number of consecutive output samples");

        log(ID_LOG_HDR, "Low bit back-to-back input");
        v_run_count_before := s_run_count;
        send_bit('0');
        send_bit('0');
        drain;
        check_value(s_run_count, v_run_count_before + 1, ERROR, "Incorrect run count");
        check_value(s_last_run_length, 2 * GC_SPS, ERROR, "Incorrect number of consecutive output samples");

        log(ID_LOG_HDR, "High-Low-High bit back-to-back input");
        v_run_count_before := s_run_count;
        send_bit('1');
        send_bit('0');
        send_bit('1');
        drain;
        check_value(s_run_count, v_run_count_before + 1, ERROR, "Incorrect run count");
        check_value(s_last_run_length, 3 * GC_SPS, ERROR, "Incorrect number of consecutive output samples");

        log(ID_LOG_HDR, "Output after completed transmission");
        send_bit('1');
        drain;

        log(ID_LOG_HDR, "Reset at every position in symbol, then recover");
        for i in 0 to GC_SPS + C_TX_LATENCY loop
            send_bit('1');
            if i > 0 then
                step(i);
            end if;
            apply_reset;
            check_value(sample_valid, '0', ERROR, "valid low after reset, i=" & to_string(i));
            check_value(sample_data, C_SAMPLE_DEFAULT, ERROR, "sample default after reset, i=" & to_string(i));
            check_value(bit_ready, '1', ERROR, "ready high after reset, i=" & to_string(i));
            send_bit('0');
            drain;
        end loop;

        log(ID_LOG_HDR, "clk_en patterns");
        for i in 0 to 2 loop
            v_run_count_before := s_run_count;
            case i is
                when 0      => s_en_pattern      <= "1010";
                when 1      => s_en_pattern      <= "1101";
                when others => s_en_pattern <= "1000";
            end case;
            send_bit('0');
            send_bit('1');
            send_bit('0');
            send_bit('1');
            drain;
            check_value(s_run_count, v_run_count_before + 1, ERROR, "Incorrect run count");
            check_value(s_last_run_length, 4 * GC_SPS, ERROR, "Incorrect number of consecutive output samples");
        end loop;
        s_en_pattern <= "1111";
        drain;
        check_value(bit_ready, '1', ERROR, "ready high when idle and enabled");

        report_alert_counters(FINAL); -- prints "Simulation SUCCESS" or "Simulation FAILED"
        std.env.stop;
        wait;
    end process;
end architecture;
