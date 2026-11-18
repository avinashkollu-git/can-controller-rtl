// can_frame.svh : a CAN frame, and the golden vectors (vectors/frames.txt,
// written by scripts/gen_vectors.py from the f1-telemetry-fault-hunter encoder).

class can_frame extends uvm_object;
    bit [10:0] id;
    bit        rtr;
    bit [3:0]  dlc;
    bit [7:0]  data [8];
    // golden (vectors) or captured (monitor)
    bit [14:0] crc;
    string     bits;          // stuffed SOF..CRC as '0'/'1'
    int        arb_end;       // index in bits of the first bit after RTR
    int        plan_k [3];    // receiver-side flip plans: bit index ...
    string     plan_t [3];    // ... and the error it must cause
    // monitor only
    bit        complete;      // reached the end of EOF without an error
    bit        acked;

    `uvm_object_utils(can_frame)
    function new(string name = "can_frame");
        super.new(name);
    endfunction

    function int nbytes();
        return rtr ? 0 : (dlc > 8 ? 8 : dlc);
    endfunction
    function string key();
        string s = $sformatf("%03h r%0d d%0d ", id, rtr, dlc);
        for (int i = 0; i < nbytes(); i++) s = {s, $sformatf("%02h", data[i])};
        return s;
    endfunction
    function bit same(can_frame o);
        return key() == o.key();
    endfunction
endclass

class vectors;
    static can_frame all [$];

    static function void load(string path);
        int fd, n;
        string id_s, data_s, crc_s, bits_s, t0, t1, t2;
        int rtr, dlc, ae, k0, k1, k2;
        if (all.size() != 0) return;
        fd = $fopen(path, "r");
        if (fd == 0) `uvm_fatal("VEC", {"cannot open ", path})
        while (!$feof(fd)) begin
            can_frame f;
            n = $fscanf(fd, "%s %d %d %s %s %d %s %d %s %d %s %d %s\n",
                        id_s, rtr, dlc, data_s, crc_s, ae, bits_s, k0, t0, k1, t1, k2, t2);
            if (n != 13) break;
            f = new("vec");
            f.id = 11'(id_s.atohex()); f.rtr = rtr[0]; f.dlc = dlc[3:0];
            f.crc = 15'(crc_s.atohex()); f.bits = bits_s; f.arb_end = ae;
            for (int i = 0; i < f.nbytes(); i++) f.data[i] = 8'(data_s.substr(2*i, 2*i+1).atohex());
            f.plan_k = '{k0, k1, k2};
            f.plan_t = '{t0, t1, t2};
            all.push_back(f);
        end
        $fclose(fd);
        `uvm_info("VEC", $sformatf("%0d golden frames from %s", all.size(), path), UVM_LOW)
    endfunction

    static function can_frame pick();
        return all[$urandom_range(all.size() - 1)];
    endfunction

    static function can_frame find(can_frame f);
        foreach (all[i]) if (all[i].same(f)) return all[i];
        return null;
    endfunction
endclass
