library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library uvvm_util;
context uvvm_util.uvvm_util_context;

library bitvis_vip_scoreboard;
use bitvis_vip_scoreboard.generic_sb_support_pkg.all;
use work.bpsk_tb_pkg.all;
use work.bit_stream_bfm_pkg.all;

entity bpsk_tx_tb is
    generic (
        GC_SAMPLE_WIDTH : positive := work.bpsk_pkg.C_DEFAULT_SAMPLE_WIDTH;
        GC_SPS          : positive := work.bpsk_pkg.C_DEFAULT_SPS;
        GC_CCPS         : positive := work.bpsk_pkg.f_default_ccps(GC_SPS);
        GC_PHASE_WIDTH  : positive := work.bpsk_pkg.C_DEFAULT_PHASE_WIDTH;
        GC_ADDR_WIDTH    : positive := work.bpsk_pkg.C_DEFAULT_ADDR_WIDTH;
        GC_DIFF_ENCODING : boolean  := false
    );
end entity bpsk_tx_tb;

architecture bhv of bpsk_tx_tb is
    -- constants: timing and models come from bpsk_tb_pkg
    constant C_CFG : t_bpsk_cfg := f_bpsk_cfg(GC_SAMPLE_WIDTH, GC_SPS, GC_CCPS, GC_PHASE_WIDTH, GC_ADDR_WIDTH);

    constant C_SAMPLE_DEFAULT : signed(GC_SAMPLE_WIDTH - 1 downto 0) := (others => '0');

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

    -- reference model: the GC_SPS samples expected for the symbol of an accepted bit
    procedure add_expected_bit (constant symbol : std_logic) is
    begin
        for i in 0 to GC_SPS - 1 loop
            sb.add_expected(f_tx_sample(C_CFG, symbol, i));
        end loop;
    end procedure;
begin
    assert f_step_is_exact(C_CFG)
        report "step size is not an integer: GC_CCPS * 2**GC_PHASE_WIDTH must be a multiple of GC_SPS"
        severity failure;

    clock_generator(clk, C_TCLK);
    watchdog_timer(watchdog_ctrl, 500 us, FAILURE, "bpsk_tx simulation hung");

    i_dut : entity work.bpsk_tx
        generic map(
            GC_SAMPLE_WIDTH => GC_SAMPLE_WIDTH,
            GC_SPS          => GC_SPS,
            GC_CCPS         => GC_CCPS,
            GC_PHASE_WIDTH  => GC_PHASE_WIDTH,
            GC_ADDR_WIDTH    => GC_ADDR_WIDTH,
            GC_DIFF_ENCODING => GC_DIFF_ENCODING
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

    -- input monitor: detects accepted input bits and passes their symbols to scoreboard
    p_in_monitor : process
        variable v_pending     : boolean   := false;            -- valid seen without ready
        variable v_pending_bit : std_logic;
        variable v_symbol      : std_logic := C_DIFF_REFERENCE; -- last symbol sent: encoder model state
    begin
        wait until rising_edge(clk);
        -- discard waiting samples in scoreboard
        if reset = '1' then
            v_pending := false;
            v_symbol  := C_DIFF_REFERENCE;
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
                v_symbol := f_tx_symbol(GC_DIFF_ENCODING, bit_data, v_symbol);
                add_expected_bit(v_symbol);
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
        -- local wrappers of bit_stream_bfm_pkg, bound to this testbench's signals
        procedure send_bit(constant bit_value : std_logic) is
        begin
            send_bit(bit_value, clk, bit_data, bit_valid, bit_ready);
        end procedure;
        procedure send_bits(constant bits : std_logic_vector) is
        begin
            send_bits(bits, clk, bit_data, bit_valid, bit_ready);
        end procedure;

        procedure drain is -- wait until every expected sample has arrived, then check nothing else follows
        begin
            loop
                step(clk, 1);
                exit when sb.is_empty(VOID);
            end loop;
            wait_enabled_edges(clk, clk_en, C_TX_LATENCY + 1); -- room for a stray extra sample
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
        disable_log_msg(ID_BFM);           -- don't log every bit the BFM sends

        sb.config(C_SB_CONFIG_DEFAULT);
        sb.set_scope("BPSK_TX SB");
        sb.enable(VOID);
        sb.disable_log_msg(ID_DATA); -- don't log every add/check

        log(ID_LOG_HDR, "Config: SPS=" & to_string(GC_SPS) & " CCPS=" & to_string(GC_CCPS) &
            " DIFF_ENCODING=" & to_string(GC_DIFF_ENCODING)); -- log config

        s_en_pattern <= "1111";

        log(ID_LOG_HDR, "Reset, then recover");
        apply_reset(clk, reset);
        check_value(sample_valid, '0', ERROR, "valid low after reset");
        check_value(bit_ready, '1', ERROR, "bit_ready high after reset");
        send_bit('1');
        drain;

        log(ID_LOG_HDR, "Latency");
        send_bit('1');
        for i in 1 to C_TX_LATENCY loop
            check_value(sample_valid, '0', ERROR, "valid low during latency");
            step(clk, 1);
        end loop;
        check_value(sample_valid, '1', ERROR, "valid high after latency");
        drain;

        log(ID_LOG_HDR, "High bit back-to-back input");
        v_run_count_before := s_run_count;
        send_bits("11");
        drain;
        check_value(s_run_count, v_run_count_before + 1, ERROR, "Incorrect run count");
        check_value(s_last_run_length, 2 * GC_SPS, ERROR, "Incorrect number of consecutive output samples");

        log(ID_LOG_HDR, "Low bit back-to-back input");
        v_run_count_before := s_run_count;
        send_bits("00");
        drain;
        check_value(s_run_count, v_run_count_before + 1, ERROR, "Incorrect run count");
        check_value(s_last_run_length, 2 * GC_SPS, ERROR, "Incorrect number of consecutive output samples");

        log(ID_LOG_HDR, "High-Low-High bit back-to-back input");
        v_run_count_before := s_run_count;
        send_bits("101");
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
                step(clk, i);
            end if;
            apply_reset(clk, reset);
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
            send_bits("0101");
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
