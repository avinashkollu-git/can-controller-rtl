# can-controller-rtl

A CAN 2.0A (standard 11-bit ID) controller in SystemVerilog with an APB3 register
interface, verified with a UVM testbench on Verilator, driven by a small C driver
in co-simulation, and synthesized to SKY130 with Yosys + OpenSTA.

## Architecture

```
          APB3 ──► can_ctrl  (registers, TX buffer, 4-entry RX FIFO, IRQs)
                     │
                     ├── can_btl   bit timing: BRP prescaler, SYNC/PROP/PH1/PH2,
                     │             hard sync on SOF, resync with SJW
                     └── can_core  one bit-stream FSM for TX and RX: stuffing,
                                   CRC-15, arbitration, ACK, error detection
                                   (bit/stuff/CRC/form/ACK), error frames,
                                   TEC/REC, error-passive, bus-off + recovery
  can_rx ──► 2-flop synchroniser            can_tx ──► transceiver (0 = dominant)
```

Register map: header comment of [rtl/can_ctrl.sv](rtl/can_ctrl.sv).

## Verification

- **UVM testbench** ([tb/](tb/)): three controllers on one wired-AND bus, one APB
  agent per node, a passive bus monitor that decodes every frame on its own,
  a scoreboard that compares each frame bit for bit (stuff bits and CRC included)
  with golden vectors, and a fault injector (flip one bit at one node, or random
  bus noise).
- **Golden model** ([model/can_ref.py](model/can_ref.py)): CRC-15 and frame
  encoder, plus a reference receiver that predicts which error a corrupted bit
  causes. [scripts/gen_vectors.py](scripts/gen_vectors.py) writes 568 golden
  frames (525 from a synthetic F1-style CAN log, 43 edge cases: IDs 000/7FF/555/2AA,
  DLC 0..8 and 15, remote frames).
- **SVA** ([sva/can_sva.sv](sva/can_sva.sv)), bound to every `can_core`:
  stuffing, arbitration, TEC/REC steps, bus-off and passive flag behaviour,
  plus 14 cover properties.
- **Tests**: `regs_test`, `frames_test`, `arb_test` (2-3 nodes in the same bit),
  `rxerr_test` (predicted error type + exact TEC/REC model), `busoff_test`
  (error-passive, bus-off, 128x11-bit recovery), `noise_test`.

## Results (from runs on 2026-11-18, macOS, Verilator 5.050)

`make regress` (6 tests x 5 seeds, N=40):

| | |
|---|---|
| Runs passed | **30/30** |
| Frames checked bit for bit on the bus | 1240 |
| Frames read back from RX FIFOs and checked | 2475 |
| Arbitration rounds checked | 200 |
| Injected faults whose error type matched the model's prediction | 200/200 (rxerr_test) |
| Errors detected (bit / stuff / CRC / form / ACK) | 209 / 405 / 77 / 305 / 100 |
| Functional coverage (scoreboard bins) | 43/44 = 97.7% (missed: `btr tq_2`, the random bit timing never picked tq=2 clocks in these 5 seeds) |
| SVA cover properties hit | 14/14 |
| RTL line coverage (Verilator) | 188/196 = 95.9% |

`make driver`: 60 golden frames sent between two nodes by the C driver,
60/60 received and matched, TEC/REC 0 on both nodes, `DRIVER: PASS`.

`make synth` (Yosys 0.67, SKY130 HD TT 25C 1.8V, OpenSTA, no placement, "Small" wire load):

| | |
|---|---|
| Generic cells (Yosys `synth`) | 3284 |
| SKY130 HD cells | 2836 (724 flip-flops) |
| Area | 31899 um^2 |
| Setup WNS at 10 ns | +1.230 ns |
| Fmax | 123.4 MHz |

The critical path is the APB read mux (`paddr` -> `prdata`), with 30% of the
period reserved for input and output delay each.

## Run it

Needs Verilator >= 5.050, z3, Python 3, Yosys; OpenSTA optional (`~/tools/OpenSTA/build2/sta`
or `sta` on PATH). UVM (chipsalliance uvm-verilator) and the SKY130 liberty are
downloaded on first use into `third_party/`.

```
make lint       # verilator -Wall on the RTL
make regress    # results/regress/summary.md, coverage.md, junit.xml
make sim TEST=arb_test SEED=3     # one test with waves
make driver     # C driver on the RTL
make synth      # build/synth/summary.md
```

Everything runs at `nice -n 10`, one job at a time, with a `COOL` pause after builds.
CI ([.github/workflows/ci.yml](.github/workflows/ci.yml)) runs lint, a short regression
(2 seeds, N=10) and the driver test on Ubuntu.

## Bug log (found while bringing the project up)

| # | Where | Bug | Fix |
|---|---|---|---|
| 1 | TB / Verilator 5.050 | `wait_irq` polled IRQ in `forever ... break`; after the `break`, the value `rd()` had written into the local `d` read back as 0, so the W1C clear wrote 0 and interrupts were never cleared. The next `send` saw a stale TX_DONE. | Rewrote the poll as a `while` loop. |
| 2 | TB | `rxerr_test` turned the injector off one clock after it started, so the flipped bit lasted 1 clock and was never sampled. No error was ever injected. | Keep it on to the end of the bit cell. |
| 3 | Golden model | `can_ref.receive()` predicted "CRC error" at the CRC delimiter. A CRC error is only flagged after the ACK delimiter; when the corrupted view puts a dominant bit on the ACK delimiter, the RTL (correctly) reports a form error. Before the fix, 183 of 200 rounds matched the prediction. | Model now looks at the ACK delimiter; vectors regenerated. |
| 4 | Golden model | Some fault plans made the receiver's error flag start inside the ID field. The transmitter then loses arbitration (spec behaviour) instead of seeing a bit error, so the test's TEC/REC model was wrong. | Plans only use flips whose error flag starts after RTR. |
| 5 | RTL (`can_core`) | Nodes' bit phases differ by a few clocks (synchroniser delay). When two nodes requested in the same bit, the later one hard-synced on the other's SOF and became a receiver, so it sent after the winner instead of arbitrating: bus order was wrong in `arb_test`. | A node with a pending request that samples SOF while idle (or in intermission) now joins arbitration from ID[10], as ISO 11898-1 specifies for the 3rd intermission bit. |
| 6 | TB | `regs_test` cleared the scoreboard's expected frame before the monitor had reported the aborted attempt. | Wait 20 bit times first. |
| 7 | TB | `busoff_test` could flip the last dominant bit of a frame. The transmitter (now error-passive) sends a recessive flag over recessive bits, the receivers accept the frame, and it is delivered again on retry. Legal CAN, but the scoreboard does not allow duplicates. | Flip only bits followed by a dominant bit. |
| 8 | TB | `rxerr_test` adds +7 TEC to the transmitter per round; once its TEC reached 128 a node became error-passive, its CRC-error flag was recessive and it missed a frame the others accepted (legal). | Send clean frames to keep TEC <= 96. |
| 9 | RTL / Yosys | Yosys 0.67 could not parse `return` in the RTL functions. | Assign to the function name instead. |

## Limits (honest)

- CAN 2.0A only: extended (29-bit) frames are rejected with a form error; no CAN FD.
- No overload frames; a dominant bit in intermission is treated as SOF.
- Receivers and the transmitter both accept a frame at the end of EOF (the spec says
  receivers accept at the 6th EOF bit).
- Fault confinement is simplified: no "+8 REC for a dominant bit after the error flag"
  and the other special cases of ISO 11898-1.
- Resync measures the phase error in whole time quanta, not clock cycles.
- No acceptance filters, single TX buffer, 4-deep RX FIFO, polling-only driver.
- Coverage is a scoreboard bin table (Verilator does not collect covergroups); SVA
  cover counts are per clock, not per event.
- Synthesis is pre-placement (no clock tree, statistical wire load); Fmax is an estimate.
- The C driver test uses only two nodes on an error-free bus.
- Not tested in hardware or against a commercial CAN controller.
