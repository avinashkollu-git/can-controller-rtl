/* drv_test.c : the C driver on the RTL. Sends golden frames from
 * vectors/frames.txt between two nodes, alternating direction, and checks
 * every received frame field by field plus the error counters. */
#include <stdio.h>
#include <string.h>
#include "can_drv.h"
#include "can_hal.h"

#define NFRAMES 60
#define TIMEOUT 200000u   /* polls */

static int hexbyte(const char *s) {
    unsigned v;
    return sscanf(s, "%2x", &v) == 1 ? (int)v : -1;
}

int drv_test(const char *path) {
    FILE *f = fopen(path, "r");
    if (!f) { printf("DRIVER: FAIL cannot open %s\n", path); return 1; }
    can_init(0, 0x00012101);   /* reset BTR: 2 clk/tq, 8 tq/bit */
    can_init(1, 0x00012101);
    int sent = 0, ok = 0, bad = 0;
    char line[512], data[64];
    while (sent < NFRAMES && fgets(line, sizeof line, f)) {
        unsigned id, rtr, dlc;
        can_msg_t m, r;
        if (sscanf(line, "%x %u %u %63s", &id, &rtr, &dlc, data) != 4) continue;
        memset(&m, 0, sizeof m);
        m.id = (uint16_t)id; m.rtr = (uint8_t)rtr; m.dlc = (uint8_t)dlc;
        int n = rtr ? 0 : (dlc > 8 ? 8 : (int)dlc);
        for (int i = 0; i < n; i++) m.data[i] = (uint8_t)hexbyte(data + 2 * i);
        int tx = sent & 1, rx = !tx;
        unsigned t = 0;
        while (can_send(tx, &m) != 0 && t++ < TIMEOUT) hal_wait(16);
        t = 0;
        while (!can_tx_done(tx) && t++ < TIMEOUT) hal_wait(16);
        t = 0;
        while (!can_recv(rx, &r) && t++ < TIMEOUT) hal_wait(16);
        sent++;
        int same = t < TIMEOUT && r.id == m.id && r.rtr == m.rtr && r.dlc == m.dlc &&
                   memcmp(r.data, m.data, (size_t)n) == 0;
        if (same) ok++;
        else {
            bad++;
            printf("mismatch frame %d: sent %03X dlc %u, got %03X dlc %u\n", sent, m.id, m.dlc, r.id, r.dlc);
        }
    }
    fclose(f);
    unsigned tec[2], rec[2];
    can_errcnt(0, &tec[0], &rec[0]);
    can_errcnt(1, &tec[1], &rec[1]);
    printf("frames sent %d, received and matched %d, mismatched %d; TEC/REC node0 %u/%u node1 %u/%u\n",
           sent, ok, bad, tec[0], rec[0], tec[1], rec[1]);
    int pass = sent == NFRAMES && ok == sent && !tec[0] && !rec[0] && !tec[1] && !rec[1];
    printf("DRIVER: %s\n", pass ? "PASS" : "FAIL");
    return pass ? 0 : 1;
}
