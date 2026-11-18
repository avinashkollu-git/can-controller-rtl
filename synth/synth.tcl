# synth.tcl : Yosys, RTL -> SKY130 HD netlist (pattern from rv32-synth-sta).
#   env: RTL (file list), LIB (liberty), OUT (output dir)
yosys -import
set lib $::env(LIB)
set out $::env(OUT)
set dont_use {-dont_use *lpflow* -dont_use *probe* -dont_use *clkdlybuf* -dont_use *dlygate*}

foreach f $::env(RTL) { read_verilog -sv $f }
# library cells as black boxes, so check knows their pin directions
read_liberty -lib $lib
hierarchy -check -top can_ctrl
synth -top can_ctrl -flatten
dfflegalize -cell {$_DFF_P_} 01 -cell {$_DFF_N_} 01 -cell {$_DFF_PN0_} 01 -cell {$_DFF_PN1_} 01
eval dfflibmap -liberty $lib $dont_use
eval abc -D 10000 -liberty $lib $dont_use
opt_clean -purge
hilomap -singleton -hicell sky130_fd_sc_hd__conb_1 HI -locell sky130_fd_sc_hd__conb_1 LO
setundef -zero
splitnets
opt_clean -purge
tee -o $out/area.rpt stat -liberty $lib
check -assert
write_verilog -noattr -noexpr -nohex -nodec $out/netlist.v
