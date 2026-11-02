--------------------------------------------------------------------------------
-- Package : bit_stream_bfm_pkg
-- Purpose : BFM for a valid/ready bit stream (bpsk_tx bit input, bpsk_modem
--           tx_bit input): drives bit_data/bit_valid and completes the handshake.
--
-- Contents
--   Config     : t_bit_stream_bfm_config, C_BIT_STREAM_BFM_CONFIG_DEFAULT.
--   Procedures : send_bit, send_bits, release_bit_stream.
--
-- Protocol
--   A bit is transferred at a rising edge where bit_valid = '1' and
--   bit_ready = '1'. The sender holds bit_valid and bit_data until then.
--
-- Timing
--   - send_bit drives bit_data and bit_valid when called (call it after an
--     edge, e.g. C_MARGIN after it) and returns at the edge that transfers the
--     bit, with bit_valid already released ('0' scheduled in that delta).
--   - A send_bit called again in the same delta overrides the release, so
--     consecutive calls give back-to-back bits with no gap.
--   - bit_ready is read in the edge's own delta, i.e. the value the DUT sees at
--     that edge.
--
-- Timeout
--   - send_bit waits at most config.max_wait_cycles edges for bit_ready
--     (0 = wait forever). On timeout it raises config.max_wait_cycles_severity,
--     releases bit_valid and returns: the bit is not transferred.
--
-- Usage
--   Signals are passed as parameters. Keep a one-line local wrapper in the
--   sequencer process:
--     procedure send_bit(constant bit_value : std_logic) is
--     begin
--         send_bit(bit_value, clk, bit_data, bit_valid, bit_ready);
--     end procedure;
--   Logging uses config.id_for_bfm (ID_BFM): disable_log_msg(ID_BFM) hides it.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;

library uvvm_util;
context uvvm_util.uvvm_util_context;

package bit_stream_bfm_pkg is

    type t_bit_stream_bfm_config is record
        max_wait_cycles          : natural;        -- edges to wait for bit_ready, 0 = no limit
        max_wait_cycles_severity : t_alert_level;  -- alert level on timeout
        id_for_bfm               : t_msg_id;       -- log message ID for each transfer
    end record;

    constant C_BIT_STREAM_BFM_CONFIG_DEFAULT : t_bit_stream_bfm_config := (
        max_wait_cycles          => 10_000, -- above the longest symbol x clk_en gap in the configs
        max_wait_cycles_severity => ERROR,
        id_for_bfm               => ID_BFM
    );

    -- send one bit: drive it, wait for the transfer edge, release bit_valid
    procedure send_bit(
        constant bit_value    : in  std_logic;
        signal   clk          : in  std_logic;
        signal   bit_data     : out std_logic;
        signal   bit_valid    : out std_logic;
        signal   bit_ready    : in  std_logic;
        constant msg          : in  string                  := "";
        constant scope        : in  string                  := C_TB_SCOPE_DEFAULT;
        constant msg_id_panel : in  t_msg_id_panel          := shared_msg_id_panel;
        constant config       : in  t_bit_stream_bfm_config := C_BIT_STREAM_BFM_CONFIG_DEFAULT);

    -- send bits left to right, back to back
    procedure send_bits(
        constant bits         : in  std_logic_vector;
        signal   clk          : in  std_logic;
        signal   bit_data     : out std_logic;
        signal   bit_valid    : out std_logic;
        signal   bit_ready    : in  std_logic;
        constant msg          : in  string                  := "";
        constant scope        : in  string                  := C_TB_SCOPE_DEFAULT;
        constant msg_id_panel : in  t_msg_id_panel          := shared_msg_id_panel;
        constant config       : in  t_bit_stream_bfm_config := C_BIT_STREAM_BFM_CONFIG_DEFAULT);

    -- input back to idle: no transfer on the next edge
    procedure release_bit_stream(signal bit_valid : out std_logic);

end package bit_stream_bfm_pkg;

package body bit_stream_bfm_pkg is

    procedure send_bit(
        constant bit_value    : in  std_logic;
        signal   clk          : in  std_logic;
        signal   bit_data     : out std_logic;
        signal   bit_valid    : out std_logic;
        signal   bit_ready    : in  std_logic;
        constant msg          : in  string                  := "";
        constant scope        : in  string                  := C_TB_SCOPE_DEFAULT;
        constant msg_id_panel : in  t_msg_id_panel          := shared_msg_id_panel;
        constant config       : in  t_bit_stream_bfm_config := C_BIT_STREAM_BFM_CONFIG_DEFAULT) is
        constant C_PROC_CALL : string  := "send_bit(" & to_string(bit_value) & ")";
        variable v_cycles    : natural := 0;
    begin
        if bit_value /= '0' and bit_value /= '1' then
            alert(TB_ERROR, C_PROC_CALL & " => bit_value must be '0' or '1'. " & add_msg_delimiter(msg), scope);
        end if;

        bit_data  <= bit_value;
        bit_valid <= '1';

        loop
            wait until rising_edge(clk);
            v_cycles := v_cycles + 1;

            if is_x(bit_ready) then
                alert(ERROR, C_PROC_CALL & " => bit_ready is " & to_string(bit_ready) & " at a transfer edge. " &
                      add_msg_delimiter(msg), scope);
            end if;

            if bit_ready = '1' then
                log(config.id_for_bfm, C_PROC_CALL & " => transferred after " & to_string(v_cycles) & " edge(s). " &
                    add_msg_delimiter(msg), scope, msg_id_panel);
                exit;
            end if;

            if config.max_wait_cycles > 0 and v_cycles >= config.max_wait_cycles then
                alert(config.max_wait_cycles_severity, C_PROC_CALL & " => bit_ready not seen within " &
                      to_string(config.max_wait_cycles) & " edges: bit dropped. " & add_msg_delimiter(msg), scope);
                exit;
            end if;
        end loop;

        bit_valid <= '0';
    end procedure;

    procedure send_bits(
        constant bits         : in  std_logic_vector;
        signal   clk          : in  std_logic;
        signal   bit_data     : out std_logic;
        signal   bit_valid    : out std_logic;
        signal   bit_ready    : in  std_logic;
        constant msg          : in  string                  := "";
        constant scope        : in  string                  := C_TB_SCOPE_DEFAULT;
        constant msg_id_panel : in  t_msg_id_panel          := shared_msg_id_panel;
        constant config       : in  t_bit_stream_bfm_config := C_BIT_STREAM_BFM_CONFIG_DEFAULT) is
    begin
        for i in bits'range loop
            send_bit(bits(i), clk, bit_data, bit_valid, bit_ready, msg, scope, msg_id_panel, config);
        end loop;
    end procedure;

    procedure release_bit_stream(signal bit_valid : out std_logic) is
    begin
        bit_valid <= '0';
    end procedure;

end package body bit_stream_bfm_pkg;
