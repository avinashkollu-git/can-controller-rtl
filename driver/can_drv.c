/* can_drv.c : see can_drv.h. */
#include "can_drv.h"
#include "can_hal.h"

static uint32_t pack(const uint8_t *b) {   /* byte 0 in bits [7:0] */
    return (uint32_t)b[0] | (uint32_t)b[1] << 8 | (uint32_t)b[2] << 16 | (uint32_t)b[3] << 24;
}

static void unpack(uint32_t w, uint8_t *b) {
    for (int i = 0; i < 4; i++) b[i] = (uint8_t)(w >> (8 * i));
}

void can_init(int node, uint32_t btr) {
    hal_wr(node, CAN_CTRL, 1);           /* INIT: BTR is only writable here */
    hal_wr(node, CAN_BTR, btr);
    hal_wr(node, CAN_IRQ, 0xFF);         /* W1C: clear everything */
    hal_wr(node, CAN_ERRFLAGS, 0x1F);
    hal_wr(node, CAN_CTRL, 0);           /* leave INIT: 11 recessive bits, then on the bus */
}

int can_send(int node, const can_msg_t *m) {
    if (hal_rd(node, CAN_STATUS) & 1u) return -1;   /* TX buffer locked while pending */
    hal_wr(node, CAN_TXID, (uint32_t)(m->id & 0x7FF) | (uint32_t)(m->rtr ? 1u << 11 : 0));
    hal_wr(node, CAN_TXDLC, m->dlc & 0xF);
    hal_wr(node, CAN_TXD0, pack(m->data));
    hal_wr(node, CAN_TXD1, pack(m->data + 4));
    hal_wr(node, CAN_CMD, 1);                       /* TX_REQ */
    return 0;
}

int can_tx_done(int node) {
    if (!(hal_rd(node, CAN_IRQ) & CAN_IRQ_TX_DONE)) return 0;
    hal_wr(node, CAN_IRQ, CAN_IRQ_TX_DONE);
    return 1;
}

int can_recv(int node, can_msg_t *m) {
    if (!(hal_rd(node, CAN_STATUS) & (1u << 3))) return 0;   /* RX FIFO empty */
    uint32_t id = hal_rd(node, CAN_RXID);
    m->id  = (uint16_t)(id & 0x7FF);
    m->rtr = (uint8_t)((id >> 11) & 1);
    m->dlc = (uint8_t)(hal_rd(node, CAN_RXDLC) & 0xF);
    unpack(hal_rd(node, CAN_RXD0), m->data);
    unpack(hal_rd(node, CAN_RXD1), m->data + 4);
    hal_wr(node, CAN_CMD, 4);                                  /* RX_POP */
    hal_wr(node, CAN_IRQ, CAN_IRQ_RX);
    return 1;
}

void can_errcnt(int node, unsigned *tec, unsigned *rec) {
    uint32_t v = hal_rd(node, CAN_ERRCNT);
    *tec = v & 0x1FF;
    *rec = (v >> 16) & 0xFF;
}
