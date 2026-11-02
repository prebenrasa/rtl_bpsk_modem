create_clock -period 10.000 -name sys_clk [get_ports clk]

# reset_n is asynchronous to clk: no timing from the pin.
set_false_path -from [get_ports reset_n]
