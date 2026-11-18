// drv_main.cpp : Verilator harness. Implements the driver's HAL (driver/can_hal.h)
// by driving the APB pins of sim/can_sys.sv, then runs drv_test().
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include "Vcan_sys.h"
#include "verilated.h"
#include "can_drv.h"
#include "can_hal.h"

static std::unique_ptr<Vcan_sys> top;
static uint64_t cycles;

static void tick() {
    top->clk = 0; top->eval();
    top->clk = 1; top->eval();
    cycles++;
}

extern "C" void hal_wait(uint32_t n) { while (n--) tick(); }

// APB3: SETUP cycle, then ACCESS cycle (PREADY is always 1 in can_ctrl)
static uint32_t apb(int node, uint32_t off, bool write, uint32_t val) {
    top->psel = 1; top->penable = 0; top->pwrite = write;
    top->paddr = (uint32_t)(node << 12) | (off & 0xFFF); top->pwdata = val;
    tick();
    top->penable = 1;
    top->clk = 0; top->eval();
    uint32_t r = top->prdata;   // read data is valid during ACCESS
    tick();
    top->psel = 0; top->penable = 0; top->pwrite = 0;
    return r;
}

extern "C" uint32_t hal_rd(int node, uint32_t off) { return apb(node, off, false, 0); }
extern "C" void hal_wr(int node, uint32_t off, uint32_t v) { apb(node, off, true, v); }

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    top.reset(new Vcan_sys);
    top->rst_n = 0;
    hal_wait(5);
    top->rst_n = 1;
    hal_wait(2);
    int rc = drv_test(argc > 1 ? argv[1] : "vectors/frames.txt");
    std::printf("cycles: %llu\n", (unsigned long long)cycles);
    top->final();
    top.reset();   // before static teardown of the Verilated context
    return rc;
}
