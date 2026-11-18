// -----------------------------------------------------------------------------
// can_core.sv : CAN 2.0A bit stream processor + fault confinement.
//
//   One state machine for both directions, like a real controller: every node,
//   including the transmitter, decodes the bus at each sample point. The
//   transmitter additionally drives its next bit at each tx_point and checks at
//   the sample point that the bus shows what it sent (bit monitoring). So the
//   CRC, stuffing and field counters are shared by TX and RX.
//
//   Data frame (standard ID), bits before stuffing:
//     SOF ID[10:0] RTR IDE r0 DLC[3:0] DATA[0..64] CRC[14:0] | CRCdel ACK ACKdel EOF(7) IFS(3)
//     |<--------------- bit stuffing + CRC-15 ------------->|  fixed form, no stuffing
//
//   Errors (one at a time, at a sample point; error flag starts at the next bit):
//     bit   - transmitter sees a bit it did not send (except arbitration, ACK slot)
//     stuff - 6 equal bits in the stuffed region
//     crc   - receiver: computed CRC != received CRC (flag after ACK delimiter)
//     form  - CRC delimiter, ACK delimiter or EOF dominant; IDE recessive
//             (extended frames are not supported, see README)
//     ack   - transmitter sees no dominant bit in the ACK slot
//
//   Fault confinement (simplified ISO 11898-1 rules, see README):
//     receiver error +1 REC, transmitter error +8 TEC (not for an ACK error
//     while error-passive), good TX -1 TEC, good RX -1 REC (REC > 127 -> 127).
//     error-passive: TEC > 127 or REC > 127 (sends recessive error flags)
//     bus-off:       TEC > 255; leaves the bus at once; back to error-active
//                    with TEC = REC = 0 after 128 x 11 recessive bits.
// -----------------------------------------------------------------------------
module can_core (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        enable,      // 0 = INIT mode: off the bus, state reset
    // bit timing
    input  logic        sample,
    input  logic        rxb,         // bus value at the sample point
    input  logic        tx_point,
    output logic        hard_sync_en,
    output logic        can_tx,      // to the transceiver (0 = dominant)
    // transmit request (the register block holds these stable while tx_req=1)
    input  logic        tx_req,
    input  logic [10:0] tx_id,
    input  logic        tx_rtr,
    input  logic [3:0]  tx_dlc,
    input  logic [63:0] tx_data,     // byte 0 in [63:56], sent first
    output logic        tx_done,     // pulse: frame sent without error
    output logic        arb_lost,    // pulse: lost arbitration, now receiving
    output logic        transmitting,
    // receive
    output logic        rx_valid,    // pulse: good frame received
    output logic [10:0] rx_id,
    output logic        rx_rtr,
    output logic [3:0]  rx_dlc,
    output logic [63:0] rx_data,     // byte 0 in [63:56]
    // errors
    output logic        err,         // pulse: an error was detected
    output logic [4:0]  err_type,    // with err: {ack, form, crc, stuff, bit}, one-hot
    output logic [8:0]  tec,
    output logic [7:0]  rec,
    output logic        err_passive,
    output logic        bus_off,
    output logic        busy         // a frame (or error frame) is on the bus
);
    typedef enum logic [4:0] {
        S_INTEG, S_IDLE, S_ID, S_RTR, S_IDE, S_R0, S_DLC, S_DATA, S_CRC, S_CRC_DELIM,
        S_ACK, S_ACK_DELIM, S_EOF, S_IFS, S_ERR_FLAG, S_ERR_DELIM, S_BUS_OFF
    } state_e;

    localparam logic [4:0] E_BIT = 5'b00001, E_STUFF = 5'b00010, E_CRC = 5'b00100,
                           E_FORM = 5'b01000, E_ACK = 5'b10000;

    state_e      state;
    logic [6:0]  bitcnt;      // bit index within the current field
    logic [2:0]  scnt;        // equal bits in a row (stuffing)
    logic        slast;       // value of the last bit (stuffing)
    logic        stuff_on;    // inside SOF..CRC sequence (+ a stuff bit after it)
    logic [14:0] crc, rx_crc;
    logic        crc_ok;
    logic [63:0] rx_sh;       // data bits, shifted in LSB first
    logic [3:0]  rcnt;        // recessive bits in a row (integration, bus-off recovery)
    logic [6:0]  boff_cnt;    // 11-recessive-bit sequences seen while bus-off
    logic        pass_flag;   // the error flag being sent is passive (recessive)

    // ---------------- combinational helpers ----------------
    wire stuff_bit = stuff_on && scnt == 3'd5;  // this bit must be a stuff bit
    // data bits in this frame, from the DLC being received (bit 3 arrives last)
    function automatic logic [6:0] ndata(input logic [3:0] d, input logic rtr);
        logic [3:0] n;
        n = (d > 4'd8) ? 4'd8 : d;
        ndata = rtr ? 7'd0 : {n, 3'b000};
    endfunction

    // CRC-15/CAN, one bit
    function automatic logic [14:0] crc_step(input logic [14:0] c, input logic b);
        logic [14:0] s;
        s = {c[13:0], 1'b0};
        crc_step = (b ^ c[14]) ? (s ^ 15'h4599) : s;
    endfunction

    wire fixed_form = !stuff_bit && (state == S_CRC_DELIM || state == S_ACK_DELIM || state == S_EOF);
    wire is_arb    = state == S_ID || state == S_RTR;
    wire start_tx  = tx_point && state == S_IDLE && tx_req && !transmitting && enable;

    // next bit this node drives, valid at tx_point (state already points at it)
    logic nb;
    always_comb begin
        nb = 1'b1;
        if (state == S_ERR_FLAG)
            nb = pass_flag;
        else if (state == S_ACK && !transmitting)
            nb = !crc_ok;                       // receiver ACKs a good CRC
        else if (transmitting) begin
            if (stuff_bit)
                nb = !slast;
            else case (state)
                S_ID:    nb = tx_id[4'd10 - bitcnt[3:0]];
                S_RTR:   nb = tx_rtr;
                S_IDE,
                S_R0:    nb = 1'b0;
                S_DLC:   nb = tx_dlc[2'd3 - bitcnt[1:0]];
                S_DATA:  nb = tx_data[6'd63 - bitcnt[5:0]];
                S_CRC:   nb = crc[4'd14 - bitcnt[3:0]];
                default: nb = 1'b1;
            endcase
        end
    end

    assign hard_sync_en = state == S_IDLE;
    assign busy         = !(state == S_IDLE || state == S_INTEG || state == S_BUS_OFF);
    assign bus_off      = tec[8];
    assign err_passive  = !bus_off && (tec >= 9'd128 || rec >= 8'd128);

    // ---------------- error detection at the sample point ----------------
    logic [4:0] det;   // error found on this bit (one-hot, priority below)
    always_comb begin
        det = '0;
        if (sample && busy && state != S_ERR_FLAG && state != S_ERR_DELIM) begin
            // fixed-form fields: a dominant bit is a form error, also for the transmitter
            if (transmitting && can_tx != rxb && !(is_arb && !stuff_bit && can_tx && !rxb)
                && !(state == S_ACK && !stuff_bit) && !fixed_form)
                det = E_BIT;
            else if (stuff_bit && rxb == slast)
                det = E_STUFF;
            else if (!stuff_bit && ((!rxb && (state == S_CRC_DELIM || state == S_ACK_DELIM ||
                                              state == S_EOF)) || (rxb && state == S_IDE)))
                det = E_FORM;
            else if (!stuff_bit && state == S_ACK && transmitting && rxb)
                det = E_ACK;
            else if (state == S_ACK_DELIM && !transmitting && !crc_ok)
                det = E_CRC;
        end
    end

    // counters after this error (computed here so bus-off is known in the same cycle)
    wire       tx_err   = transmitting;
    wire [8:0] tec_err  = (det == E_ACK && err_passive) ? tec : tec + 9'd8;
    wire       to_boff  = tx_err && tec_err[8];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_INTEG;
            bitcnt <= '0; scnt <= '0; slast <= 1'b1; stuff_on <= 1'b0;
            crc <= '0; rx_crc <= '0; crc_ok <= 1'b0; rx_sh <= '0;
            rx_id <= '0; rx_rtr <= 1'b0; rx_dlc <= '0; rx_data <= '0;
            rcnt <= '0; boff_cnt <= '0; pass_flag <= 1'b0;
            tec <= '0; rec <= '0;
            can_tx <= 1'b1; transmitting <= 1'b0;
            tx_done <= 1'b0; arb_lost <= 1'b0; rx_valid <= 1'b0; err <= 1'b0; err_type <= '0;
        end else begin
            tx_done <= 1'b0; arb_lost <= 1'b0; rx_valid <= 1'b0; err <= 1'b0;

            if (!enable) begin
                // INIT mode: off the bus. Counters keep their value (as SJA1000 reset mode).
                // A bus-off node stays bus-off: INIT does not skip the recovery sequence.
                if (state != S_BUS_OFF) state <= S_INTEG;
                rcnt <= '0; can_tx <= 1'b1; transmitting <= 1'b0;
                stuff_on <= 1'b0;
            end else begin
                // ---- drive ----
                if (tx_point) begin
                    if (start_tx) begin
                        can_tx       <= 1'b0;   // SOF
                        transmitting <= 1'b1;
                    end else
                        can_tx <= (state == S_BUS_OFF || state == S_INTEG) ? 1'b1 : nb;
                end

                // ---- receive ----
                if (sample) begin
                    if (det != '0) begin
                        err      <= 1'b1;
                        err_type <= det;
                        stuff_on <= 1'b0;
                        transmitting <= 1'b0;   // request stays pending: retransmit
                        bitcnt   <= '0;
                        if (tx_err) tec <= tec_err;
                        else if (rec != 8'hFF) rec <= rec + 8'd1;
                        if (to_boff) begin
                            // bus-off: release the bus now, not at the next bit
                            state <= S_BUS_OFF; rcnt <= '0; boff_cnt <= '0; can_tx <= 1'b1;
                        end else begin
                            state     <= S_ERR_FLAG;
                            // flag type from the counters after this error
                            pass_flag <= tx_err ? (tec_err >= 9'd128 || rec >= 8'd128)
                                                : (tec >= 9'd128 || rec >= 8'd127);
                        end
                    end else if (stuff_bit) begin
                        // a correct stuff bit: not data, restarts the run
                        scnt  <= 3'd1;
                        slast <= rxb;
                    end else begin
                        if (stuff_on) begin
                            scnt  <= (rxb == slast) ? scnt + 3'd1 : 3'd1;
                            slast <= rxb;
                        end
                        if (transmitting && is_arb && can_tx && !rxb) begin
                            transmitting <= 1'b0;   // lost arbitration: keep receiving
                            arb_lost     <= 1'b1;
                        end
                        bitcnt <= bitcnt + 7'd1;
                        case (state)
                            S_INTEG: begin
                                // bus integration: 11 recessive bits before taking part
                                rcnt <= rxb ? rcnt + 4'd1 : 4'd0;
                                if (rxb && rcnt == 4'd10) state <= S_IDLE;
                            end
                            S_IDLE, S_IFS: begin
                                // dominant while idle or in intermission = SOF
                                // (shortcut: no overload frames, see README)
                                if (rxb) transmitting <= 1'b0;   // our SOF never showed: retry
                                if (!rxb) begin
                                    // another node's SOF came first (bit phases differ by a few
                                    // clocks): with a request pending, take part in arbitration
                                    // from ID[10] instead of becoming a receiver (ISO 11898-1
                                    // rule for the 3rd intermission bit, also used in bus idle)
                                    if (tx_req) transmitting <= 1'b1;
                                    state <= S_ID; bitcnt <= '0;
                                    stuff_on <= 1'b1; scnt <= 3'd1; slast <= 1'b0;
                                    crc <= '0;      // crc_step('0, 0) == 0
                                end else if (state == S_IFS && bitcnt == 7'd2)
                                    state <= S_IDLE;
                            end
                            S_ID: begin
                                crc   <= crc_step(crc, rxb);
                                rx_id <= {rx_id[9:0], rxb};
                                if (bitcnt == 7'd10) state <= S_RTR;
                            end
                            S_RTR: begin
                                crc <= crc_step(crc, rxb); rx_rtr <= rxb; state <= S_IDE;
                            end
                            S_IDE: begin
                                crc <= crc_step(crc, rxb); state <= S_R0;  // rxb == 0 here
                            end
                            S_R0: begin
                                crc <= crc_step(crc, rxb); state <= S_DLC; bitcnt <= '0;
                            end
                            S_DLC: begin
                                crc    <= crc_step(crc, rxb);
                                rx_dlc <= {rx_dlc[2:0], rxb};
                                if (bitcnt == 7'd3) begin
                                    bitcnt <= '0;
                                    state  <= (ndata({rx_dlc[2:0], rxb}, rx_rtr) == 7'd0) ? S_CRC : S_DATA;
                                end
                            end
                            S_DATA: begin
                                crc   <= crc_step(crc, rxb);
                                rx_sh <= {rx_sh[62:0], rxb};
                                if (bitcnt == ndata(rx_dlc, rx_rtr) - 7'd1) begin
                                    bitcnt <= '0; state <= S_CRC;
                                end
                            end
                            S_CRC: begin
                                rx_crc <= {rx_crc[13:0], rxb};
                                if (bitcnt == 7'd14) state <= S_CRC_DELIM;
                            end
                            S_CRC_DELIM: begin
                                stuff_on <= 1'b0;
                                crc_ok   <= (rx_crc == crc);
                                state    <= S_ACK;
                            end
                            S_ACK:       state <= S_ACK_DELIM;
                            S_ACK_DELIM: begin state <= S_EOF; bitcnt <= '0; end
                            S_EOF: if (bitcnt == 7'd6) begin
                                // shortcut: TX and RX both accept at the end of EOF
                                // (spec: RX at the 6th EOF bit), see README
                                state <= S_IFS; bitcnt <= '0;
                                if (transmitting) begin
                                    tx_done      <= 1'b1;
                                    transmitting <= 1'b0;
                                    if (tec != 9'd0) tec <= tec - 9'd1;
                                end else begin
                                    rx_valid <= 1'b1;
                                    rx_data  <= rx_sh << (7'd64 - ndata(rx_dlc, rx_rtr));
                                    if (rec > 8'd127) rec <= 8'd127;
                                    else if (rec != 8'd0) rec <= rec - 8'd1;
                                end
                            end
                            S_ERR_FLAG: if (bitcnt == 7'd5) begin state <= S_ERR_DELIM; bitcnt <= '0; end
                            S_ERR_DELIM: begin
                                // other nodes' flags may follow ours: wait for 8 recessive bits
                                if (!rxb) bitcnt <= '0;
                                else if (bitcnt == 7'd7) begin state <= S_IFS; bitcnt <= '0; end
                            end
                            S_BUS_OFF: begin
                                rcnt <= rxb ? ((rcnt == 4'd10) ? 4'd0 : rcnt + 4'd1) : 4'd0;
                                if (rxb && rcnt == 4'd10) begin
                                    boff_cnt <= boff_cnt + 7'd1;
                                    if (boff_cnt == 7'd127) begin
                                        state <= S_IDLE; tec <= '0; rec <= '0;
                                    end
                                end
                            end
                            default: state <= S_INTEG;
                        endcase
                    end
                end
            end
        end
    end
endmodule
