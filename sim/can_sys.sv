// can_sys.sv : two can_ctrl nodes on one wired-AND CAN bus, for the C driver
// co-simulation. One APB port; paddr[12] selects the node.
module can_sys (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        psel,
    input  logic        penable,
    input  logic        pwrite,
    input  logic [12:0] paddr,
    input  logic [31:0] pwdata,
    output logic [31:0] prdata
);
    logic [1:0]  tx, irq, pready, pslverr;
    logic [31:0] rd [2];
    wire bus = &tx;

    for (genvar i = 0; i < 2; i++) begin : g_node
        can_ctrl u_can (
            .pclk(clk), .presetn(rst_n),
            .psel(psel && paddr[12] == 1'(i)), .penable(penable), .pwrite(pwrite),
            .paddr(paddr[11:0]), .pwdata(pwdata), .prdata(rd[i]),
            .pready(pready[i]), .pslverr(pslverr[i]), .irq(irq[i]),
            .can_rx(bus), .can_tx(tx[i]));
    end
    assign prdata = rd[0] | rd[1];   // unselected node returns 0
endmodule
