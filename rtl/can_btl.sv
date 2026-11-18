// -----------------------------------------------------------------------------
// can_btl.sv : CAN bit timing logic.
//
//   One bit = SYNC (1 tq) + PROP + PH1 (= TSEG1) + PH2 (= TSEG2), in time quanta.
//   One time quantum (tq) = (brp + 1) clock cycles.
//
//     |SYNC|<---- PROP ---->|<--- PH1 --->|<-- PH2 -->|
//     q=0   1 ............................ T1|T1+1 ... T1+T2
//                                         ^ sample point (end of PH1)
//     ^ tx_point: the transmitter changes its output here
//
//   Synchronisation (simplified, documented in README "Limitations"):
//   - Hard sync: while the core is idle (hard_sync_en), a recessive->dominant
//     edge (an SOF) restarts the bit: the edge becomes the SYNC segment.
//   - Resync: any other recessive->dominant edge, at most once per bit and
//     only if the last sampled bit was recessive. The phase error is measured
//     in whole tq (not clock cycles):
//       edge in PROP/PH1 (late)  -> PH1 is lengthened by min(e, SJW) tq
//       edge in PH2 (early)      -> PH2 is shortened by min(e, SJW) tq;
//                                   if e <= SJW the new bit starts at the edge
//   A node never resyncs on an edge it made itself (it is driving dominant):
//   the loop delay through its transceiver would look like a late edge.
//   The core never sees the edge itself, only the sample and tx_point pulses.
// -----------------------------------------------------------------------------
module can_btl (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       enable,       // 0 in INIT mode: counters held in reset
    input  logic [7:0] brp,          // tq = brp + 1 clocks
    input  logic [4:0] tseg1,        // PROP + PH1, in tq (2..16)
    input  logic [3:0] tseg2,        // PH2, in tq (1..8)
    input  logic [2:0] sjw,          // resync jump width, in tq (1..4)
    input  logic       rx_i,         // synchronised bus value (0 = dominant)
    input  logic       hard_sync_en, // core is idle: next falling edge is an SOF
    input  logic       own_dom,      // this node drives dominant now: its own edge, no resync
    output logic       sample,       // 1-cycle pulse at the sample point
    output logic       sampled_bit,  // bus value latched at the last sample point
    output logic       tx_point      // 1-cycle pulse at the start of each bit
);
    logic [7:0] presc;
    logic [4:0] qcnt;        // quantum index within the bit (0 = SYNC)
    logic [2:0] ext;         // PH1 lengthening for this bit (late edge)
    logic [2:0] shorten;     // PH2 shortening for this bit (early edge)
    logic       synced;      // one resync per bit: set by an edge, cleared at the sample point
    logic       rx_q;        // rx one clock ago, for edge detection
    logic       sampled_q;   // value at the last sample point

    wire tick  = (presc == brp);
    wire edge_ = rx_q && !rx_i;                     // recessive -> dominant
    wire [4:0] t1    = tseg1 + 5'(ext);             // sample point quantum
    wire [4:0] lastq = t1 + 5'(tseg2) - 5'(shorten);
    wire in_ph2      = (qcnt > t1);
    // phase error in tq: late edge = quanta since SYNC, early edge = quanta left in the bit
    wire [4:0] e_late  = qcnt;
    wire [4:0] e_early = lastq - qcnt + 5'd1;
    wire [4:0] sjw5    = 5'(sjw);

    wire hard   = enable && hard_sync_en && edge_;
    wire resync = enable && !hard_sync_en && !own_dom && edge_ && !synced && sampled_q && qcnt != 5'd0;
    // early edge within SJW: start the next bit right now
    wire jump   = resync && in_ph2 && e_early <= sjw5;

    assign sampled_bit = sampled_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            presc     <= '0;
            qcnt      <= '0;
            ext       <= '0;
            shorten   <= '0;
            synced    <= 1'b0;
            rx_q      <= 1'b1;
            sampled_q <= 1'b1;
            sample    <= 1'b0;
            tx_point  <= 1'b0;
        end else begin
            rx_q     <= rx_i;
            sample   <= 1'b0;
            tx_point <= 1'b0;
            if (!enable) begin
                presc     <= '0;
                qcnt      <= '0;
                ext       <= '0;
                shorten   <= '0;
                synced    <= 1'b0;
                sampled_q <= 1'b1;
            end else if (hard || jump) begin
                // the edge is the SYNC segment of a new bit
                presc   <= '0;
                qcnt    <= '0;
                ext     <= '0;
                shorten <= '0;
                synced  <= 1'b1;
                tx_point <= jump;   // hard sync: the SOF is already on the bus
            end else begin
                if (resync && !in_ph2) begin
                    ext    <= 3'((e_late < sjw5) ? e_late : sjw5);
                    synced <= 1'b1;
                end else if (resync) begin
                    shorten <= sjw;   // e_early > SJW here
                    synced  <= 1'b1;
                end
                presc <= tick ? '0 : presc + 8'd1;
                if (tick) begin
                    if (qcnt == t1) begin
                        sample    <= 1'b1;
                        sampled_q <= rx_i;
                        synced    <= 1'b0;
                    end
                    if (qcnt >= lastq) begin
                        qcnt     <= '0;
                        ext      <= '0;
                        shorten  <= '0;
                        tx_point <= 1'b1;
                    end else begin
                        qcnt <= qcnt + 5'd1;
                    end
                end
            end
        end
    end
endmodule
