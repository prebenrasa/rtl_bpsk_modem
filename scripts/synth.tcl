# -----------------------------------------------------------------------------
# Synthesis (Vivado non-project mode)
#   Usage: vivado -mode batch -source scripts/synth.tcl -tclargs <TOP> <PART> <SOURCES_F>
#   SOURCES_F lists the VHDL sources, one path per line (the Makefile writes it from mk/sources.mk).
#   Run from the output folder build/vivado/<TOP>/ (the Makefile does this for you):
#   checkpoints, reports, logs and Vivado's own files (.Xil/) are written there.
# -----------------------------------------------------------------------------
set root [file normalize [file join [file dirname [info script]] ..]]
if {[string match "* *" $root]} { error "Vivado breaks on spaces in absolute paths: move the project out of '$root'" }
set top  [expr {[llength $argv] > 0 ? [lindex $argv 0] : "top"}]
set part [expr {[llength $argv] > 1 ? [lindex $argv 1] : "xc7a35tcpg236-1"}]
set rpt  reports
file mkdir $rpt

puts "== Synthesis: top=$top part=$part"

# Sources: exactly the files listed in SOURCES_F (testbenches are NOT read)
if {[llength $argv] < 3} { error "No sources file given - run synthesis with make synth" }
set fh [open [lindex $argv 2]]
set srcs [split [string trim [read $fh]] "\n"]
close $fh
if {[llength $srcs] == 0} { error "No VHDL files listed in [lindex $argv 2]" }
read_vhdl -vhdl2008 $srcs

# Constraints: constraints/clocks.xdc (shared by all tops), then constraints/<TOP>.xdc if it exists
set clocks_xdc [file join $root constraints clocks.xdc]
if {[file exists $clocks_xdc]} {
    read_xdc $clocks_xdc
} else {
    puts "WARNING: no constraints file $clocks_xdc - synthesising without clock constraints"
}
set xdc [file join $root constraints "$top.xdc"]
if {[file exists $xdc]} { read_xdc $xdc }

synth_design -top $top -part $part

write_checkpoint -force post_synth.dcp
report_utilization    -file [file join $rpt post_synth_utilization.rpt]
report_utilization -hierarchical -file [file join $rpt post_synth_utilization_hier.rpt]
report_timing_summary -file [file join $rpt post_synth_timing.rpt]
report_methodology    -file [file join $rpt post_synth_methodology.rpt]

puts "== Synthesis done. Reports in [file normalize $rpt]"
