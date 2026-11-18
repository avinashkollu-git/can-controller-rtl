// can_pkg.sv : UVM environment for the CAN controller.
`timescale 1ns / 1ps

package can_pkg;
    import uvm_pkg::*;
    `include "uvm_macros.svh"

    `include "apb_agent.svh"
    `include "can_frame.svh"
    `include "can_monitor.svh"
    `include "scoreboard.svh"
    `include "can_node.svh"
    `include "tests.svh"
endpackage
