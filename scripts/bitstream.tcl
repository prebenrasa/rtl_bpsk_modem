# -----------------------------------------------------------------------------
# Bitstream generation (optional - no board needed to run this)
#   Usage: vivado -mode batch -source scripts/bitstream.tcl
#   Needs build/post_route.dcp from impl.tcl.
# -----------------------------------------------------------------------------
set root [file normalize [file join [file dirname [info script]] ..]]
cd $root   ;# use relative paths below: Vivado breaks on spaces in absolute paths
set dcp  [file join build post_route.dcp]
if {![file exists $dcp]} { error "No $dcp - run implementation first (make impl)" }
open_checkpoint $dcp

set top [get_property TOP [current_design]]
write_bitstream -force [file join build "$top.bit"]
puts "== Bitstream written: build/$top.bit"
