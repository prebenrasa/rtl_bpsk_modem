# -----------------------------------------------------------------------------
# Elaborated (RTL) design in the Vivado GUI - for schematic screenshots
#   Usage: vivado -mode gui -source scripts/rtl.tcl -tclargs <TOP> <PART> <SOURCES_F>
#   SOURCES_F lists the VHDL sources, one path per line (the Makefile writes it from mk/sources.mk).
#   Run from the output folder build/vivado/<TOP>/ (the Makefile does this for you).
# -----------------------------------------------------------------------------
set root [file normalize [file join [file dirname [info script]] ..]]
if {[string match "* *" $root]} { error "Vivado breaks on spaces in absolute paths: move the project out of '$root'" }
set top  [expr {[llength $argv] > 0 ? [lindex $argv 0] : "top"}]
set part [expr {[llength $argv] > 1 ? [lindex $argv 1] : "xc7a35tcpg236-1"}]

if {[llength $argv] < 3} { error "No sources file given - open the schematic with make rtl" }
set fh [open [lindex $argv 2]]
read_vhdl -vhdl2008 [split [string trim [read $fh]] "\n"]
close $fh
foreach xdc [list [file join $root constraints clocks.xdc] [file join $root constraints "$top.xdc"]] {
    if {[file exists $xdc]} { read_xdc $xdc }
}

synth_design -rtl -top $top -part $part -name rtl_1
show_schematic [concat [get_cells] [get_ports]]
