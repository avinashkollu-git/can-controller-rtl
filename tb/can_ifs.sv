// can_ifs.sv : pin bundles.
//   apb_if: same as amba-uvm-vip. Drivers change signals 1 ns after the rising
//   edge, monitors sample on the falling edge (no race with the DUT flops).
//   can_tb_if: the bus wire, fault-injection controls and DUT event probes.
`timescale 1ns / 1ps

interface apb_if (input logic clk, input logic rst_n);
    logic        psel, penable, pwrite, pready, pslverr;
    logic [11:0] paddr;
    logic [31:0] pwdata, prdata;
endinterface

interface can_tb_if (input logic clk, input logic rst_n);
    logic        bus;              // the wire, after bus noise
    logic [2:0]  irq;
    // injector controls (set by the test)
    int unsigned bit_clks = 16;    // clocks per bit, for bit-window counting
    logic        inj_en = 1'b0;    // flip node inj_node's RX for bit inj_bit of every frame
    int unsigned inj_node = 0, inj_bit = 0;
    int unsigned noise_div = 0;    // bus noise: flip each bit with probability 1/noise_div
    // injector outputs
    logic [2:0]  node_flip;
    logic        bus_flip;
    int unsigned injected = 0, sofs = 0;
    // DUT probes
    logic [2:0]  err, arb_lost;
    logic [4:0]  err_type [3];
endinterface
