# -----------------------------------------------------------------------------
# Implementation: opt -> place -> route (Vivado non-project mode)
#   Usage: vivado -mode batch -source scripts/impl.tcl
#   Needs build/post_synth.dcp from synth.tcl.
# -----------------------------------------------------------------------------
set root [file normalize [file join [file dirname [info script]] ..]]
cd $root   ;# use relative paths below: Vivado breaks on spaces in absolute paths
set rpt  [file join build reports]
file mkdir $rpt

set dcp [file join build post_synth.dcp]
if {![file exists $dcp]} { error "No $dcp - run synthesis first (make synth)" }
open_checkpoint $dcp

opt_design
place_design
write_checkpoint -force [file join build post_place.dcp]
report_utilization -file [file join $rpt post_place_utilization.rpt]

route_design
write_checkpoint -force [file join build post_route.dcp]

report_utilization    -file [file join $rpt post_route_utilization.rpt]
report_timing_summary -file [file join $rpt post_route_timing.rpt]
report_power          -file [file join $rpt post_route_power.rpt]
report_drc            -file [file join $rpt post_route_drc.rpt]
report_io             -file [file join $rpt post_route_io.rpt]
report_route_status   -file [file join $rpt post_route_status.rpt]

puts "== Implementation done. Reports in $rpt"
