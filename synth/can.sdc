# can.sdc : one clock on pclk, ideal (no clock tree). Units ns/pF from the liberty.
set CLK_PERIOD 10.0
# synth/sta.tcl overrides the period (env FMAX_PERIOD) to search for Fmax
if {[info exists ::env(FMAX_PERIOD)]} { set CLK_PERIOD $::env(FMAX_PERIOD) }
create_clock -name clk -period $CLK_PERIOD [get_ports pclk]
set data_inputs [lsearch -inline -all -not -exact [all_inputs] [get_ports pclk]]
set_clock_uncertainty 0.25 [get_clocks clk]
set_clock_transition 0.15 [get_clocks clk]
# APB inputs arrive 30% into the cycle, outputs are needed 30% early
set_input_delay [expr 0.3 * $CLK_PERIOD] -clock clk $data_inputs
set_output_delay [expr 0.3 * $CLK_PERIOD] -clock clk [all_outputs]
set_driving_cell -lib_cell sky130_fd_sc_hd__buf_2 -pin X $data_inputs
set_load 0.01 [all_outputs]
# presetn and can_rx are asynchronous (async reset; can_rx has a 2-flop synchroniser)
set_false_path -from [get_ports {presetn can_rx}]
