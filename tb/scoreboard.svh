// scoreboard.svh : frame-level checks against the golden vectors, RX FIFO
// checks, error/arbitration counts and the coverage table.
//
//  - every complete frame on the bus must be one some node was asked to send,
//    and its stuffed bit stream must equal the golden one bit for bit
//    (that checks ID/DLC/data order, stuff bits and the CRC-15 together)
//  - every receiver must read each delivered frame exactly once, in bus order
//  - aborted frames (error flag) must match the golden stream up to the flag
//
// Covergroups are not collected by Verilator, so coverage is a table of named
// bins sampled here and printed as "COVBIN can <coverpoint> <bin> <hits>"
// lines; scripts/regress.py merges them over all runs.

class can_scoreboard extends uvm_scoreboard;
    `uvm_component_utils(can_scoreboard)
    uvm_analysis_imp #(can_frame, can_scoreboard) imp;
    virtual can_tb_if vif;

    can_frame pending [3];        // frame each node is currently asked to send
    bit       rx_en [3] = '{1, 1, 1};
    can_frame rx_q [3][$];        // frames each receiver has yet to read
    can_frame bus_order [$];      // complete frames, in bus order
    bit       check_prefix = 1;   // off when bus noise corrupts the stream itself

    int frames_checked, rx_checked, aborted, prefix_checked, errors_seen;
    int err_cnt [3][5];           // per node: bit, stuff, crc, form, ack
    int arb_lost [3];
    int cov [string];             // "coverpoint bin" -> hits
    string cov_order [$];

    function new(string name, uvm_component parent);
        super.new(name, parent);
        imp = new("imp", this);
    endfunction

    function void bin(string cp, string b, int n = 1);
        string k = {cp, " ", b};
        if (!cov.exists(k)) begin cov[k] = 0; cov_order.push_back(k); end
        cov[k] += n;
    endfunction

    function void build_phase(uvm_phase phase);
        // declare every bin up front, so bins never hit show up with 0
        string dl [10] = '{"d0","d1","d2","d3","d4","d5","d6","d7","d8","d9_15"};
        foreach (dl[i]) bin("dlc", dl[i], 0);
        bin("id", "000", 0); bin("id", "7FF", 0); bin("id", "001_0FF", 0);
        bin("id", "100_3FF", 0); bin("id", "400_7FE", 0);
        bin("stuff_bits", "0", 0); bin("stuff_bits", "1_2", 0);
        bin("stuff_bits", "3_5", 0); bin("stuff_bits", "6_up", 0);
        bin("frame", "data", 0); bin("frame", "remote", 0);
        bin("error", "bit", 0); bin("error", "stuff", 0); bin("error", "crc", 0);
        bin("error", "form", 0); bin("error", "ack", 0);
        bin("arb", "lost_node0", 0); bin("arb", "lost_node1", 0); bin("arb", "lost_node2", 0);
        bin("arb", "contenders_2", 0); bin("arb", "contenders_3", 0); bin("arb", "decided_by_rtr", 0);
        bin("conf", "error_passive", 0); bin("conf", "bus_off", 0); bin("conf", "recovered", 0);
        bin("conf", "passive_ack_no_tec", 0);
        bin("rx", "fifo_full", 0); bin("rx", "overrun", 0);
        bin("btr", "tq_2", 0); bin("btr", "tq_3", 0); bin("btr", "tq_4", 0);
        bin("btr", "sjw_1", 0); bin("btr", "sjw_2", 0);
        if (!uvm_config_db #(virtual can_tb_if)::get(this, "", "cif", vif))
            `uvm_fatal("SCB", "cif not set")
    endfunction

    function void expect_tx(int node, can_frame f);
        if (pending[node] != null) `uvm_fatal("SCB", $sformatf("node %0d already has a pending frame", node))
        pending[node] = f;
    endfunction

    function void write(can_frame m);
        int n = -1;
        // a frame nobody acknowledged is not delivered: the sender repeats it
        if (m.complete && m.acked) begin
            foreach (pending[i]) if (pending[i] != null && pending[i].same(m)) n = i;
            if (n < 0) begin
                `uvm_error("SCB", {"frame on the bus that nobody sent: ", m.key()})
                return;
            end
            if (m.bits != pending[n].bits)
                `uvm_error("SCB", $sformatf("bit stream mismatch %s\n  bus    %s\n  golden %s",
                                            m.key(), m.bits, pending[n].bits))
            if (m.crc != pending[n].crc)
                `uvm_error("SCB", $sformatf("CRC %04h, golden %04h", m.crc, pending[n].crc))
            frames_checked++;
            sample_frame(pending[n]);
            bus_order.push_back(pending[n]);
            foreach (rx_q[r]) if (r != n && rx_en[r]) rx_q[r].push_back(pending[n]);
            pending[n] = null;
        end else begin
            aborted++;
            if (check_prefix && m.bits.len() > 8) begin
                int cmp = m.bits.len() - 7;   // the last bits can be the error flag
                bit hit = 0;
                foreach (pending[i])
                    if (pending[i] != null && pending[i].bits.substr(0, cmp - 1) == m.bits.substr(0, cmp - 1))
                        hit = 1;
                if (!hit) `uvm_error("SCB", {"aborted frame matches no pending golden stream: ", m.bits})
                prefix_checked++;
            end
        end
    endfunction

    // a receiver read a frame from its RX FIFO
    function void rx(int node, can_frame f);
        if (rx_q[node].size() == 0) begin
            `uvm_error("SCB", $sformatf("node %0d read %s but nothing was delivered to it", node, f.key()))
            return;
        end
        if (!rx_q[node][0].same(f))
            `uvm_error("SCB", $sformatf("node %0d read %s, expected %s", node, f.key(), rx_q[node][0].key()))
        void'(rx_q[node].pop_front());
        rx_checked++;
    endfunction

    function void sample_frame(can_frame f);
        int sb = f.bits.len() - (19 + 8 * f.nbytes() + 15);
        if (f.dlc > 8) bin("dlc", "d9_15"); else bin("dlc", $sformatf("d%0d", f.dlc));
        if (f.id == 0) bin("id", "000");
        else if (f.id == 11'h7FF) bin("id", "7FF");
        else if (f.id < 11'h100) bin("id", "001_0FF");
        else if (f.id < 11'h400) bin("id", "100_3FF");
        else bin("id", "400_7FE");
        bin("stuff_bits", sb == 0 ? "0" : sb <= 2 ? "1_2" : sb <= 5 ? "3_5" : "6_up");
        bin("frame", f.rtr ? "remote" : "data");
    endfunction

    // DUT error and arbitration pulses
    task run_phase(uvm_phase phase);
        string en [5] = '{"bit", "stuff", "crc", "form", "ack"};
        forever begin
            @(posedge vif.clk);
            for (int n = 0; n < 3; n++) begin
                if (vif.err[n])
                    for (int t = 0; t < 5; t++)
                        if (vif.err_type[n][t]) begin
                            err_cnt[n][t]++; bin("error", en[t]);
                            `uvm_info("SCB", $sformatf("node %0d detected a %s error", n, en[t]), UVM_HIGH)
                        end
                if (vif.arb_lost[n]) begin arb_lost[n]++; bin("arb", $sformatf("lost_node%0d", n)); end
            end
        end
    endtask

    function void check_phase(uvm_phase phase);
        foreach (pending[i]) if (pending[i] != null)
            `uvm_error("SCB", $sformatf("node %0d frame never sent: %s", i, pending[i].key()))
        foreach (rx_q[i]) if (rx_q[i].size() != 0)
            `uvm_error("SCB", $sformatf("node %0d never read %0d delivered frame(s)", i, rx_q[i].size()))
    endfunction

    function void report_phase(uvm_phase phase);
        int e [5];
        foreach (err_cnt[n, t]) e[t] += err_cnt[n][t];
        foreach (cov_order[i]) $display("COVBIN can %s %0d", cov_order[i], cov[cov_order[i]]);
        $display("STATS frames_checked=%0d rx_checked=%0d aborted=%0d prefix_checked=%0d injected=%0d err_bit=%0d err_stuff=%0d err_crc=%0d err_form=%0d err_ack=%0d arb_lost=%0d",
                 frames_checked, rx_checked, aborted, prefix_checked, vif.injected,
                 e[0], e[1], e[2], e[3], e[4], arb_lost[0] + arb_lost[1] + arb_lost[2]);
    endfunction
endclass
