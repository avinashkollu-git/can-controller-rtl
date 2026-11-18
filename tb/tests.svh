// tests.svh : env and tests.
//
//   regs_test   reset values, read/write, W1C, BTR and TX-buffer write locks, TX abort
//   frames_test N golden frames from random nodes; every receiver reads each one;
//               some receivers let their FIFO fill (and one overrun)
//   arb_test    2 or 3 nodes request in the same bit: bus order must be by ID
//               (then RTR), losers report ARB_LOST and send later
//   rxerr_test  flip one bit at one node (receiver: predicted stuff/CRC/form error;
//               transmitter: bit error); exact TEC/REC model after every frame
//   busoff_test ACK errors -> error-passive (TEC stops at 128), then bit errors
//               -> bus-off -> 128x11 recessive bits -> recovered, frame delivered
//   noise_test  random bit flips on the bus; every frame still delivered once

class can_env extends uvm_env;
    `uvm_component_utils(can_env)
    apb_agent      apb [3];
    can_monitor    mon;
    can_scoreboard scb;
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction
    function void build_phase(uvm_phase phase);
        virtual apb_if v;
        virtual can_tb_if c;
        for (int i = 0; i < 3; i++) begin
            apb[i] = apb_agent::type_id::create($sformatf("apb%0d", i), this);
        end
        mon = can_monitor::type_id::create("mon", this);
        scb = can_scoreboard::type_id::create("scb", this);
        if (!uvm_config_db #(virtual can_tb_if)::get(this, "", "cif", c)) `uvm_fatal("ENV", "cif not set")
        mon.vif = c;
    endfunction
    function void connect_phase(uvm_phase phase);
        for (int i = 0; i < 3; i++) begin
            virtual apb_if v;
            if (!uvm_config_db #(virtual apb_if)::get(this, "", $sformatf("vif%0d", i), v))
                `uvm_fatal("ENV", "apb vif not set")
            apb[i].drv.vif = v;
        end
        mon.ap.connect(scb.imp);
    endfunction
endclass

class base_test extends uvm_test;
    `uvm_component_utils(base_test)
    can_env           env;
    can_node          node [3];
    virtual can_tb_if vif;
    int unsigned      n = 40;
    bit [31:0]        btr;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction
    function void build_phase(uvm_phase phase);
        string vec = "vectors/frames.txt";
        env = can_env::type_id::create("env", this);
        void'($value$plusargs("N=%d", n));
        void'($value$plusargs("VEC=%s", vec));
        vectors::load(vec);
        if (!uvm_config_db #(virtual can_tb_if)::get(this, "", "cif", vif)) `uvm_fatal("TEST", "cif not set")
        uvm_root::get().set_timeout(200ms, 0);
    endfunction

    // random legal bit timing per seed; the same for all nodes
    function void pick_btr();
        int tq = $urandom_range(2, 4), prop = $urandom_range(2, 4), ph1 = $urandom_range(2, 4),
            ph2 = $urandom_range(2, 4), sjw = $urandom_range(1, 2);
        int bit_clks = tq * (1 + prop + ph1 + ph2);
        btr = {10'd0, 2'(sjw - 1), 1'b0, 3'(ph2 - 1), 1'b0, 3'(ph1 - 1), 1'b0, 3'(prop - 1), 8'(tq - 1)};
        vif.bit_clks = bit_clks;
        env.mon.bit_clks = bit_clks;
        env.mon.samp = bit_clks / 2;
        env.scb.bin("btr", $sformatf("tq_%0d", tq));
        env.scb.bin("btr", $sformatf("sjw_%0d", sjw));
        `uvm_info("TEST", $sformatf("bit timing: tq=%0d clk, prop=%0d ph1=%0d ph2=%0d sjw=%0d -> %0d clk/bit, BTR=%08h",
                                    tq, prop, ph1, ph2, sjw, bit_clks, btr), UVM_LOW)
    endfunction

    task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        for (int i = 0; i < 3; i++)
            node[i] = new(i, env.apb[i].sqr, env.scb, vif);
        @(posedge vif.rst_n);
        pick_btr();
        body();
        // let the last frame's IFS pass, then nothing may be left over
        repeat (20 * vif.bit_clks) @(posedge vif.clk);
        for (int i = 0; i < 3; i++) node[i].drain();
        phase.drop_objection(this);
    endtask

    virtual task init_all();
        fork
            node[0].init(btr);
            node[1].init(btr);
            node[2].init(btr);
        join
    endtask

    virtual task body();
    endtask

    function void report_phase(uvm_phase phase);
        uvm_report_server rs = uvm_report_server::get_server();
        int errs = rs.get_severity_count(UVM_ERROR) + rs.get_severity_count(UVM_FATAL);
        $display("RESULT: %s", errs == 0 ? "PASS" : "FAIL");
    endfunction

    // send one frame from node t and read it at every other enabled node
    task one_frame(int t, can_frame f);
        `uvm_info("TEST", $sformatf("node %0d sends %s", t, f.key()), UVM_HIGH)
        node[t].send(f);
        node[t].wait_tx_done();
        `uvm_info("TEST", $sformatf("node %0d TX_DONE", t), UVM_HIGH)
        for (int r = 0; r < 3; r++) if (r != t && env.scb.rx_en[r]) begin
            bit [7:0] g;
            node[r].wait_irq(I_RX, g);
            node[r].drain();
        end
    endtask
endclass

// ---------------------------------------------------------------------------
class regs_test extends base_test;
    `uvm_component_utils(regs_test)
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction
    task body();
        bit [31:0] d, v;
        bit [7:0] g;
        can_frame f = vectors::pick();
        for (int i = 0; i < 3; i++) begin
            node[i].check(R_CTRL, 32'h1, "CTRL reset");
            node[i].check(R_BTR, 32'h0001_2101, "BTR reset");
            node[i].check(R_STATUS, 32'h40, "STATUS reset (INIT)");
            node[i].check(R_IRQ, 0, "IRQ reset");
            node[i].check(R_ERRCNT, 0, "ERRCNT reset");
            node[i].check(12'h40, 0, "unmapped");
        end
        // read/write registers
        repeat (n) begin
            int i = $urandom_range(2);
            v = $urandom;
            node[i].wr(R_IRQ_EN, v);   node[i].check(R_IRQ_EN, {24'd0, v[7:0]}, "IRQ_EN");
            node[i].wr(R_TXID, v);     node[i].check(R_TXID, {20'd0, v[11:0]}, "TXID");
            node[i].wr(R_TXDLC, v);    node[i].check(R_TXDLC, {28'd0, v[3:0]}, "TXDLC");
            node[i].wr(R_TXD0, v);     node[i].check(R_TXD0, v, "TXD0");
            node[i].wr(R_TXD1, ~v);    node[i].check(R_TXD1, ~v, "TXD1");
            node[i].wr(R_BTR, v);      node[i].check(R_BTR, {10'd0, v[21:0]}, "BTR in INIT");
        end
        init_all();
        // BTR is locked outside INIT
        node[0].wr(R_BTR, 32'h0);
        node[0].check(R_BTR, btr, "BTR locked");
        // TX abort and TX buffer lock: nobody else on the bus, so node 0 never gets an ACK
        node[1].wr(R_CTRL, 1); node[2].wr(R_CTRL, 1);
        node[0].send(f);
        node[0].wait_irq(I_ERR, g);
        node[0].wr(R_TXID, 32'h0);
        node[0].check(R_TXID, {20'd0, f.rtr, f.id}, "TXID locked while pending");
        do begin
            node[0].wr(R_CMD, 2);
            node[0].rd(R_STATUS, d);
        end while (d[0]);
        // the monitor reports the aborted attempt when it sees the error flag,
        // which can be after the abort: drop the expectation only after that
        repeat (20 * vif.bit_clks) @(posedge vif.clk);
        env.scb.pending[0] = null;
        node[0].check(R_ERRFLAGS, 32'h10, "ERRFLAGS = ACK error");
        node[0].wr(R_ERRFLAGS, 32'h10);
        node[0].check(R_ERRFLAGS, 0, "ERRFLAGS W1C");
        node[0].wr(R_IRQ, 32'hFF);
        node[0].check(R_IRQ, 0, "IRQ W1C");
        // irq pin follows IRQ & IRQ_EN
        node[1].wr(R_IRQ_EN, 0);
        if (vif.irq[1]) `uvm_error("REG", "irq pin high with IRQ_EN = 0")
        node[1].wr(R_CTRL, 0); node[2].wr(R_CTRL, 0);
        repeat (40 * vif.bit_clks) @(posedge vif.clk);   // wait out the last error frame
    endtask
endclass

// ---------------------------------------------------------------------------
class frames_test extends base_test;
    `uvm_component_utils(frames_test)
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction
    task body();
        int tec, rec, cnt;
        bit [7:0] g;
        bit [31:0] d;
        init_all();
        for (int k = 0; k < n; k++)
            one_frame($urandom_range(2), vectors::pick());
        // FIFO: 4 frames fill it, the 5th overruns and is dropped
        for (int k = 0; k < 5; k++) begin
            node[0].send(vectors::pick());
            node[0].wait_tx_done();
            node[1].drain();
        end
        node[2].rx_count(cnt);
        if (cnt != 4) `uvm_error("TEST", $sformatf("RX FIFO holds %0d frames, expected 4", cnt))
        else env.scb.bin("rx", "fifo_full");
        node[2].rd(R_IRQ, d);
        if (!d[6]) `uvm_error("TEST", "no RX_OVERRUN interrupt") else env.scb.bin("rx", "overrun");
        void'(env.scb.rx_q[2].pop_back());   // the 5th frame was dropped
        node[2].drain();
        // a clean bus: no errors anywhere
        for (int i = 0; i < 3; i++) begin
            node[i].errcnt(tec, rec);
            node[i].rd(R_ERRFLAGS, d);
            if (tec != 0 || rec != 0 || d != 0)
                `uvm_error("TEST", $sformatf("node %0d: TEC=%0d REC=%0d ERRFLAGS=%0h on a clean bus", i, tec, rec, d))
        end
    endtask
endclass

// ---------------------------------------------------------------------------
class arb_test extends base_test;
    `uvm_component_utils(arb_test)
    int cases;
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction
    task body();
        init_all();
        for (int k = 0; k < n; k++) begin
            can_frame f [3];
            can_frame exp [$];
            int nc = $urandom_range(2, 3);
            int first = env.scb.bus_order.size();
            bit by_rtr = 0;
            // distinct (ID, RTR) per contender; 1 round in 4 starts with a
            // data frame and a remote frame of the same ID (RTR decides)
            if ($urandom_range(3) == 0) begin
                can_frame rem [$];
                foreach (vectors::all[j]) if (vectors::all[j].rtr) begin
                    foreach (vectors::all[m]) if (!vectors::all[m].rtr && vectors::all[m].id == vectors::all[j].id)
                        begin rem.push_back(vectors::all[m]); rem.push_back(vectors::all[j]); break; end
                end
                begin
                    int p = 2 * $urandom_range(rem.size() / 2 - 1);
                    f[0] = rem[p]; f[1] = rem[p + 1];
                end
            end
            for (int i = (f[0] == null ? 0 : 2); i < nc; i++) begin
                bit dup;
                do begin
                    f[i] = vectors::pick();
                    dup = 0;
                    for (int j = 0; j < i; j++) if (f[j].id == f[i].id && f[j].rtr == f[i].rtr) dup = 1;
                end while (dup);
            end
            for (int i = 0; i < nc; i++) for (int j = 0; j < i; j++)
                if (f[i].id == f[j].id) by_rtr = 1;
            for (int i = 0; i < nc; i++) begin
                node[i].scb.expect_tx(i, f[i]);
                node[i].load(f[i]);
                exp.push_back(f[i]);
            end
            exp.sort() with ({item.id, item.rtr});
            // all requests in the same clock, so the same bit
            fork
                node[0].wr(R_CMD, 1);
                node[1].wr(R_CMD, 1);
                if (nc == 3) node[2].wr(R_CMD, 1);
            join
            for (int i = 0; i < nc; i++) node[i].wait_tx_done();
            repeat (12 * vif.bit_clks) @(posedge vif.clk);
            for (int i = 0; i < 3; i++) node[i].drain();
            for (int i = 0; i < nc; i++)
                if (env.scb.bus_order[first + i] != exp[i])
                    `uvm_error("ARB", $sformatf("round %0d: bus slot %0d carried %s, expected %s", k, i,
                                                env.scb.bus_order[first + i].key(), exp[i].key()))
            cases++;
            env.scb.bin("arb", $sformatf("contenders_%0d", nc));
            if (by_rtr) env.scb.bin("arb", "decided_by_rtr");
        end
        $display("STATS arb_cases=%0d", cases);
    endtask
endclass

// ---------------------------------------------------------------------------
class rxerr_test extends base_test;
    `uvm_component_utils(rxerr_test)
    int matched;
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction
    task body();
        int tec_m [3], rec_m [3];
        init_all();
        for (int k = 0; k < n; k++) begin
            int t = $urandom_range(2);
            can_frame f = vectors::pick();
            int r, kb;
            bit [4:0] exp_flag;
            bit [31:0] d;
            int inj0 = vif.injected;
            if ($urandom_range(3) != 0) begin
                // a receiver sees one wrong bit: error type predicted by can_ref.receive()
                int j = $urandom_range(2);
                r = (t + $urandom_range(1, 2)) % 3;
                kb = f.plan_k[j];
                case (f.plan_t[j])
                    "stuff": exp_flag = 5'b00010;
                    "crc":   exp_flag = 5'b00100;
                    default: exp_flag = 5'b01000;
                endcase
            end else begin
                // the transmitter sees one wrong bit after arbitration: bit error
                r = t;
                kb = $urandom_range(f.arb_end, f.bits.len() - 1);
                exp_flag = 5'b00001;
            end
            vif.inj_node = r; vif.inj_bit = kb; vif.inj_en = 1;
            node[t].send(f);
            wait (vif.injected != inj0);
            // keep it on to the end of the flipped bit cell, then the retransmission is clean
            repeat (vif.bit_clks + 1) @(posedge vif.clk);
            vif.inj_en = 0;
            for (int i = 0; i < 3; i++) begin bit [7:0] g; if (i != t) node[i].wait_irq(I_RX, g); end
            node[t].wait_tx_done();
            for (int i = 0; i < 3; i++) node[i].drain();
            node[r].rd(R_ERRFLAGS, d);
            if (d[4:0] != exp_flag)
                `uvm_error("ERR", $sformatf("frame %s flip bit %0d at node %0d: ERRFLAGS=%05b, expected %05b",
                                            f.key(), kb, r, d[4:0], exp_flag))
            else matched++;
            // counter model: one error at every node (the flags make it global),
            // then one good frame: TX +8 -1, each RX +1 -1
            for (int i = 0; i < 3; i++) begin
                int tec, rec;
                if (i == t) tec_m[i] = tec_m[i] + 8 - 1;
                else        rec_m[i] = rec_m[i] + 1 - 1;
                node[i].errcnt(tec, rec);
                if (tec != tec_m[i] || rec != rec_m[i])
                    `uvm_error("ERR", $sformatf("node %0d TEC/REC %0d/%0d, model %0d/%0d", i, tec, rec, tec_m[i], rec_m[i]))
                node[i].wr(R_ERRFLAGS, 32'h1F);
            end
            // each round nets the transmitter +7 TEC. Keep every node error-active
            // (TEC < 128): a passive receiver's flag is recessive, so it would miss
            // the frame it flagged while the others accept it (legal, not checked here)
            while (tec_m[t] > 96) begin
                one_frame(t, vectors::pick());
                tec_m[t]--;
            end
        end
        $display("STATS err_predicted_match=%0d", matched);
    endtask
endclass

// ---------------------------------------------------------------------------
class busoff_test extends base_test;
    `uvm_component_utils(busoff_test)
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction
    task body();
        int tec, rec;
        bit [7:0] g;
        bit [31:0] d;
        can_frame f = vectors::pick();
        init_all();
        // 1. alone on the bus: ACK errors. +8 each until error-passive at 128,
        //    then an error-passive transmitter's ACK error does not count.
        node[1].wr(R_CTRL, 1); node[2].wr(R_CTRL, 1);
        env.scb.rx_en[1] = 0; env.scb.rx_en[2] = 0;
        node[0].send(f);
        node[0].wait_irq(I_PASSIVE, g);
        env.scb.bin("conf", "error_passive");
        repeat (4) node[0].wait_irq(I_ERR, g);
        node[0].errcnt(tec, rec);
        if (tec != 128) `uvm_error("CONF", $sformatf("passive ACK errors: TEC=%0d, expected to stay 128", tec))
        else env.scb.bin("conf", "passive_ack_no_tec");
        node[0].rd(R_STATUS, d);
        if (!d[4]) `uvm_error("CONF", "STATUS.err_passive not set")
        // receivers come back: the frame goes through, TEC 128 -> 127, error-active
        env.scb.rx_en[1] = 1; env.scb.rx_en[2] = 1;
        fork node[1].wr(R_CTRL, 0); node[2].wr(R_CTRL, 0); join
        node[0].wait_tx_done();
        node[0].errcnt(tec, rec);
        if (tec != 127) `uvm_error("CONF", $sformatf("TEC=%0d after a good frame, expected 127", tec))
        for (int i = 1; i < 3; i++) begin node[i].wait_irq(I_RX, g); node[i].drain(); end

        // 2. node 0 sees a wrong bit in every attempt: bit errors -> bus-off
        // the flipped bit must be followed by a dominant frame bit: node 0 becomes
        // error-passive on this error, and a recessive (passive) error flag over
        // bits that are recessive anyway leaves a good frame that the receivers
        // accept, which node 0 then repeats (legal CAN, but not what this test checks)
        f = vectors::pick();
        begin
            int last0 = f.bits.len() - 1;
            while (f.bits.getc(last0) != "0") last0--;
            vif.inj_bit = $urandom_range(f.arb_end, last0 - 1);
        end
        vif.inj_node = 0; vif.inj_en = 1;
        env.scb.check_prefix = 0;   // node 0's error flag can start inside the frame body
        node[0].send(f);
        node[0].wait_irq(I_BUS_OFF, g);
        vif.inj_en = 0;
        env.scb.bin("conf", "bus_off");
        node[0].errcnt(tec, rec);
        node[0].rd(R_STATUS, d);
        if (tec < 256 || !d[5]) `uvm_error("CONF", $sformatf("bus-off: TEC=%0d STATUS=%0h", tec, d))
        // 128 x 11 recessive bits, then back with TEC = REC = 0; the frame is still pending
        node[0].wait_irq(I_BUS_ON, g, 200 * 1408 * vif.bit_clks / 100);
        env.scb.bin("conf", "recovered");
        node[0].errcnt(tec, rec);
        if (tec != 0 || rec != 0) `uvm_error("CONF", $sformatf("after recovery TEC=%0d REC=%0d", tec, rec))
        node[0].wait_tx_done();
        for (int i = 1; i < 3; i++) begin node[i].wait_irq(I_RX, g); node[i].drain(); end
        // receivers saw one error per attempt; good frames since bring REC back down
        for (int i = 1; i < 3; i++) begin
            node[i].errcnt(tec, rec);
            if (tec != 0 || rec > 32) `uvm_error("CONF", $sformatf("node %0d TEC=%0d REC=%0d", i, tec, rec))
        end
    endtask
endclass

// ---------------------------------------------------------------------------
class noise_test extends base_test;
    `uvm_component_utils(noise_test)
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction
    task body();
        init_all();
        env.scb.check_prefix = 0;
        vif.noise_div = 400;
        for (int k = 0; k < n; k++)
            one_frame($urandom_range(2), vectors::pick());
        vif.noise_div = 0;
    endtask
endclass
