// apb_agent.svh : APB3 master (driver + sequencer), from amba-uvm-vip.
// One agent per CAN node. Reads return their data in the same item.

// register offsets (rtl/can_ctrl.sv)
localparam bit [11:0] R_CTRL = 12'h00, R_BTR = 12'h04, R_CMD = 12'h08, R_STATUS = 12'h0C,
                      R_IRQ = 12'h10, R_IRQ_EN = 12'h14, R_ERRCNT = 12'h18, R_ERRFLAGS = 12'h1C,
                      R_TXID = 12'h20, R_TXDLC = 12'h24, R_TXD0 = 12'h28, R_TXD1 = 12'h2C,
                      R_RXID = 12'h30, R_RXDLC = 12'h34, R_RXD0 = 12'h38, R_RXD1 = 12'h3C;
// IRQ bits
localparam bit [7:0] I_TX_DONE = 8'h01, I_RX = 8'h02, I_ERR = 8'h04, I_ARB = 8'h08,
                     I_PASSIVE = 8'h10, I_BUS_OFF = 8'h20, I_OVERRUN = 8'h40, I_BUS_ON = 8'h80;

class apb_item extends uvm_sequence_item;
    bit        write;
    bit [11:0] addr;
    bit [31:0] data;
    `uvm_object_utils(apb_item)
    function new(string name = "apb_item");
        super.new(name);
    endfunction
endclass

typedef uvm_sequencer #(apb_item) apb_sequencer;

// one register access
class apb_rw_seq extends uvm_sequence #(apb_item);
    `uvm_object_utils(apb_rw_seq)
    bit        write;
    bit [11:0] addr;
    bit [31:0] data;
    function new(string name = "apb_rw_seq");
        super.new(name);
    endfunction
    task body();
        apb_item t = apb_item::type_id::create("t");
        t.write = write; t.addr = addr; t.data = data;
        start_item(t);
        finish_item(t);
        data = t.data;
    endtask
endclass

class apb_driver extends uvm_driver #(apb_item);
    `uvm_component_utils(apb_driver)
    virtual apb_if vif;
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    task tick();
        @(posedge vif.clk);
        #1;
    endtask

    task run_phase(uvm_phase phase);
        vif.psel = 0; vif.penable = 0; vif.pwrite = 0; vif.paddr = 0; vif.pwdata = 0;
        @(posedge vif.rst_n);
        tick();
        forever begin
            seq_item_port.get_next_item(req);
            vif.psel = 1; vif.penable = 0;                       // SETUP
            vif.paddr = req.addr; vif.pwrite = req.write; vif.pwdata = req.data;
            tick();
            vif.penable = 1;                                     // ACCESS until PREADY
            do @(negedge vif.clk); while (!vif.pready);
            if (!req.write) req.data = vif.prdata;
            tick();
            vif.psel = 0; vif.penable = 0;
            seq_item_port.item_done();
        end
    endtask
endclass

class apb_agent extends uvm_agent;
    `uvm_component_utils(apb_agent)
    apb_sequencer sqr;
    apb_driver    drv;
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction
    function void build_phase(uvm_phase phase);
        sqr = apb_sequencer::type_id::create("sqr", this);
        drv = apb_driver::type_id::create("drv", this);
    endfunction
    function void connect_phase(uvm_phase phase);
        drv.seq_item_port.connect(sqr.seq_item_export);
    endfunction
endclass
