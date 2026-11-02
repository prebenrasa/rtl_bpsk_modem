# -----------------------------------------------------------------------------
# One implementation run for the resource figures: synthesis with generic overrides, then opt/place/route
# (Vivado non-project mode). Started by scripts/fpga_resources.py, one run per design variant.
#   Usage: vivado -mode batch -source fpga_resources.tcl -tclargs <TOP> <PART> <SOURCES_F> <XDC> [NAME=VALUE ...]
#   Run from the variant's output folder: reports go to utilization.rpt, timing.rpt there.
# -----------------------------------------------------------------------------
lassign $argv top part sources_f xdc
set generics [lrange $argv 4 end]

set fh [open $sources_f]
read_vhdl -vhdl2008 [split [string trim [read $fh]] "\n"]
close $fh
read_xdc $xdc

set generic_args {}
foreach g $generics { lappend generic_args -generic $g }
synth_design -top $top -part $part {*}$generic_args
report_utilization -file post_synth_utilization.rpt

opt_design
place_design
route_design
report_utilization    -file utilization.rpt
report_timing_summary -file timing.rpt
puts "== done: $top $generics"
