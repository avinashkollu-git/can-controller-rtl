// can_monitor.svh : passive bus monitor. Decodes every frame on the wire on
// its own (destuffing, field lengths from the DLC), with no help from the DUT,
// and sends one can_frame per SOF to the scoreboard.
//
// Timing: samples each bit at clock `samp` after the bit starts; every falling
// edge restarts the bit (all nodes run on one clock, so this is exact).
// An SOF is a falling edge after at least 10 recessive bit times.

class can_monitor extends uvm_monitor;
    `uvm_component_utils(can_monitor)
    virtual can_tb_if vif;
    uvm_analysis_port #(can_frame) ap;
    int unsigned bit_clks = 16, samp = 10;

    function new(string name, uvm_component parent);
        super.new(name, parent);
        ap = new("ap", this);
    endfunction

    task run_phase(uvm_phase phase);
        int unsigned rc = 0;
        forever begin
            @(posedge vif.clk);
            if (!vif.rst_n || vif.bus) begin
                rc = vif.rst_n ? rc + 1 : 0;
                continue;
            end
            if (rc >= 10 * bit_clks) begin
                bit ok;
                capture(ok);
                // after a good EOF the bus has already been recessive long enough
                rc = ok ? 10 * bit_clks : 0;
            end else
                rc = 0;
        end
    endtask

    // called on the SOF clock; returns after EOF or at the first error
    task capture(output bit ok);
        can_frame f = can_frame::type_id::create("mon");
        bit raw [$];
        int c = 0, run = 0, need = -1, tail = -1;
        bit last = 1, prev = 0, b;
        ok = 0;
        forever begin
            if (c == samp) begin
                b = vif.bus;
                if (tail < 0) begin                       // stuffed region
                    if (run == 5) begin
                        if (b == last) break;             // stuff violation: error flag
                        f.bits = {f.bits, b ? "1" : "0"};
                        run = 1; last = b;
                    end else if (need >= 0 && raw.size() == need) begin
                        tail = 0;                         // this is the CRC delimiter
                    end else begin
                        f.bits = {f.bits, b ? "1" : "0"};
                        raw.push_back(b);
                        run = (b == last) ? run + 1 : 1;
                        last = b;
                        if (raw.size() == 19) begin
                            int dlc = {raw[15], raw[16], raw[17], raw[18]};
                            need = 19 + (raw[12] ? 0 : 8 * (dlc > 8 ? 8 : dlc)) + 15;
                        end
                    end
                end
                if (tail >= 0) begin                      // fixed form
                    if (tail == 1) f.acked = !b;
                    else if (!b) break;                   // form error
                    if (tail == 9) begin ok = 1; break; end
                    tail++;
                end
            end
            @(posedge vif.clk);
            c = (prev && !vif.bus) ? 0 : (c + 1 == bit_clks ? 0 : c + 1);
            prev = vif.bus;
        end
        f.complete = ok;
        if (raw.size() >= 19) begin
            for (int i = 0; i < 11; i++) f.id[10 - i] = raw[1 + i];
            f.rtr = raw[12];
            f.dlc = {raw[15], raw[16], raw[17], raw[18]};
            for (int i = 0; i < f.nbytes() * 8 && 19 + i < raw.size(); i++)
                f.data[i / 8][7 - i % 8] = raw[19 + i];
        end
        if (need >= 0 && raw.size() == need)
            for (int i = 0; i < 15; i++) f.crc[14 - i] = raw[need - 15 + i];
        `uvm_info("MON", $sformatf("%s %s crc=%04h ack=%0b bits=%s", ok ? "FRAME" : "ABORT",
                                   f.key(), f.crc, f.acked, f.bits), UVM_HIGH)
        ap.write(f);
    endtask
endclass
