/* can_hal.h : register access the driver needs from the platform.
 * On a real SoC these are volatile loads/stores at the controller's base
 * address; in co-simulation sim/drv_main.cpp drives the APB pins of the RTL. */
#ifndef CAN_HAL_H
#define CAN_HAL_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

uint32_t hal_rd(int node, uint32_t off);
void     hal_wr(int node, uint32_t off, uint32_t val);
void     hal_wait(uint32_t clocks);   /* let time pass (busy-wait on hardware) */

#ifdef __cplusplus
}
#endif
#endif
