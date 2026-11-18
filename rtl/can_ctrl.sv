// -----------------------------------------------------------------------------
// can_ctrl.sv : CAN 2.0A controller, top level. APB3 slave + registers +
// TX buffer + 4-entry RX FIFO, around can_btl (bit timing) and can_core.
//
//   APB as in amba-uvm-vip (SETUP then ACCESS, write/read in the ACCESS cycle
//   with PREADY=1), but no wait states and no PSLVERR: unmapped reads return 0.
//
//   Offset Name     Access Reset       Fields
//   0x00   CTRL     RW     0x0000_0001 [0] INIT: 1 = off the bus, BTR writable.
//                                      Clearing it starts bus integration
//                                      (11 recessive bits) before joining.
//   0x04   BTR      RW     0x0001_2101 [7:0] BRP (tq = BRP+1 clocks)
//                                      [10:8] PROP-1  [14:12] PH1-1
//                                      [18:16] PH2-1  [21:20] SJW-1
//                                      only written while CTRL.INIT = 1
//   0x08   CMD      W      -           [0] TX_REQ  [1] TX_ABORT (only if not on
//                                      the bus yet)  [2] RX_POP (drop FIFO head)
//   0x0C   STATUS   RO     -           [0] tx pending  [1] transmitting
//                                      [2] bus busy  [3] RX FIFO not empty
//                                      [4] error-passive  [5] bus-off
//                                      [6] INIT or integrating  [10:8] RX count
//   0x10   IRQ      W1C    0           [0] TX_DONE [1] RX [2] ERR [3] ARB_LOST
//                                      [4] ERR_PASSIVE (entered) [5] BUS_OFF
//                                      [6] RX_OVERRUN [7] BUS_ON (recovered)
//   0x14   IRQ_EN   RW     0           same bits; irq = |(IRQ & IRQ_EN)
//   0x18   ERRCNT   RO     0           [8:0] TEC  [23:16] REC
//   0x1C   ERRFLAGS W1C    0           sticky: [0] BIT [1] STUFF [2] CRC [3] FORM
//                                      [4] ACK
//   0x20   TXID     RW     0           [10:0] ID  [11] RTR   } ignored while a
//   0x24   TXDLC    RW     0           [3:0] DLC             } TX request is
//   0x28   TXD0     RW     0           bytes 0..3 (byte 0 in [7:0])  } pending
//   0x2C   TXD1     RW     0           bytes 4..7
//   0x30   RXID     RO     -           FIFO head: [10:0] ID  [11] RTR
//   0x34   RXDLC    RO     -           FIFO head: [3:0] DLC
//   0x38   RXD0     RO     -           FIFO head bytes 0..3
//   0x3C   RXD1     RO     -           FIFO head bytes 4..7
// -----------------------------------------------------------------------------
module can_ctrl #(
    parameter int AW = 12
) (
    input  logic          pclk,
    input  logic          presetn,
    input  logic          psel,
    input  logic          penable,
    input  logic          pwrite,
    input  logic [AW-1:0] paddr,
    input  logic [31:0]   pwdata,
    output logic [31:0]   prdata,
    output logic          pready,
    output logic          pslverr,
    output logic          irq,
    // CAN transceiver side (0 = dominant)
    input  logic          can_rx,
    output logic          can_tx
);
    localparam int FD = 4;   // RX FIFO depth

    // ---------------- registers ----------------
    logic        init;
    logic [21:0] btr;
    logic [7:0]  irq_st, irq_en;
    logic [4:0]  errflags;
    logic [10:0] txid;
    logic        txrtr;
    logic [3:0]  txdlc;
    logic [31:0] txd0, txd1;
    logic        tx_pend;

    // RX FIFO: {rtr, id, dlc, data}
    logic [79:0] fifo [FD];
    logic [1:0]  wp, rp;
    logic [2:0]  cnt;

    // core signals
    logic        sample, sbit, tx_point, hard_sync_en;
    logic        tx_done, arb_lost, transmitting, rx_valid, err;
    logic [4:0]  err_type;
    logic [10:0] rx_id;
    logic        rx_rtr;
    logic [3:0]  rx_dlc;
    logic [63:0] rx_data;
    logic [8:0]  tec;
    logic [7:0]  rec;
    logic        err_passive, bus_off, busy;

    // two-flop synchroniser on the asynchronous bus input
    logic rx_s1, rx_s2;
    always_ff @(posedge pclk or negedge presetn)
        if (!presetn) {rx_s2, rx_s1} <= 2'b11;
        else          {rx_s2, rx_s1} <= {rx_s1, can_rx};

    // ---------------- APB ----------------
    wire access = psel && penable;
    wire wr     = access && pwrite;
    wire [AW-1:0] a = paddr;
    assign pready  = 1'b1;
    assign pslverr = 1'b0;

    // bytes are numbered 0..7 in the order they go on the bus
    function automatic logic [31:0] swap4(input logic [31:0] w);
        swap4 = {w[7:0], w[15:8], w[23:16], w[31:24]};
    endfunction

    logic [31:0] rd;
    wire  [79:0] head = fifo[rp];
    always_comb begin
        case (a)
            AW'('h00): rd = {31'd0, init};
            AW'('h04): rd = {10'd0, btr};
            AW'('h0C): rd = {21'd0, cnt, 1'b0, init || !(busy || hard_sync_en || bus_off), bus_off, err_passive,
                             cnt != 3'd0, busy, transmitting, tx_pend};
            AW'('h10): rd = {24'd0, irq_st};
            AW'('h14): rd = {24'd0, irq_en};
            AW'('h18): rd = {8'd0, rec, 7'd0, tec};
            AW'('h1C): rd = {27'd0, errflags};
            AW'('h20): rd = {20'd0, txrtr, txid};
            AW'('h24): rd = {28'd0, txdlc};
            AW'('h28): rd = txd0;
            AW'('h2C): rd = txd1;
            AW'('h30): rd = {20'd0, head[79], head[78:68]};
            AW'('h34): rd = {28'd0, head[67:64]};
            AW'('h38): rd = swap4(head[63:32]);
            AW'('h3C): rd = swap4(head[31:0]);
            default:   rd = '0;
        endcase
    end
    assign prdata = (access && !pwrite) ? rd : '0;

    wire cmd_wr   = wr && a == AW'('h08);
    wire tx_req_w = cmd_wr && pwdata[0];
    wire abort_w  = cmd_wr && pwdata[1] && !transmitting;
    wire pop_w    = cmd_wr && pwdata[2] && cnt != 3'd0;
    wire push     = rx_valid && cnt != 3'(FD);
    wire overrun  = rx_valid && cnt == 3'(FD);

    logic passive_q, boff_q;   // for edge-triggered interrupts

    always_ff @(posedge pclk or negedge presetn) begin
        if (!presetn) begin
            init <= 1'b1;
            btr  <= 22'h01_2101;   // BRP 1, PROP 2, PH1 3, PH2 2, SJW 1 -> 8 tq, sample at 75%
            irq_st <= '0; irq_en <= '0; errflags <= '0;
            txid <= '0; txrtr <= 1'b0; txdlc <= '0; txd0 <= '0; txd1 <= '0;
            tx_pend <= 1'b0;
            wp <= '0; rp <= '0; cnt <= '0;
            passive_q <= 1'b0; boff_q <= 1'b0;
        end else begin
            passive_q <= err_passive;
            boff_q    <= bus_off;
            if (wr) begin
                case (a)
                    AW'('h00): init <= pwdata[0];
                    AW'('h04): if (init) btr <= pwdata[21:0];
                    AW'('h14): irq_en <= pwdata[7:0];
                    AW'('h20): if (!tx_pend) {txrtr, txid} <= pwdata[11:0];
                    AW'('h24): if (!tx_pend) txdlc <= pwdata[3:0];
                    AW'('h28): if (!tx_pend) txd0 <= pwdata;
                    AW'('h2C): if (!tx_pend) txd1 <= pwdata;
                    default: ;
                endcase
            end
            // pending TX request
            if (tx_done || abort_w) tx_pend <= 1'b0;
            else if (tx_req_w)      tx_pend <= 1'b1;
            // RX FIFO
            if (push) begin
                fifo[wp] <= {rx_rtr, rx_id, rx_dlc, rx_data};
                wp <= wp + 2'd1;
            end
            if (pop_w) rp <= rp + 2'd1;
            cnt <= cnt + 3'(push) - 3'(pop_w);
            // interrupts: set by events, cleared by writing 1 (set wins)
            irq_st <= (irq_st & ~((wr && a == AW'('h10)) ? pwdata[7:0] : 8'd0))
                    | {boff_q && !bus_off, overrun, bus_off && !boff_q, err_passive && !passive_q,
                       arb_lost, err, push, tx_done};
            errflags <= (errflags & ~((wr && a == AW'('h1C)) ? pwdata[4:0] : 5'd0))
                      | (err ? err_type : 5'd0);
        end
    end
    assign irq = |(irq_st & irq_en);

    // ---------------- bit timing + bit stream ----------------
    can_btl u_btl (
        .clk(pclk), .rst_n(presetn), .enable(!init),
        .brp(btr[7:0]),
        .tseg1(5'(btr[10:8]) + 5'(btr[14:12]) + 5'd2),
        .tseg2(4'(btr[18:16]) + 4'd1),
        .sjw(3'(btr[21:20]) + 3'd1),
        .rx_i(rx_s2), .hard_sync_en(hard_sync_en), .own_dom(!can_tx),
        .sample(sample), .sampled_bit(sbit), .tx_point(tx_point)
    );

    can_core u_core (
        .clk(pclk), .rst_n(presetn), .enable(!init),
        .sample(sample), .rxb(sbit), .tx_point(tx_point),
        .hard_sync_en(hard_sync_en), .can_tx(can_tx),
        .tx_req(tx_pend), .tx_id(txid), .tx_rtr(txrtr), .tx_dlc(txdlc),
        .tx_data({swap4(txd0), swap4(txd1)}),
        .tx_done(tx_done), .arb_lost(arb_lost), .transmitting(transmitting),
        .rx_valid(rx_valid), .rx_id(rx_id), .rx_rtr(rx_rtr), .rx_dlc(rx_dlc), .rx_data(rx_data),
        .err(err), .err_type(err_type), .tec(tec), .rec(rec),
        .err_passive(err_passive), .bus_off(bus_off), .busy(busy)
    );
endmodule
