/* can_drv.h : bare-metal driver for the can_ctrl CAN 2.0A controller
 * (register map: rtl/can_ctrl.sv). Polling only, no OS. */
#ifndef CAN_DRV_H
#define CAN_DRV_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

enum {
    CAN_CTRL = 0x00, CAN_BTR = 0x04, CAN_CMD = 0x08, CAN_STATUS = 0x0C,
    CAN_IRQ = 0x10, CAN_IRQ_EN = 0x14, CAN_ERRCNT = 0x18, CAN_ERRFLAGS = 0x1C,
    CAN_TXID = 0x20, CAN_TXDLC = 0x24, CAN_TXD0 = 0x28, CAN_TXD1 = 0x2C,
    CAN_RXID = 0x30, CAN_RXDLC = 0x34, CAN_RXD0 = 0x38, CAN_RXD1 = 0x3C
};
enum { CAN_IRQ_TX_DONE = 0x01, CAN_IRQ_RX = 0x02, CAN_IRQ_ERR = 0x04 };

typedef struct {
    uint16_t id;      /* 11-bit identifier */
    uint8_t  rtr;     /* 1 = remote frame */
    uint8_t  dlc;     /* 0..15 (more than 8 still carries 8 bytes) */
    uint8_t  data[8];
} can_msg_t;

void can_init(int node, uint32_t btr);                 /* INIT, bit timing, join the bus */
int  can_send(int node, const can_msg_t *m);           /* 0 ok, -1 a frame is still pending */
int  can_tx_done(int node);                            /* 1 once per finished frame */
int  can_recv(int node, can_msg_t *m);                 /* 1 if a frame was read from the FIFO */
void can_errcnt(int node, unsigned *tec, unsigned *rec);

/* co-simulation test entry (sim/drv_test.c) */
int drv_test(const char *vectors_path);

#ifdef __cplusplus
}
#endif
#endif
