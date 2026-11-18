# can-controller-rtl : CAN 2.0A controller (APB), UVM testbench on Verilator,
# C driver co-simulation, Yosys/OpenSTA synthesis.
#
#   make lint      verilator --lint-only -Wall on the RTL
#   make vectors   regenerate vectors/frames.txt from the golden Python model
#   make sim       one test (TEST=..., SEED=..., N=...), with waves
#   make regress   every test x SEEDS seeds (default 5); results/regress/{summary,coverage}.md
#   make driver    C driver (driver/) running on the RTL through Verilator
#   make synth     Yosys: generic cell count + SKY130 netlist; OpenSTA Fmax if available
#   make clean
#
# CPU: everything runs at low priority, one job at a time (-j1, --build-jobs 1),
# with COOL seconds of pause after each heavy build.

VERILATOR ?= verilator
PYTHON    ?= python3
YOSYS     ?= yosys
STA       ?= $(firstword $(wildcard $(HOME)/tools/OpenSTA/build2/sta) $(shell command -v sta))
NICE      ?= nice -n 10
COOL      ?= 5
TEST      ?= frames_test
SEED      ?= 1
SEEDS     ?= 5
N         ?= 40

UVM_HOME   := third_party/uvm/src
UVM_REPO   ?= https://github.com/chipsalliance/uvm-verilator
UVM_COMMIT := 5a37baacfed0722b523b05decc9b94fe3e9efbe4   # branch uvm-2017-1.0-vlt

RTL := rtl/can_btl.sv rtl/can_core.sv rtl/can_ctrl.sv
SVA := sva/can_sva.sv
TB  := tb/can_ifs.sv tb/can_pkg.sv tb/tb_top.sv
TB_INC := $(wildcard tb/*.svh)

# Full UVM with its DPI (needs --vpi; on macOS a malloc.h shim), as in amba-uvm-vip.
VFLAGS := --binary --timing --vpi --assert -j 1 --build-jobs 1 \
          --coverage-line --coverage-user --trace \
          --timescale 1ns/1ps -Wno-fatal -Wno-lint -Wno-style -Itb --top-module tb_top \
          +incdir+$(UVM_HOME) $(UVM_HOME)/uvm_pkg.sv $(UVM_HOME)/dpi/uvm_dpi.cc
ifeq ($(shell uname),Darwin)
VFLAGS += -CFLAGS -I$(CURDIR)/tools/shim
endif

BIN := build/Vtb
cool = @if [ "$(COOL)" != 0 ]; then echo "cooling $(COOL)s"; sleep $(COOL); fi

.PHONY: lint vectors sim regress driver synth uvm clean distclean

uvm: $(UVM_HOME)/uvm_pkg.sv
$(UVM_HOME)/uvm_pkg.sv:
	git clone -q $(UVM_REPO) third_party/uvm
	git -C third_party/uvm checkout -q $(UVM_COMMIT)

lint:
	$(VERILATOR) --lint-only -Wall $(RTL) --top-module can_ctrl
	@echo "lint: clean"

vectors:
	$(PYTHON) model/can_ref.py
	$(PYTHON) scripts/gen_vectors.py

$(BIN): $(RTL) $(SVA) $(TB) $(TB_INC) | uvm
	@mkdir -p build
	$(NICE) $(VERILATOR) $(VFLAGS) $(RTL) $(SVA) $(TB) -Mdir build -o Vtb > build/build.log 2>&1 \
	  || (tail -30 build/build.log; false)
	$(cool)

sim: $(BIN)
	$(NICE) $(PYTHON) scripts/regress.py --bin $(BIN) --tests $(TEST) --seeds 1 --first-seed $(SEED) \
	  --n $(N) --out results/sim --waves

regress: $(BIN)
	$(NICE) $(PYTHON) scripts/regress.py --bin $(BIN) --seeds $(SEEDS) --n $(N) --out results/regress

# ---- C driver on the RTL: C++ harness -> register shim -> APB pins ----
DRV_BIN := build/drv/Vcan_sys
$(DRV_BIN): $(RTL) driver/can_drv.c driver/can_drv.h driver/can_hal.h sim/can_sys.sv sim/drv_main.cpp sim/drv_test.c
	@mkdir -p build/drv
	$(NICE) $(VERILATOR) --cc --exe --build -j 1 --build-jobs 1 -Wno-fatal --top-module can_sys \
	  -CFLAGS "-I$(CURDIR)/driver -O1" -Mdir build/drv -o Vcan_sys \
	  $(RTL) sim/can_sys.sv sim/drv_main.cpp sim/drv_test.c driver/can_drv.c > build/drv/build.log 2>&1 \
	  || (tail -30 build/drv/build.log; false)
	$(cool)

driver: $(DRV_BIN)
	@mkdir -p results
	$(NICE) $(DRV_BIN) vectors/frames.txt | tee results/driver.log
	@grep -q "^DRIVER: PASS" results/driver.log

# ---- synthesis ----
LIB     := third_party/sky130_fd_sc_hd__tt_025C_1v80.lib
LIB_URL := https://raw.githubusercontent.com/The-OpenROAD-Project/OpenROAD-flow-scripts/2ba1223c8e39f7a16950ed0272ca8faa391cba84/flow/platforms/sky130hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib

$(LIB):
	@mkdir -p third_party
	curl -fsSL -o $@ $(LIB_URL)

synth: $(RTL) synth/synth.tcl synth/sta.tcl synth/can.sdc $(LIB)
	@mkdir -p build/synth
	$(NICE) $(YOSYS) -q -l build/synth/generic.log -p "read_verilog -sv $(RTL); synth -top can_ctrl -flatten; tee -o build/synth/generic_stat.rpt stat"
	LIB=$(LIB) OUT=build/synth RTL="$(RTL)" $(NICE) $(YOSYS) -q -l build/synth/sky130.log -c synth/synth.tcl
	@if [ -n "$(STA)" ]; then LIB=$(LIB) OUT=build/synth SDC=synth/can.sdc \
	  $(NICE) $(STA) -no_splash -exit synth/sta.tcl > build/synth/sta.log 2>&1 || (tail -20 build/synth/sta.log; false); \
	  else echo "no OpenSTA: skipping timing"; fi
	@$(PYTHON) scripts/synth_summary.py build/synth | tee build/synth/summary.md
	$(cool)

clean:
	rm -rf build results

distclean: clean
	rm -rf third_party
