# -----------------------------------------------------------------------------
# Bitstream generation (optional - no board needed to run this)
#   Usage: vivado -mode batch -source scripts/bitstream.tcl
#   Run from the output folder build/vivado/<TOP>/; needs post_route.dcp from impl.tcl there.
# -----------------------------------------------------------------------------
set dcp post_route.dcp
if {![file exists $dcp]} { error "No $dcp in [pwd] - run implementation of this top first (make impl TOP=...)" }
open_checkpoint $dcp

set top [get_property TOP [current_design]]
write_bitstream -force "$top.bit"
puts "== Bitstream written: [file normalize $top.bit]"
