# -----------------------------------------------------------------------------
# Implementation: opt -> place -> route (Vivado non-project mode)
#   Usage: vivado -mode batch -source scripts/impl.tcl
#   Run from the output folder build/vivado/<TOP>/; needs post_synth.dcp from synth.tcl there.
# -----------------------------------------------------------------------------
set rpt  reports
file mkdir $rpt

set dcp post_synth.dcp
if {![file exists $dcp]} { error "No $dcp in [pwd] - run synthesis of this top first (make synth TOP=...)" }
open_checkpoint $dcp

opt_design
place_design
write_checkpoint -force post_place.dcp
report_utilization -file [file join $rpt post_place_utilization.rpt]

route_design
write_checkpoint -force post_route.dcp

report_utilization    -file [file join $rpt post_route_utilization.rpt]
report_timing_summary -file [file join $rpt post_route_timing.rpt]
report_power          -file [file join $rpt post_route_power.rpt]
report_drc            -file [file join $rpt post_route_drc.rpt]
report_io             -file [file join $rpt post_route_io.rpt]
report_route_status   -file [file join $rpt post_route_status.rpt]

puts "== Implementation done. Reports in [file normalize $rpt]"
