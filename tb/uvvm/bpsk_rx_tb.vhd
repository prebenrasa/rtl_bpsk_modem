library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library uvvm_util;
context uvvm_util.uvvm_util_context;

library bitvis_vip_scoreboard;
use bitvis_vip_scoreboard.generic_sb_support_pkg.all;
use work.bpsk_tb_pkg.all;

entity bpsk_rx_tb is
    generic (
        GC_SAMPLE_WIDTH   : positive := work.bpsk_pkg.C_DEFAULT_SAMPLE_WIDTH;
        GC_SPS            : positive := work.bpsk_pkg.C_DEFAULT_SPS;
        GC_CCPS           : positive := work.bpsk_pkg.f_default_ccps(GC_SPS);
        GC_PHASE_WIDTH    : positive := work.bpsk_pkg.C_DEFAULT_PHASE_WIDTH;
        GC_ADDR_WIDTH     : positive := work.bpsk_pkg.C_DEFAULT_ADDR_WIDTH;
        GC_CORR_THRESHOLD : positive := work.bpsk_pkg.f_default_corr_threshold(GC_SAMPLE_WIDTH);
        GC_DIFF_ENCODING  : boolean  := false
    );
end entity bpsk_rx_tb;

architecture bhv of bpsk_rx_tb is
    -- constants: timing and models come from bpsk_tb_pkg
    constant C_CFG : t_bpsk_cfg := f_bpsk_cfg(GC_SAMPLE_WIDTH, GC_SPS, GC_CCPS, GC_PHASE_WIDTH, GC_ADDR_WIDTH);

    -- entity signals
    signal clk   : std_logic := '0';
    signal reset : std_logic := '1';

    signal bit_data, bit_valid, bit_trust, sample_valid : std_logic := '0';
    signal sample_data                                  : signed(GC_SAMPLE_WIDTH - 1 downto 0);

    -- tb helpers
    shared variable sb   : work.bpsk_bit_sb_pkg.t_generic_sb;          -- scoreboard
    signal watchdog_ctrl : t_watchdog_ctrl := C_WATCHDOG_CTRL_DEFAULT; -- watchdog

    -- per-sample number of idle edges before the sample, cycled over the symbol
    type t_gap_pattern is array (natural range <>) of natural;
    constant C_NO_GAPS     : t_gap_pattern(0 to 0) := (0 => 0);
    signal s_valid_pattern : t_gap_pattern(0 to 3) := (0, 1, 0, 3); -- number of idle edges before samples

begin
    clock_generator(clk, C_TCLK);
    watchdog_timer(watchdog_ctrl, 500 us, FAILURE, "bpsk_rx simulation hung");

    i_dut : entity work.bpsk_rx
        generic map(
            GC_SAMPLE_WIDTH   => GC_SAMPLE_WIDTH,
            GC_SPS            => GC_SPS,
            GC_CCPS           => GC_CCPS,
            GC_PHASE_WIDTH    => GC_PHASE_WIDTH,
            GC_ADDR_WIDTH     => GC_ADDR_WIDTH,
            GC_CORR_THRESHOLD => GC_CORR_THRESHOLD,
            GC_DIFF_ENCODING  => GC_DIFF_ENCODING
        )
        port map(
            clk          => clk,
            reset        => reset,
            sample_data  => sample_data,
            sample_valid => sample_valid,
            bit_data     => bit_data,
            bit_valid    => bit_valid,
            bit_trust    => bit_trust
        );

    -- input monitor: correlates the observed samples with the reference model
    -- (bpsk_tb_pkg) and passes the expected bit of each symbol to the scoreboard
    p_in_monitor : process
        variable v_symbol      : t_symbol  := C_SYMBOL_EMPTY;   -- per-symbol state
        variable v_predicted   : std_logic;                     -- symbol decision predicted from the samples
        variable v_prev_symbol : std_logic := C_DIFF_REFERENCE; -- previous predicted symbol: decoder model state
        variable v_expected    : std_logic;
    begin
        wait until rising_edge(clk);

        -- discard waiting bits in scoreboard
        if reset = '1' then
            v_symbol      := C_SYMBOL_EMPTY;
            v_prev_symbol := C_DIFF_REFERENCE;
            if not sb.is_empty(VOID) then
                sb.flush("bits in flight are discarded by reset");
            end if;
        else
            -- protocol check: check that input is not 'U'/'X''
            check_value(not is_x(sample_valid), ERROR, "sample_valid unknown");

            -- assemble the symbol using the reference carrier
            if sample_valid = '1' then
                check_value(not is_x(sample_data), ERROR, "sample_data unknown at transfer");
                v_symbol := f_add_sample(C_CFG, v_symbol, sample_data);

                if v_symbol.count = GC_SPS then
                    v_predicted := f_predict_bit(C_CFG, v_symbol);
                    if v_predicted = C_BIT_DONT_CARE then
                        log(ID_SEQUENCER, "ambiguous symbol, corr=" & to_string(v_symbol.corr, 1) & ", not checked");
                    end if;
                    -- decoding: the bit depends on this and the previous symbol, so it is a don't care if either is
                    v_expected    := f_rx_bit(GC_DIFF_ENCODING, v_predicted, v_prev_symbol);
                    v_prev_symbol := v_predicted;
                    sb.add_expected(v_expected);
                    v_symbol := C_SYMBOL_EMPTY;
                end if;
            end if;
        end if;
    end process;

    -- output monitor: checks each bit against the scoreboard, and its trust. Noiseless input, so every
    -- bit is trusted, except with decoding the first bit after reset: it uses the reference as the
    -- previous symbol, whose trust is '0'
    p_out_monitor : process
        variable v_first_bit : boolean := true; -- no bit output since reset
    begin
        wait until rising_edge(clk);
        -- check reset behaviour
        if reset = '1' then
            v_first_bit := true;
            wait for C_MARGIN; -- avoids immediate failure at start of simulation
            check_value(bit_data, '0', "bit_data not low after reset");
            check_value(bit_valid, '0', "bit_valid not low after reset");
        else
            check_value(not is_x(bit_data), ERROR, "bit_data unknown");
            check_value(not is_x(bit_valid), ERROR, "bit_valid unknown");
        end if;

        -- check symbol decoding
        if bit_valid = '1' then
            sb.check_received(bit_data);
            if GC_DIFF_ENCODING and v_first_bit then
                check_value(bit_trust, '0', ERROR, "first bit after reset trusted: it is decoded against the reference");
            else
                check_value(bit_trust, '1', TB_FAILURE, "Bit correlation low for noiseless input");
            end if;
            v_first_bit := false;
        end if;
    end process;

    p_stimulus : process
        -- loop integrator of the rx
        alias s_freq is << signal .bpsk_rx_tb.i_dut.s_freq : signed >> ;
        variable v_freq_ref                                : signed(s_freq'range);
        variable v_tx_symbol                               : std_logic := C_DIFF_REFERENCE; -- encoder model state
        variable v_bit                                     : std_logic;                     -- bit sent, to compare with bit_data

        -- reset the DUT and the encoder model together, as bpsk_tx and bpsk_rx are reset together
        procedure reset_dut is
        begin
            apply_reset(clk, reset);
            v_tx_symbol := C_DIFF_REFERENCE;
        end procedure;

        procedure send_sample(constant value : integer; gap_cycles : natural := 0) is
        begin
            for g in 1 to gap_cycles loop
                sample_valid <= '0';
                step(clk, 1);
            end loop;
            sample_valid <= '1';
            sample_data  <= to_signed(value, sample_data'length);
            step(clk, 1);
        end procedure;

        -- input back to idle: no transfer on the next edge
        procedure release_input is
        begin
            sample_valid <= '0';
        end procedure;

        -- the GC_SPS samples of the symbol for bit_value: encoded first when GC_DIFF_ENCODING.
        -- inverted: the channel flips the carrier by 180 degrees (the encoder model is unaffected)
        procedure send_symbol(constant bit_value : std_logic; gaps : t_gap_pattern := C_NO_GAPS;
                              constant inverted : boolean := false) is
            variable v_line_symbol : std_logic;
        begin
            v_tx_symbol   := f_tx_symbol(GC_DIFF_ENCODING, bit_value, v_tx_symbol);
            v_line_symbol := not v_tx_symbol when inverted else v_tx_symbol;
            for i in 0 to GC_SPS - 1 loop
                send_sample(f_tx_sample(C_CFG, v_line_symbol, i), gaps(gaps'low + i mod gaps'length));
            end loop;
            release_input;
        end procedure;

        -- partial symbols are cut off by a reset: they send bit_value as the symbol and leave the encoder model alone
        procedure send_partial_symbol(constant bit_value : std_logic; constant n_samples : natural) is
        begin
            check_value(n_samples < GC_SPS, TB_FAILURE, "send_partial_symbol: n_samples must be < GC_SPS");
            for i in 0 to n_samples - 1 loop
                send_sample(f_tx_sample(C_CFG, bit_value, i));
            end loop;
            release_input;
        end procedure;

        -- carrier phase shifted by one sample (360 * GC_CCPS / GC_SPS degrees): the products then have a
        -- Q component
        procedure send_shifted_partial_symbol(constant bit_value : std_logic; constant n_samples : natural) is
        begin
            check_value(n_samples < GC_SPS, TB_FAILURE, "send_shifted_partial_symbol: n_samples must be < GC_SPS");
            for i in 0 to n_samples - 1 loop
                send_sample(f_tx_sample(C_CFG, bit_value, (i + 1) mod GC_SPS));
            end loop;
            release_input;
        end procedure;

        procedure send_bits(constant bits : std_logic_vector) is
        begin
            for i in bits'range loop
                send_symbol(bits(i));
            end loop;
        end procedure;

        procedure drain is                                     -- wait for every expected bit, but at most C_DRAIN_LIMIT edges
            constant C_DRAIN_LIMIT : positive := C_RX_LATENCY + 2; -- latency + margin
            variable v_edges       : natural  := 0;
        begin
            while not sb.is_empty(VOID) and v_edges < C_DRAIN_LIMIT loop
                step(clk, 1);
                v_edges := v_edges + 1;
            end loop;
            check_value(sb.is_empty(VOID), ERROR,
            "drain timeout: " & to_string(sb.get_pending_count(VOID)) &
            " expected bit(s) not received within " & to_string(C_DRAIN_LIMIT) & " edges");
            step(clk, C_RX_LATENCY + 1); -- room for a stray extra bit
            check_value(bit_valid, '0', ERROR, "bit_valid high when no bit is expected");
        end procedure;
    begin
        set_log_file_name("bpsk_rx_tb_log.txt");
        set_alert_file_name("bpsk_rx_tb_alert.txt");
        set_alert_stop_limit(ERROR, 0);    -- see every failure, not just the first
        set_alert_stop_limit(TB_ERROR, 0); -- the scoreboard reports a stray valid as TB_ERROR
        disable_log_msg(ID_POS_ACK);       -- don't log every passing check

        sb.config(C_SB_CONFIG_DEFAULT);
        sb.set_scope("BPSK_RX SB");
        sb.enable(VOID);
        sb.disable_log_msg(ID_DATA); -- don't log every add/check

        log(ID_LOG_HDR, "Config: SPS=" & to_string(GC_SPS) & " CCPS=" & to_string(GC_CCPS) &
            " DIFF_ENCODING=" & to_string(GC_DIFF_ENCODING)); -- log config

        log(ID_LOG_HDR, "Reset, then recover");
        reset_dut;
        check_value(bit_data, '0', ERROR, "bit_data low after reset");
        check_value(bit_valid, '0', ERROR, "bit_valid low after reset");
        send_symbol('1');
        drain;

        log(ID_LOG_HDR, "Latency");
        send_symbol('1');
        for i in 1 to C_RX_LATENCY loop
            check_value(bit_valid, '0', ERROR, "output valid low during latency");
            step(clk, 1);
        end loop;
        check_value(bit_valid, '1', ERROR, "valid high after latency");
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

        -- with encoding, a run of 1s alternates the symbol and a run of 0s repeats it
        log(ID_LOG_HDR, "Runs of equal bits");
        send_bits("11111000001");
        drain;

        log(ID_LOG_HDR, "Reset at every position in symbol, then recover");
        for i in 0 to GC_SPS - 1 loop
            send_partial_symbol('1', i);
            reset_dut;
            check_value(bit_valid, '0', ERROR, "bit_valid low after reset, i=" & to_string(i));
            check_value(bit_data, '0', ERROR, "bit_data default after reset, i=" & to_string(i));
            send_symbol('0');
            drain;
        end loop;

        -- the product buffers of the moving sums have no reset: entries written before a reset must not
        -- be subtracted afterwards, or I and Q keep a permanent offset and the loop drifts. 
        log(ID_LOG_HDR, "Loop state after reset does not depend on the buffer contents before it");
        send_partial_symbol('1', GC_SPS - 1);
        reset_dut;
        send_bits("1010");
        drain;
        v_freq_ref := s_freq;
        send_shifted_partial_symbol('1', GC_SPS - 1);
        reset_dut;
        send_bits("1010");
        drain;
        check_value(s_freq = v_freq_ref, ERROR, "s_freq after reset depends on the buffer contents before it: " &
        to_string(to_integer(s_freq)) & ", expected " & to_string(to_integer(v_freq_ref)));

        -- the scoreboard follows the samples, so it cannot tell an inversion apart: compare with the sent bits.
        -- The first bit after reset is decoded against the reference and comes out inverted either way;
        -- after it, decoding cancels the inversion, while without encoding every bit stays inverted
        log(ID_LOG_HDR, "Carrier inverted by 180 degrees: decoding cancels the inversion");
        reset_dut;
        for i in 0 to 7 loop
            v_bit := '1' when i mod 3 = 0 else '0'; -- runs of 0s and isolated 1s
            send_symbol(v_bit, inverted => true);
            step(clk, C_RX_LATENCY);
            check_value(bit_valid, '1', ERROR, "inverted carrier: valid high after latency, i=" & to_string(i));
            if GC_DIFF_ENCODING and i > 0 then
                check_value(bit_data, v_bit, ERROR, "inverted carrier: bit not restored by decoding, i=" & to_string(i));
            else
                check_value(bit_data, not v_bit, ERROR, "inverted carrier: bit not inverted, i=" & to_string(i));
            end if;
            drain;
        end loop;

        log(ID_LOG_HDR, "sample_valid patterns");
        for i in 0 to 2 loop
            case i is
                when 0      => s_valid_pattern      <= (0, 1, 0, 3);
                when 1      => s_valid_pattern      <= (2, 0, 0, 3);
                when others => s_valid_pattern <= (0, 0, 0, 3);
            end case;
            send_symbol('0', s_valid_pattern);
            send_symbol('1', s_valid_pattern);
            send_symbol('0', s_valid_pattern);
            send_symbol('1', s_valid_pattern);
            drain;
        end loop;

        sb.report_counters(VOID);
        report_alert_counters(FINAL); -- prints "Simulation SUCCESS" or "Simulation FAILED"
        std.env.stop;
        wait;
    end process;
end architecture;
