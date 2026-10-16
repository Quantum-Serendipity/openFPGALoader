#!/usr/bin/env python3
import struct
import sys

SYNC = 0xAA995566
NOOP = 0x20000000
REG = {'CRC': 0, 'FAR': 1, 'FDRI': 2, 'CMD': 4, 'CTL0': 5, 'MASK': 6,
       'COR0': 9, 'IDCODE': 12, 'COR1': 14, 'WBSTAR': 16, 'TIMER': 17,
       'CTL1': 24}
CMD = {'NULL': 0, 'WCFG': 1, 'RCRC': 7, 'START': 5, 'GRESTORE': 10,
       'SHUTDOWN': 11, 'IPROG': 15, 'DESYNC': 13}


def w1(reg, *data):
    return [0x30000000 | (REG[reg] << 13) | len(data)] + list(data)


def stream(variant):
    words = [0xFFFFFFFF, 0x000000BB, 0x11220044, 0xFFFFFFFF, 0xFFFFFFFF]
    if variant != 'nosync':
        words += [SYNC]
    words += [NOOP]
    words += w1('CMD', CMD['RCRC']) + [NOOP]
    words += w1('IDCODE', 0x03631093)
    mask = 0x00001000 if variant == 'ctl0-bit12' else 0x00000400
    words += w1('MASK', mask) + w1('CTL0', mask)
    if variant == 'cor0':
        words += w1('COR0', 0x02003FE5)
    if variant == 'wbstar':
        words += w1('WBSTAR', 0x00000000)
    words += w1('FAR', 0x00000000)
    words += w1('CMD', CMD['WCFG']) + [NOOP]
    words += [0x30004000, 0x50000000 | 101] + [0] * 101
    for c in ('START', 'GRESTORE', 'SHUTDOWN', 'IPROG'):
        if variant == c.lower():
            words += w1('CMD', CMD[c]) + [NOOP]
    if variant == 'truncated':
        words += [0x30008002, CMD['DESYNC']]
        return words
    words += w1('CMD', CMD['DESYNC']) + [NOOP] * 16
    return words


def bit_header(nbytes):
    def field(t, v):
        return t + struct.pack('>H', len(v) + 1) + v + b'\0'
    return (struct.pack('>H', 9) + bytes([0x0f, 0xf0] * 4 + [0x00])
            + struct.pack('>H', 1) + field(b'a', b'fixture;UserID=0XFFFFFFFF')
            + field(b'b', b'7a100tfgg484') + field(b'c', b'2026/10/16')
            + field(b'd', b'00:00:00') + b'e' + struct.pack('>I', nbytes))


def pack(words):
    return struct.pack('>%dI' % len(words), *words)


def shifted(words, nbits):
    v = int.from_bytes(pack(words), 'big')
    total = 32 * len(words) + nbits
    total += -total % 32
    return (v << (total - 32 * len(words) - nbits)).to_bytes(total // 8, 'big')


def payload(variant):
    good = pack(stream('good'))
    decoy = [SYNC] + w1('CMD', CMD['IPROG']) + [NOOP] + w1('CMD', CMD['DESYNC'])
    if variant == 'unaligned-sync':
        return b'\xff' + pack(decoy) + b'\xff' * 3 + good
    if variant == 'unaligned-resync':
        return good + shifted(decoy, 3)
    if variant == 'two-syncs':
        return good + good
    return pack(stream(variant))


def main():
    variant, out = sys.argv[1], sys.argv[2]
    data = payload(variant)
    with open(out, 'wb') as f:
        if out.endswith('.bit'):
            f.write(bit_header(len(data)))
        f.write(data)


if __name__ == '__main__':
    main()
