# -----------------------------------------------------------------------------
# Synthesis (Vivado non-project mode)
#   Usage: vivado -mode batch -source scripts/synth.tcl -tclargs <TOP> [PART]
#   Run from the build/ directory (the Makefile does this for you).
# -----------------------------------------------------------------------------
set root [file normalize [file join [file dirname [info script]] ..]]
cd $root   ;# use relative paths below: Vivado breaks on spaces in absolute paths
set top  [expr {[llength $argv] > 0 ? [lindex $argv 0] : "top"}]
set part [expr {[llength $argv] > 1 ? [lindex $argv 1] : "xc7a35tcpg236-1"}]
set rpt  [file join build reports]
file mkdir $rpt

puts "== Synthesis: top=$top part=$part"

# Sources: every .vhd in src/ (testbenches in tb/ are NOT read)
set srcs [glob -nocomplain [file join src *.vhd] [file join ip rtl_nco src *.vhd]]
if {[llength $srcs] == 0} { error "No VHDL files found in src/" }
read_vhdl -vhdl2008 $srcs

# Constraints: constraints/<TOP>.xdc if it exists
set xdc [file join constraints "$top.xdc"]
if {[file exists $xdc]} {
    read_xdc $xdc
} else {
    puts "WARNING: no constraints file $xdc - synthesising without pin/clock constraints"
}

synth_design -top $top -part $part

write_checkpoint -force [file join build post_synth.dcp]
report_utilization    -file [file join $rpt post_synth_utilization.rpt]
report_utilization -hierarchical -file [file join $rpt post_synth_utilization_hier.rpt]
report_timing_summary -file [file join $rpt post_synth_timing.rpt]
report_methodology    -file [file join $rpt post_synth_methodology.rpt]

puts "== Synthesis done. Reports in $rpt"
