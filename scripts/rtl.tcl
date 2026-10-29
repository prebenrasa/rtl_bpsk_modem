# -----------------------------------------------------------------------------
# Elaborated (RTL) design in the Vivado GUI - for schematic screenshots
#   Usage: vivado -mode gui -source scripts/rtl.tcl -tclargs <TOP> [PART]
# -----------------------------------------------------------------------------
set root [file normalize [file join [file dirname [info script]] ..]]
cd $root   ;# use relative paths below: Vivado breaks on spaces in absolute paths
set top  [expr {[llength $argv] > 0 ? [lindex $argv 0] : "top"}]
set part [expr {[llength $argv] > 1 ? [lindex $argv 1] : "xc7a35tcpg236-1"}]

read_vhdl -vhdl2008 [glob [file join src *.vhd] [file join ip rtl_nco src *.vhd]]
set xdc [file join constraints "$top.xdc"]
if {[file exists $xdc]} { read_xdc $xdc }

synth_design -rtl -top $top -part $part -name rtl_1
show_schematic [concat [get_cells] [get_ports]]
