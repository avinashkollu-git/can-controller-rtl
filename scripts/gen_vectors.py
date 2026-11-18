#!/usr/bin/env python3
"""Write vectors/frames.txt: golden frames for the testbench and the C driver test.

Sources:
  vectors/f1_can_log_sample.txt  every 300th frame of the f1-telemetry-fault-hunter
                                 synthetic bus log (seed 42); frames whose logged CRC
                                 does not match (that log injects corrupted frames) are dropped
  edge cases                     IDs 000/7FF/555/2AA, DLC 0..8 and 15, all-0/all-1 data
                                 (most stuff bits), remote frames

One line per frame:
  ID RTR DLC DATA CRC ARB_END BITS k1 t1 k2 t2 k3 t3
  DATA     hex bytes, "-" if none
  ARB_END  index (in BITS) of the first bit after RTR: the end of arbitration
  BITS     stuffed SOF..CRC sequence as it must appear on the bus
  k/t      receiver-side bit-flip plans: flipping wire bit k at one receiver must make
           that receiver report error t (stuff/crc/form), as predicted by can_ref.receive
"""
import random, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "model"))
from can_ref import TAIL, crc15, frame_bits, frame_bits_rtr, receive, stuff, wire_bits  # noqa: E402


def arb_end(bits_pre):
    """Stuffed index of unstuffed bit 13 (IDE)."""
    return len(stuff(bits_pre[:13]))


def plans(w, ae, rng):
    """Flips whose error flag starts after arbitration (the flag starts on the bit after
    the deciding bit i). A flag inside ID/RTR overwrites a recessive bit of the
    transmitter there, which is lost arbitration, not a bit error, per ISO 11898-1."""
    out = []
    cands = list(range(1, len(w) + 1))   # len(w) is the CRC delimiter
    rng.shuffle(cands)
    for k in cands:
        x = w + TAIL   # what the receiver sees: the real frame, with bit k flipped
        x[k] ^= 1
        t, i = receive(x)
        if t in ("stuff", "crc", "form") and i + 1 >= ae:
            out.append((k, t))
        if len(out) == 3:
            break
    return out


def main():
    rng = random.Random(1)
    frames, dropped = [], 0
    for ln in open(ROOT / "vectors/f1_can_log_sample.txt"):
        _, id_, dlc, data, crc = ln.split()
        id_, dlc, data, crc = int(id_, 16), int(dlc), bytes.fromhex(data), int(crc, 16)
        if crc15(frame_bits(id_, dlc, data)) != crc:
            dropped += 1
            continue
        frames.append((id_, 0, dlc, data))
    n_f1 = len(frames)
    for id_ in (0x000, 0x7FF, 0x555, 0x2AA):
        for dlc in list(range(9)) + [15]:
            fill = {0x000: 0x00, 0x7FF: 0xFF, 0x555: 0x55}.get(id_, 0xA5)
            frames.append((id_, 0, dlc, bytes([fill] * min(dlc, 8))))
    for id_ in (0x123, 0x7FF, 0x000):
        frames.append((id_, 1, 4, b""))
    with open(ROOT / "vectors/frames.txt", "w") as f:
        for id_, rtr, dlc, data in frames:
            w, crc = wire_bits(id_, dlc, data, rtr)
            pre = frame_bits_rtr(id_, dlc, data, rtr)
            assert receive(w + TAIL) == ("ok", len(w) + 2)
            p = plans(w, arb_end(pre), rng)
            assert len(p) == 3
            f.write(f"{id_:03X} {rtr} {dlc} {data.hex().upper() or '-'} {crc:04X} {arb_end(pre)} "
                    f"{''.join(map(str, w))} " + " ".join(f"{k} {t}" for k, t in p) + "\n")
    print(f"vectors/frames.txt: {len(frames)} frames ({n_f1} from the f1 log, {dropped} bad-CRC "
          f"log frames dropped, {len(frames) - n_f1} edge cases)")


if __name__ == "__main__":
    main()
