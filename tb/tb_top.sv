// tb_top.sv : three CAN controllers on one wired-AND bus, a fault injector,
// the SVA checkers, and the UVM test.
//
//   bus     = tx0 & tx1 & tx2, XOR bus_flip     (bus_flip: noise seen by everyone)
//   rx[i]   = bus XOR node_flip[i]              (node_flip: one node sees a wrong bit)
`timescale 1ns / 1ps

module tb_top;
    import uvm_pkg::*;
    import can_pkg::*;

    localparam int N = 3;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #5 clk = ~clk;
    initial begin
        repeat (5) @(posedge clk);
        rst_n <= 1'b1;
    end

    apb_if    apb [N] (.clk(clk), .rst_n(rst_n));
    can_tb_if cif (.clk(clk), .rst_n(rst_n));

    logic [N-1:0] tx, rx, irq;
    assign cif.bus = (&tx) ^ cif.bus_flip;
    assign rx      = {N{cif.bus}} ^ cif.node_flip;
    assign cif.irq = irq;

    for (genvar i = 0; i < N; i++) begin : g_node
        can_ctrl u_dut (
            .pclk(clk), .presetn(rst_n),
            .psel(apb[i].psel), .penable(apb[i].penable), .pwrite(apb[i].pwrite),
            .paddr(apb[i].paddr), .pwdata(apb[i].pwdata), .prdata(apb[i].prdata),
            .pready(apb[i].pready), .pslverr(apb[i].pslverr),
            .irq(irq[i]), .can_rx(rx[i]), .can_tx(tx[i]));
        // error pulses for the scoreboard's error counts and coverage
        assign cif.err[i]      = u_dut.u_core.err;
        assign cif.err_type[i] = u_dut.u_core.err_type;
        assign cif.arb_lost[i] = u_dut.u_core.arb_lost;
    end

    bind can_core can_sva u_sva (.*);

    // ---------------- fault injector ----------------
    // Bit windows are counted from the SOF edge on the bus. An SOF is a falling
    // edge after at least 10 recessive bit times (idle, or end of IFS).
    int unsigned rcnt, c;
    logic        in_frame;
    always @(posedge clk) begin
        if (!rst_n) begin
            rcnt <= 0; in_frame <= 1'b0; c <= 0;
            cif.node_flip <= '0; cif.bus_flip <= 1'b0;
        end else begin
            rcnt <= cif.bus ? rcnt + 1 : 0;
            if (!cif.bus && rcnt >= 10 * cif.bit_clks) begin
                in_frame <= 1'b1;
                c <= 1;
                cif.sofs <= cif.sofs + 1;
            end else if (in_frame) begin
                c <= c + 1;
                if (c >= 200 * cif.bit_clks) in_frame <= 1'b0;
            end
            // per-node flip of exactly one bit cell, at bit inj_bit of the frame
            cif.node_flip <= '0;
            if (cif.inj_en && in_frame && c >= cif.inj_bit * cif.bit_clks - 1
                && c < (cif.inj_bit + 1) * cif.bit_clks - 1) begin
                cif.node_flip[cif.inj_node] <= 1'b1;
                if (c == cif.inj_bit * cif.bit_clks - 1) cif.injected <= cif.injected + 1;
            end
            // random bus noise: each bit cell flipped with probability 1/noise_div
            if (cif.noise_div != 0 && in_frame && c % cif.bit_clks == cif.bit_clks - 1)
                cif.bus_flip <= ($urandom % cif.noise_div) == 0;
            else if (cif.noise_div == 0 || !in_frame)
                cif.bus_flip <= 1'b0;
        end
    end

    initial begin
        if ($test$plusargs("waves")) begin
            $dumpfile("waves.vcd");
            $dumpvars(0, tb_top);
        end
        uvm_config_db #(virtual apb_if)::set(null, "*", "vif0", apb[0]);
        uvm_config_db #(virtual apb_if)::set(null, "*", "vif1", apb[1]);
        uvm_config_db #(virtual apb_if)::set(null, "*", "vif2", apb[2]);
        uvm_config_db #(virtual can_tb_if)::set(null, "*", "cif", cif);
        run_test("frames_test");
    end
endmodule
