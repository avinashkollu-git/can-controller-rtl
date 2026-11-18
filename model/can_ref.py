"""Golden CAN 2.0A reference model.

crc15, bytes_to_bits and frame_bits are copied unchanged from
f1-telemetry-fault-hunter (fh/can.py, commit aa6b394), the Python encoder
that wrote that project's bus log and whose CRCs its C++ decoder checks.
Everything below the line is new here: RTR, bit stuffing, and a reference
receiver that predicts which error a corrupted bit stream produces.
"""

CRC15_POLY = 0x4599  # x^15 + x^14 + x^10 + x^8 + x^7 + x^4 + x^3 + 1 (Bosch CAN spec)


def crc15(bits):
    """Bitwise CRC-15/CAN over a sequence of 0/1 ints (init 0, no final XOR)."""
    crc = 0
    for b in bits:
        crc_next = b ^ ((crc >> 14) & 1)
        crc = (crc << 1) & 0x7FFF
        if crc_next:
            crc ^= CRC15_POLY
    return crc


def bytes_to_bits(data):
    return [(byte >> (7 - i)) & 1 for byte in data for i in range(8)]


def frame_bits(can_id, dlc, data):
    """Bits covered by the CRC in a CAN 2.0A data frame, before bit stuffing:
    SOF(0), 11-bit ID, RTR(0), IDE(0), r0(0), 4-bit DLC, data bytes. MSB first."""
    bits = [0]
    bits += [(can_id >> (10 - i)) & 1 for i in range(11)]
    bits += [0, 0, 0]
    bits += [(dlc >> (3 - i)) & 1 for i in range(4)]
    bits += bytes_to_bits(data[:dlc])
    return bits

# ---------------------------------------------------------------------------


def frame_bits_rtr(can_id, dlc, data, rtr=0):
    """frame_bits() plus remote frames: RTR recessive, no data field."""
    if not rtr:
        return frame_bits(can_id, dlc, data)
    bits = frame_bits(can_id, dlc, b"")
    bits[12] = 1
    return bits


def stuff(bits):
    """Insert a complement bit after every 5 equal bits (stuff bits count too)."""
    out, run, last = [], 0, None
    for b in bits:
        out.append(b)
        run = run + 1 if b == last else 1
        last = b
        if run == 5:
            out.append(1 - b)
            run, last = 1, 1 - b
    return out


def wire_bits(can_id, dlc, data, rtr=0):
    """Stuffed SOF..CRC sequence as it appears on the bus (no CRC delimiter)."""
    pre = frame_bits_rtr(can_id, dlc, data, rtr)
    crc = crc15(pre)
    return stuff(pre + [(crc >> (14 - i)) & 1 for i in range(15)]), crc


# what follows the stuffed region on a good frame: CRC delim, ACK (driven by the
# other receivers), ACK delim, 7 EOF bits, 3 IFS bits
TAIL = [1, 0, 1] + [1] * 10


def receive(wire):
    """Reference receiver. wire = stuffed bits from SOF, then the bits after them
    (normally TAIL). Returns ('ok' | 'stuff' | 'crc' | 'form' | 'short', index of
    the deciding bit). 'short' = the receiver would need bits beyond the end of wire.
    A CRC error is only flagged after the ACK delimiter (ISO 11898-1), so a dominant
    ACK delimiter is reported as a form error first."""
    raw, run, last = [], 0, None
    i = 0
    need = None   # unstuffed bits in SOF..CRC once the DLC is known
    while True:
        if i >= len(wire):
            return "short", i
        b = wire[i]
        if run == 5:                       # stuff bit expected
            if b == last:
                return "stuff", i
            run, last = 1, b
            i += 1
            continue
        if need is not None and len(raw) == need:
            # CRC delimiter
            if b == 0:
                return "form", i
            pre, rx = raw[:need - 15], raw[need - 15:]
            ok = crc15(pre) == int("".join(map(str, rx)), 2)
            if i + 2 >= len(wire):
                return "short", i
            if wire[i + 2] == 0:           # ACK delimiter (wire[i + 1] is the ACK slot)
                return "form", i + 2
            return ("ok" if ok else "crc"), i + 2
        raw.append(b)
        run = run + 1 if b == last else 1
        last = b
        i += 1
        if len(raw) == 15 and raw[13] == 1:
            return "form", i - 1           # IDE recessive: extended frames unsupported
        if len(raw) == 19:
            dlc = int("".join(map(str, raw[15:19])), 2)
            n = 0 if raw[12] else 8 * min(dlc, 8)
            need = 19 + n + 15


if __name__ == "__main__":
    # self-check: an uncorrupted frame decodes as ok, a known CRC from the f1 log matches
    w, c = wire_bits(0x0C0, 4, bytes.fromhex("0525C882"))
    assert c == 0x42EC, hex(c)
    assert receive(w + TAIL) == ("ok", len(w) + 2), receive(w + TAIL)
    # regression run bug: flipping bit 6 of this frame at a receiver was predicted
    # 'crc', but its view of the frame puts a dominant bit on the ACK delimiter
    w, _ = wire_bits(0x0C0, 4, bytes.fromhex("DA28C88B"))
    x = w + TAIL
    x[6] ^= 1
    assert receive(x)[0] == "form", receive(x)
    assert stuff([0] * 5) == [0, 0, 0, 0, 0, 1]
    print("can_ref self-check ok")
