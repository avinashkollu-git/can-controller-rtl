// can_node.svh : register-level API for one controller, built on APB
// sequences (the same steps the C driver does: driver/can_drv.c).

class can_node;
    int               idx;
    apb_sequencer     sqr;
    can_scoreboard    scb;
    virtual can_tb_if vif;

    function new(int idx, apb_sequencer sqr, can_scoreboard scb, virtual can_tb_if vif);
        this.idx = idx; this.sqr = sqr; this.scb = scb; this.vif = vif;
    endfunction

    task wr(bit [11:0] a, bit [31:0] d);
        apb_rw_seq s = apb_rw_seq::type_id::create("wr");
        s.write = 1; s.addr = a; s.data = d;
        s.start(sqr);
    endtask

    task rd(bit [11:0] a, output bit [31:0] d);
        apb_rw_seq s = apb_rw_seq::type_id::create("rd");
        s.write = 0; s.addr = a;
        s.start(sqr);
        d = s.data;
    endtask

    // read and compare (register checks)
    task check(bit [11:0] a, bit [31:0] exp, string what);
        bit [31:0] d;
        rd(a, d);
        if (d !== exp) `uvm_error("REG", $sformatf("node %0d %s: read %08h, expected %08h", idx, what, d, exp))
        else scb.bin("reg", "check_ok");
    endtask

    task init(bit [31:0] btr);
        wr(R_CTRL, 1);
        wr(R_BTR, btr);
        wr(R_IRQ, 32'hFF);
        wr(R_ERRFLAGS, 32'h1F);
        wr(R_IRQ_EN, 32'hFF);
        wr(R_CTRL, 0);
    endtask

    task load(can_frame f);
        wr(R_TXID, {f.rtr, f.id});
        wr(R_TXDLC, f.dlc);
        wr(R_TXD0, {f.data[3], f.data[2], f.data[1], f.data[0]});
        wr(R_TXD1, {f.data[7], f.data[6], f.data[5], f.data[4]});
    endtask

    task send(can_frame f);
        scb.expect_tx(idx, f);
        load(f);
        wr(R_CMD, 1);
    endtask

    // poll IRQ until any bit of mask is set; clears those bits.
    // No forever/break here: with Verilator 5.050 the value rd() wrote into d
    // read back as 0 after the break (README bug log).
    task wait_irq(bit [7:0] mask, output bit [7:0] got, input int unsigned max_clks = 400000);
        bit [31:0] d;
        int unsigned t = 0;
        rd(R_IRQ, d);
        while ((d[7:0] & mask) == 0) begin
            if (t > max_clks)
                `uvm_fatal("NODE", $sformatf("node %0d: no IRQ %02h after %0d clocks (IRQ=%02h)", idx, mask, t, d[7:0]))
            repeat (16) @(posedge vif.clk);
            t += 19;
            rd(R_IRQ, d);
        end
        got = d[7:0];
        wr(R_IRQ, {24'd0, d[7:0] & mask});
    endtask

    task wait_tx_done();
        bit [7:0] g;
        wait_irq(I_TX_DONE, g);
    endtask

    task rx_count(output int n);
        bit [31:0] d;
        rd(R_STATUS, d);
        n = d[10:8];
    endtask

    task read_rx();
        bit [31:0] d;
        can_frame f = can_frame::type_id::create("rx");
        rd(R_RXID, d);  f.id = d[10:0]; f.rtr = d[11];
        rd(R_RXDLC, d); f.dlc = d[3:0];
        rd(R_RXD0, d);  {f.data[3], f.data[2], f.data[1], f.data[0]} = d;
        rd(R_RXD1, d);  {f.data[7], f.data[6], f.data[5], f.data[4]} = d;
        wr(R_CMD, 4);
        scb.rx(idx, f);
    endtask

    task drain();
        int n;
        rx_count(n);
        repeat (n) read_rx();
    endtask

    task errcnt(output int tec, output int rec);
        bit [31:0] d;
        rd(R_ERRCNT, d);
        tec = d[8:0]; rec = d[23:16];
    endtask
endclass
