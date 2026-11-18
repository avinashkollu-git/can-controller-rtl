// can_sva.sv : protocol checks on can_core, bound to every instance
// (tb_top: bind can_core can_sva u_sva (.*)). Ports are can_core's own
// ports and internal signals, connected by name.
//
//   stuffing    - this node never drives 6 equal bits inside the stuffed region,
//                 and 6 equal sampled bits there always raise a stuff (or bit) error
//   arbitration - arbitration is lost only in ID/RTR, by sending recessive and
//                 seeing dominant; afterwards the node is a receiver and drives
//                 recessive through the rest of the arbitration/data/CRC fields
//   counters    - TEC moves only by +8, -1 or to 0; bus-off <=> TEC > 255;
//                 a bus-off node never drives dominant; passive flags are recessive
`timescale 1ns / 1ps

module can_sva (
    input logic        clk,
    input logic        rst_n,
    input logic        enable,
    input logic        sample,
    input logic        rxb,
    input logic        tx_point,
    input logic        can_tx,
    input logic        transmitting,
    input logic        arb_lost,
    input logic        err,
    input logic [4:0]  err_type,
    input logic [8:0]  tec,
    input logic [7:0]  rec,
    input logic        err_passive,
    input logic        bus_off,
    input logic        rx_valid,
    input logic        rx_rtr,
    input logic [3:0]  rx_dlc,
    input logic [4:0]  state,
    input logic        stuff_on,
    input logic        stuff_bit,
    input logic        is_arb,
    input logic        pass_flag,
    input logic [4:0]  det
);
    // state encoding of can_core::state_e (same order)
    localparam logic [4:0] S_IDLE = 5'd1, S_ID = 5'd2, S_RTR = 5'd3, S_CRC = 5'd8,
                           S_ERR_FLAG = 5'd14, S_BUS_OFF = 5'd16;

    // --- aux: run length of equal bits on the bus (sampled) and driven by us ---
    int unsigned rx_run, tx_run;
    logic rx_last, tx_last, txp_q, tx_region;
    logic flag_on;   // our error flag is on the wire (from its first tx_point)
    always_ff @(posedge clk) begin
        txp_q <= tx_point;   // can_tx holds the new bit one cycle after tx_point
        if (state != S_ERR_FLAG) flag_on <= 1'b0;
        else if (tx_point)       flag_on <= 1'b1;
        if (!rst_n || !stuff_on && state != S_IDLE) begin
            rx_run <= 0; tx_run <= 0;
        end
        if (rst_n && sample && stuff_on) begin
            rx_run  <= (rxb == rx_last) ? rx_run + 1 : 1;
            rx_last <= rxb;
        end else if (rst_n && sample && state == S_IDLE && !rxb) begin   // SOF
            rx_run <= 1; rx_last <= 1'b0;
        end
        // TX side: count from our SOF while we transmit the stuffed region
        if (rst_n && txp_q) begin
            tx_region <= transmitting && (stuff_on || state == S_IDLE);
            if (transmitting && (stuff_on || state == S_IDLE)) begin
                tx_run  <= (tx_region && can_tx == tx_last) ? tx_run + 1 : 1;
                tx_last <= can_tx;
            end
        end
    end

    // ---------------- stuffing ----------------
    a_tx_stuff: assert property (@(posedge clk) disable iff (!rst_n || !enable) tx_run <= 5)
        else $error("node drove %0d equal bits in the stuffed region", tx_run);
    a_rx_stuff: assert property (@(posedge clk) disable iff (!rst_n || !enable)
        sample && stuff_on && rx_run == 5 && rxb == rx_last && state != S_IDLE |-> det != 5'd0)
        else $error("6 equal bits sampled without an error");

    // ---------------- arbitration ----------------
    a_arb_where: assert property (@(posedge clk) disable iff (!rst_n)
        arb_lost |-> $past(sample && is_arb && can_tx && !rxb && !stuff_bit && transmitting))
        else $error("arbitration lost outside ID/RTR or without recessive-vs-dominant");
    a_arb_rx: assert property (@(posedge clk) disable iff (!rst_n)
        arb_lost |-> !transmitting);
    a_rx_quiet: assert property (@(posedge clk) disable iff (!rst_n || !enable)
        !transmitting && state >= S_ID && state <= S_CRC |-> can_tx)
        else $error("a receiver drove dominant inside the frame body");

    // ---------------- error counters ----------------
    a_tec_step: assert property (@(posedge clk) disable iff (!rst_n)
        tec != $past(tec) |-> tec == $past(tec) + 9'd8 || tec == $past(tec) - 9'd1 || tec == 9'd0)
        else $error("TEC jumped %0d -> %0d", $past(tec), tec);
    a_tec_max: assert property (@(posedge clk) disable iff (!rst_n) tec <= 9'd263);
    a_boff_tec: assert property (@(posedge clk) disable iff (!rst_n)
        bus_off == (tec > 9'd255) && (bus_off == (state == S_BUS_OFF)));
    a_boff_quiet: assert property (@(posedge clk) disable iff (!rst_n) bus_off |-> can_tx)
        else $error("bus-off node drives dominant");
    a_passive: assert property (@(posedge clk) disable iff (!rst_n)
        err_passive == (!bus_off && (tec > 9'd127 || rec > 8'd127)));
    a_pass_flag: assert property (@(posedge clk) disable iff (!rst_n)
        flag_on && pass_flag |-> can_tx)
        else $error("passive error flag drove dominant");
    a_err_onehot: assert property (@(posedge clk) disable iff (!rst_n) err |-> $onehot(err_type));

    // ---------------- cover ----------------
    c_arb_lost:   cover property (@(posedge clk) arb_lost);
    c_err_bit:    cover property (@(posedge clk) err && err_type[0]);
    c_err_stuff:  cover property (@(posedge clk) err && err_type[1]);
    c_err_crc:    cover property (@(posedge clk) err && err_type[2]);
    c_err_form:   cover property (@(posedge clk) err && err_type[3]);
    c_err_ack:    cover property (@(posedge clk) err && err_type[4]);
    c_passive:    cover property (@(posedge clk) $rose(err_passive));
    c_bus_off:    cover property (@(posedge clk) $rose(bus_off));
    c_recover:    cover property (@(posedge clk) $fell(bus_off));
    c_pass_flag:  cover property (@(posedge clk) state == S_ERR_FLAG && pass_flag);
    c_stuff_bit:  cover property (@(posedge clk) sample && stuff_bit && det == 5'd0);
    c_rx_8bytes:  cover property (@(posedge clk) rx_valid && rx_dlc >= 4'd8);
    c_rx_remote:  cover property (@(posedge clk) rx_valid && rx_rtr);
    c_tx_run5:    cover property (@(posedge clk) tx_run == 5);
endmodule
