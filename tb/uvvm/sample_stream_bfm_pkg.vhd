--------------------------------------------------------------------------------
-- Package : sample_stream_bfm_pkg
-- Purpose : BFM for a valid-only sample stream (bpsk_rx sample input): drives
--           sample_data/sample_valid, sample by sample or as whole BPSK symbols
--           from the reference carrier in bpsk_tb_pkg.
--
-- Contents
--   Gaps       : t_gap_pattern, C_NO_GAPS.
--   Config     : t_sample_stream_bfm_config, C_SAMPLE_STREAM_BFM_CONFIG_DEFAULT.
--   Procedures : send_sample, send_symbol, send_partial_symbol, send_symbols,
--                release_sample_stream.
--
-- Protocol
--   A sample is transferred at every rising edge where sample_valid = '1'.
--   No backpressure.
--
-- Timing
--   - Call after an edge (e.g. C_MARGIN after it). send_sample holds
--     sample_valid = '0' for gap_cycles edges, then drives the sample and waits
--     for the edge that takes it, plus config.margin.
--   - sample_valid stays '1' after send_sample, so consecutive calls give
--     back-to-back samples. send_symbol, send_partial_symbol and send_symbols
--     release the stream at the end.
--
-- Gaps
--   gaps(i mod gaps'length) is the number of idle edges before sample i of a
--   symbol, so a short pattern repeats over the symbol. C_NO_GAPS = none.
--
-- Usage
--   Signals and the testbench's t_bpsk_cfg are passed as parameters. Keep
--   one-line local wrappers in the sequencer process:
--     procedure send_symbol(constant bit_value : std_logic; constant gaps : t_gap_pattern := C_NO_GAPS) is
--     begin
--         send_symbol(bit_value, C_CFG, clk, sample_data, sample_valid, gaps);
--     end procedure;
--   Logging uses config.id_for_bfm (ID_BFM), once per symbol, not per sample.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library uvvm_util;
context uvvm_util.uvvm_util_context;

use work.bpsk_tb_pkg.all;

package sample_stream_bfm_pkg is

    -- idle edges before each sample of a symbol, repeated over the symbol
    type t_gap_pattern is array (natural range <>) of natural;

    constant C_NO_GAPS : t_gap_pattern(0 to 0) := (0 => 0);

    type t_sample_stream_bfm_config is record
        margin     : time;     -- wait after the transfer edge before returning
        id_for_bfm : t_msg_id; -- log message ID for each symbol
    end record;

    constant C_SAMPLE_STREAM_BFM_CONFIG_DEFAULT : t_sample_stream_bfm_config := (
        margin     => C_MARGIN,
        id_for_bfm => ID_BFM
    );

    -- send one sample after gap_cycles idle edges; sample_valid stays '1'
    procedure send_sample(
        constant value        : in  integer;
        signal   clk          : in  std_logic;
        signal   sample_data  : out signed;
        signal   sample_valid : out std_logic;
        constant gap_cycles   : in  natural                    := 0;
        constant scope        : in  string                     := C_TB_SCOPE_DEFAULT;
        constant config       : in  t_sample_stream_bfm_config := C_SAMPLE_STREAM_BFM_CONFIG_DEFAULT);

    -- send the first n_samples (0 .. cfg.sps-1) samples of a symbol, then release
    procedure send_partial_symbol(
        constant bit_value    : in  std_logic;
        constant n_samples    : in  natural;
        constant cfg          : in  t_bpsk_cfg;
        signal   clk          : in  std_logic;
        signal   sample_data  : out signed;
        signal   sample_valid : out std_logic;
        constant gaps         : in  t_gap_pattern              := C_NO_GAPS;
        constant msg          : in  string                     := "";
        constant scope        : in  string                     := C_TB_SCOPE_DEFAULT;
        constant msg_id_panel : in  t_msg_id_panel             := shared_msg_id_panel;
        constant config       : in  t_sample_stream_bfm_config := C_SAMPLE_STREAM_BFM_CONFIG_DEFAULT);

    -- send one full symbol (cfg.sps samples): +carrier for '1', -carrier for '0'
    procedure send_symbol(
        constant bit_value    : in  std_logic;
        constant cfg          : in  t_bpsk_cfg;
        signal   clk          : in  std_logic;
        signal   sample_data  : out signed;
        signal   sample_valid : out std_logic;
        constant gaps         : in  t_gap_pattern              := C_NO_GAPS;
        constant msg          : in  string                     := "";
        constant scope        : in  string                     := C_TB_SCOPE_DEFAULT;
        constant msg_id_panel : in  t_msg_id_panel             := shared_msg_id_panel;
        constant config       : in  t_sample_stream_bfm_config := C_SAMPLE_STREAM_BFM_CONFIG_DEFAULT);

    -- send one symbol per bit, left to right, back to back
    procedure send_symbols(
        constant bits         : in  std_logic_vector;
        constant cfg          : in  t_bpsk_cfg;
        signal   clk          : in  std_logic;
        signal   sample_data  : out signed;
        signal   sample_valid : out std_logic;
        constant gaps         : in  t_gap_pattern              := C_NO_GAPS;
        constant msg          : in  string                     := "";
        constant scope        : in  string                     := C_TB_SCOPE_DEFAULT;
        constant msg_id_panel : in  t_msg_id_panel             := shared_msg_id_panel;
        constant config       : in  t_sample_stream_bfm_config := C_SAMPLE_STREAM_BFM_CONFIG_DEFAULT);

    -- input back to idle: no transfer on the next edge
    procedure release_sample_stream(signal sample_valid : out std_logic);

end package sample_stream_bfm_pkg;

package body sample_stream_bfm_pkg is

    procedure send_sample(
        constant value        : in  integer;
        signal   clk          : in  std_logic;
        signal   sample_data  : out signed;
        signal   sample_valid : out std_logic;
        constant gap_cycles   : in  natural                    := 0;
        constant scope        : in  string                     := C_TB_SCOPE_DEFAULT;
        constant config       : in  t_sample_stream_bfm_config := C_SAMPLE_STREAM_BFM_CONFIG_DEFAULT) is
        constant C_MAX   : integer := 2 ** (sample_data'length - 1) - 1;
        variable v_value : integer := value;
    begin
        if value > C_MAX or value < -C_MAX - 1 then
            alert(TB_ERROR, "send_sample(" & to_string(value) & ") => outside the " &
                  to_string(sample_data'length) & "-bit signed range: saturated", scope);
            v_value := maximum(-C_MAX - 1, minimum(C_MAX, value));
        end if;

        for g in 1 to gap_cycles loop
            sample_valid <= '0';
            wait_num_rising_edge_plus_margin(clk, 1, config.margin);
        end loop;

        sample_valid <= '1';
        sample_data  <= to_signed(v_value, sample_data'length);
        wait_num_rising_edge_plus_margin(clk, 1, config.margin);
    end procedure;

    procedure send_partial_symbol(
        constant bit_value    : in  std_logic;
        constant n_samples    : in  natural;
        constant cfg          : in  t_bpsk_cfg;
        signal   clk          : in  std_logic;
        signal   sample_data  : out signed;
        signal   sample_valid : out std_logic;
        constant gaps         : in  t_gap_pattern              := C_NO_GAPS;
        constant msg          : in  string                     := "";
        constant scope        : in  string                     := C_TB_SCOPE_DEFAULT;
        constant msg_id_panel : in  t_msg_id_panel             := shared_msg_id_panel;
        constant config       : in  t_sample_stream_bfm_config := C_SAMPLE_STREAM_BFM_CONFIG_DEFAULT) is
        constant C_PROC_CALL : string := "send_partial_symbol(" & to_string(bit_value) & ", " & to_string(n_samples) & ")";
    begin
        if n_samples >= cfg.sps then
            alert(TB_ERROR, C_PROC_CALL & " => n_samples must be < sps = " & to_string(cfg.sps) &
                  " (use send_symbol). " & add_msg_delimiter(msg), scope);
            return;
        end if;

        for i in 0 to n_samples - 1 loop
            send_sample(f_tx_sample(cfg, bit_value, i), clk, sample_data, sample_valid,
                        gaps(gaps'low + i mod gaps'length), scope, config);
        end loop;
        release_sample_stream(sample_valid);
        log(config.id_for_bfm, C_PROC_CALL & " => done. " & add_msg_delimiter(msg), scope, msg_id_panel);
    end procedure;

    procedure send_symbol(
        constant bit_value    : in  std_logic;
        constant cfg          : in  t_bpsk_cfg;
        signal   clk          : in  std_logic;
        signal   sample_data  : out signed;
        signal   sample_valid : out std_logic;
        constant gaps         : in  t_gap_pattern              := C_NO_GAPS;
        constant msg          : in  string                     := "";
        constant scope        : in  string                     := C_TB_SCOPE_DEFAULT;
        constant msg_id_panel : in  t_msg_id_panel             := shared_msg_id_panel;
        constant config       : in  t_sample_stream_bfm_config := C_SAMPLE_STREAM_BFM_CONFIG_DEFAULT) is
    begin
        for i in 0 to cfg.sps - 1 loop
            send_sample(f_tx_sample(cfg, bit_value, i), clk, sample_data, sample_valid,
                        gaps(gaps'low + i mod gaps'length), scope, config);
        end loop;
        release_sample_stream(sample_valid);
        log(config.id_for_bfm, "send_symbol(" & to_string(bit_value) & ") => done. " & add_msg_delimiter(msg),
            scope, msg_id_panel);
    end procedure;

    procedure send_symbols(
        constant bits         : in  std_logic_vector;
        constant cfg          : in  t_bpsk_cfg;
        signal   clk          : in  std_logic;
        signal   sample_data  : out signed;
        signal   sample_valid : out std_logic;
        constant gaps         : in  t_gap_pattern              := C_NO_GAPS;
        constant msg          : in  string                     := "";
        constant scope        : in  string                     := C_TB_SCOPE_DEFAULT;
        constant msg_id_panel : in  t_msg_id_panel             := shared_msg_id_panel;
        constant config       : in  t_sample_stream_bfm_config := C_SAMPLE_STREAM_BFM_CONFIG_DEFAULT) is
    begin
        -- the release at the end of each symbol is overridden by the next sample in the same delta
        for i in bits'range loop
            send_symbol(bits(i), cfg, clk, sample_data, sample_valid, gaps, msg, scope, msg_id_panel, config);
        end loop;
    end procedure;

    procedure release_sample_stream(signal sample_valid : out std_logic) is
    begin
        sample_valid <= '0';
    end procedure;

end package body sample_stream_bfm_pkg;
