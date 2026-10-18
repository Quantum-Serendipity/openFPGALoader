#!/usr/bin/env python3
import argparse
import signal
import socket
import sys

NEXT = {
    'TLR': ('RTI', 'TLR'),
    'RTI': ('RTI', 'SELDR'),
    'SELDR': ('CAPDR', 'SELIR'),
    'CAPDR': ('SHDR', 'EX1DR'),
    'SHDR': ('SHDR', 'EX1DR'),
    'EX1DR': ('PADR', 'UPDR'),
    'PADR': ('PADR', 'EX2DR'),
    'EX2DR': ('SHDR', 'UPDR'),
    'UPDR': ('RTI', 'SELDR'),
    'SELIR': ('CAPIR', 'TLR'),
    'CAPIR': ('SHIR', 'EX1IR'),
    'SHIR': ('SHIR', 'EX1IR'),
    'EX1IR': ('PAIR', 'UPIR'),
    'PAIR': ('PAIR', 'EX2IR'),
    'EX2IR': ('SHIR', 'UPIR'),
    'UPIR': ('RTI', 'SELDR'),
}

IR_LEN = 6
IR_CFG_OUT = 0x04
IR_CFG_IN = 0x05
IR_USER1 = 0x02
IR_IDCODE = 0x09

WORDS_PER_FRAME = 101
SYNC = 0xAA995566
REG_FAR = 1
REG_FDRO = 3
REG_CMD = 4
CMD_RCFG = 4
CMD_DESYNC = 13
DUMMY_WORD = 0xDEADBEEF

CLB_ROW0 = [42, 30, 36, 36, 36, 36, 28, 36, 36, 28, 36, 36, 36, 36, 36, 36,
            36, 36, 30, 36, 36, 36, 36, 36, 36, 36, 36, 36, 36, 36, 36, 30,
            36, 36, 36, 28, 36, 36, 28, 36, 36, 36, 36, 36, 28, 36, 36, 36,
            28, 36, 36, 28, 36, 36, 36, 36, 30, 42]
CLB_ROW1 = CLB_ROW0[:51] + [32]
GEOMETRY = {
    0x03631093: {
        (0, 0): CLB_ROW0, (0, 1): CLB_ROW1,
        (1, 0): [128] * 4, (1, 1): [128] * 3,
    },
}


def far_of(block, half, row, col, minor):
    return (block << 23) | (half << 22) | (row << 17) | (col << 7) | minor


def sweep(idcode):
    geo = GEOMETRY[idcode]
    out = []
    for block in (0, 1):
        for half in (0, 1):
            for row in (0, 1):
                group = []
                for col, n in enumerate(geo[(block, row)]):
                    group += [far_of(block, half, row, col, m)
                              for m in range(n)]
                out.append(group)
    return out


def slots(idcode, pads):
    s = []
    for group in sweep(idcode):
        s += group + [None] * pads
    return s


def frame_words(far):
    w = [far] * WORDS_PER_FRAME
    w[1] = far ^ 0xFFFFFFFF
    return w


def window(idcode, far, count):
    addrs = [a for g in sweep(idcode) for a in g]
    i = addrs.index(far)
    if i + count > len(addrs):
        raise ValueError('window runs past the device')
    return addrs[i:i + count]


class Tap:
    def __init__(self, idcode, stat, done, pads=2, pad_word=0, replay=None,
                 user1_byte=None):
        self.idcode = idcode
        self.user1_byte = user1_byte
        self.user1_bit = 0
        self.irs = []
        self.cfg_out_bits = 0
        self.stat = stat
        self.ir_capture = 0x01 | 0x10 | (0x20 if done else 0)
        self.state = 'TLR'
        self.ir = IR_IDCODE
        self.ir_sr = 0
        self.dr = []
        self.pads = pads
        self.pad_word = pad_word
        self.replay = replay
        self.in_bits = 0
        self.in_n = 0
        self.synced = False
        self.pending = None
        self.far = None
        self.rcfg = False
        self.fdro_words = 0
        self.t1_fdro = False

    def cfg_word(self, w):
        if not self.synced:
            self.synced = w == SYNC
            return
        if self.pending is not None:
            reg = self.pending
            self.pending = None
            if reg == REG_FAR:
                self.far = w
            elif reg == REG_CMD and w == CMD_RCFG:
                self.rcfg = True
            elif reg == REG_CMD and w == CMD_DESYNC:
                self.synced = False
                self.rcfg = False
                self.fdro_words = 0
            return
        typ, op = w >> 29, (w >> 27) & 3
        if typ == 1:
            reg, cnt = (w >> 13) & 0x3FFF, w & 0x7FF
            self.t1_fdro = op == 1 and reg == REG_FDRO
            if op == 2 and cnt == 1:
                self.pending = reg
            elif self.t1_fdro and cnt:
                self.fdro_words = cnt
        elif typ == 2 and op == 1 and self.t1_fdro:
            self.fdro_words = w & 0x07FFFFFF

    def fdro_stream(self):
        words = [DUMMY_WORD] * WORDS_PER_FRAME
        if self.replay is not None:
            words += self.replay
            words += [0] * max(0, self.fdro_words - len(words))
            return words[:self.fdro_words]
        s = slots(self.idcode, self.pads) if self.idcode in GEOMETRY else []
        try:
            i = s.index(self.far)
        except ValueError:
            i = len(s)
        while len(words) < self.fdro_words:
            a = s[i] if i < len(s) else None
            words += ([self.pad_word] * WORDS_PER_FRAME if a is None
                      else frame_words(a))
            i += 1
        return words[:self.fdro_words]

    def capture_dr(self):
        if self.ir == IR_IDCODE:
            self.dr = [(self.idcode >> i) & 1 for i in range(32)]
        elif self.ir == IR_CFG_OUT and self.rcfg and self.fdro_words:
            self.dr = [(w >> (31 - i)) & 1 for w in self.fdro_stream()
                       for i in range(32)]
            self.dr.reverse()
        elif self.ir == IR_CFG_OUT:
            self.dr = [(self.stat >> (31 - i)) & 1 for i in range(32)]
            self.dr.reverse()
        else:
            self.dr = [0]

    def clock(self, tms, tdi):
        st = self.state
        tdo = 0
        if st == 'SHIR':
            tdo = self.ir_sr & 1
            self.ir_sr = (self.ir_sr >> 1) | (tdi << (IR_LEN - 1))
        elif st == 'SHDR':
            if self.ir == IR_CFG_OUT:
                tdo = self.dr.pop() if self.dr else 0
                self.cfg_out_bits += 1
            elif self.ir == IR_USER1 and self.user1_byte is not None:
                tdo = (self.user1_byte >> (self.user1_bit & 7)) & 1
                self.user1_bit += 1
            elif self.ir == IR_CFG_IN:
                self.in_bits = ((self.in_bits << 1) | tdi) & 0xFFFFFFFF
                self.in_n += 1
                if self.in_n == 32:
                    self.cfg_word(self.in_bits)
                    self.in_n = 0
            else:
                tdo = self.dr.pop(0)
                self.dr.append(tdi)
        elif st == 'CAPIR':
            self.ir_sr = self.ir_capture
        elif st == 'CAPDR':
            self.in_n = 0
            self.user1_bit = 0
            self.capture_dr()
        elif st == 'UPIR':
            self.ir = self.ir_sr & ((1 << IR_LEN) - 1)
            self.irs.append(self.ir)
        nxt = NEXT[st][tms]
        if nxt == 'TLR':
            self.ir = IR_IDCODE
        self.state = nxt
        return tdo


class SimpleTap:
    def __init__(self, idcode, irlen):
        self.idcode = idcode
        self.irlen = irlen
        self.state = 'TLR'
        self.ir_sr = 0
        self.ir = None
        self.dr = []

    def clock(self, tms, tdi):
        st = self.state
        tdo = 0
        if st == 'SHIR':
            tdo = self.ir_sr & 1
            self.ir_sr = (self.ir_sr >> 1) | (tdi << (self.irlen - 1))
        elif st == 'SHDR':
            tdo = self.dr.pop(0)
            self.dr.append(tdi)
        elif st == 'CAPIR':
            self.ir_sr = 0x01
        elif st == 'CAPDR':
            if self.ir is None:
                self.dr = [(self.idcode >> i) & 1 for i in range(32)]
            else:
                self.dr = [0]
        elif st == 'UPIR':
            self.ir = self.ir_sr & ((1 << self.irlen) - 1)
        nxt = NEXT[st][tms]
        if nxt == 'TLR':
            self.ir = None
        self.state = nxt
        return tdo


class Chain:
    def __init__(self, fpga, tdo_side, tdi_side=()):
        self.fpga = fpga
        self.tdo_side = tdo_side
        self.tdi_side = tdi_side

    @property
    def cfg_out_bits(self):
        return self.fpga.cfg_out_bits

    @property
    def state(self):
        return self.fpga.state

    def clock(self, tms, tdi):
        for t in self.tdi_side:
            tdi = t.clock(tms, tdi)
        out = self.fpga.clock(tms, tdi)
        for t in self.tdo_side:
            out = t.clock(tms, out)
        return out


def recv_exact(conn, n):
    buf = b''
    while len(buf) < n:
        chunk = conn.recv(n - len(buf))
        if not chunk:
            raise EOFError
        buf += chunk
    return buf


def recv_command(conn):
    cmd = b''
    while not cmd.endswith(b':'):
        c = conn.recv(1)
        if not c:
            raise EOFError
        cmd += c
        if len(cmd) > 16:
            raise ValueError('bad command %r' % cmd)
    return cmd


def serve(conn, tap, short_shift=None, shifts=None, tlr_shifts=None):
    n_shift = 0
    muted = False

    def send(data):
        if not muted:
            conn.sendall(data)

    while True:
        try:
            cmd = recv_command(conn)
        except EOFError:
            return
        if cmd == b'getinfo:':
            send(b'xvcServer_v1.0:2048\n')
        elif cmd == b'settck:':
            send(recv_exact(conn, 4))
        elif cmd == b'shift:':
            nbits = int.from_bytes(recv_exact(conn, 4), 'little')
            nbytes = (nbits + 7) // 8
            tms = recv_exact(conn, nbytes)
            tdi = recv_exact(conn, nbytes)
            out = bytearray(nbytes)
            before = tap.cfg_out_bits
            for i in range(nbits):
                b = tap.clock((tms[i >> 3] >> (i & 7)) & 1,
                              (tdi[i >> 3] >> (i & 7)) & 1)
                out[i >> 3] |= b << (i & 7)
            n_shift += 1
            if shifts is not None and tap.cfg_out_bits != before:
                shifts.append(n_shift)
            if tlr_shifts is not None and tap.state == 'TLR':
                tlr_shifts.append(n_shift)
            if n_shift == short_shift:
                send(bytes(out[:nbytes // 2]))
                conn.shutdown(socket.SHUT_WR)
                muted = True
            send(bytes(out))
        else:
            raise ValueError('unknown command %r' % cmd)


def read_dump(path):
    frames = []
    with open(path) as f:
        for line in f:
            t = line.split()
            if not t:
                continue
            if t[0] == '.frame':
                frames.append((int(t[1], 16), []))
            else:
                frames[-1][1].extend(int(x, 16) for x in t)
    return frames


def check_dump(idcode, path, far, count):
    want = window(idcode, far, count)
    got = read_dump(path)
    errs = []
    if len(got) != len(want):
        errs.append('%d frames in the dump, %d wanted' % (len(got), len(want)))
    for k, (label, words) in enumerate(got):
        if k < len(want) and label != want[k]:
            errs.append('frame %d labelled 0x%08X, the sweep says 0x%08X'
                        % (k, label, want[k]))
        if words != frame_words(label):
            errs.append('frame %d labelled 0x%08X carries the content of '
                        '0x%08X' % (k, label, words[0] if words else 0))
    for e in errs[:8]:
        print('check-dump: ' + e)
    print('check-dump: %d frames, %d errors' % (len(got), len(errs)))
    return 1 if errs else 0


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--port-file')
    p.add_argument('--idcode', type=lambda s: int(s, 0), default=0x03631093)
    p.add_argument('--stat', type=lambda s: int(s, 0), default=0x401079FC)
    p.add_argument('--done-low', action='store_true')
    p.add_argument('--accept-timeout', type=float, default=60.0)
    p.add_argument('--pads', type=int, default=2)
    p.add_argument('--pad-word', type=lambda s: int(s, 0), default=0)
    p.add_argument('--far', type=lambda s: int(s, 0))
    p.add_argument('--count', type=int)
    p.add_argument('--write-far-list')
    p.add_argument('--check-dump')
    p.add_argument('--replay', nargs='+')
    p.add_argument('--compare-dump')
    p.add_argument('--expect', nargs='+')
    p.add_argument('--ir-log')
    p.add_argument('--user1-byte', type=lambda s: int(s, 0))
    p.add_argument('--short-shift', type=int)
    p.add_argument('--cfg-out-shift-log')
    p.add_argument('--tlr-shift-log')
    p.add_argument('--neighbour', action='append', default=[])
    p.add_argument('--neighbour-tdi', action='append', default=[])
    p.add_argument('--ir-capture', type=lambda s: int(s, 0))
    a = p.parse_args()
    if a.compare_dump:
        want = [f for x in a.expect for f in read_dump(x)]
        got = read_dump(a.compare_dump)
        same = got == want
        print('compare-dump: %d frames, %d expected, %s'
              % (len(got), len(want), 'identical' if same else 'DIFFERENT'))
        sys.exit(0 if same else 1)
    if a.write_far_list:
        with open(a.write_far_list, 'w') as f:
            for x in window(a.idcode, a.far, a.count):
                f.write('0x%08X\n' % x)
        return
    if a.check_dump:
        sys.exit(check_dump(a.idcode, a.check_dump, a.far, a.count))
    if not a.port_file:
        p.error('--port-file is required to serve')
    replay = None
    if a.replay:
        replay = [w for x in a.replay for _, ws in read_dump(x) for w in ws]
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.bind(('127.0.0.1', 0))
    srv.listen(1)
    srv.settimeout(a.accept_timeout)
    with open(a.port_file, 'w') as f:
        f.write('%d\n' % srv.getsockname()[1])
    try:
        conn, _ = srv.accept()
    except socket.timeout:
        sys.exit('xvc_tap_model: no connection')
    conn.settimeout(a.accept_timeout)
    tap = Tap(a.idcode, a.stat, not a.done_low, a.pads, a.pad_word, replay,
              a.user1_byte)
    if a.ir_capture is not None:
        tap.ir_capture = a.ir_capture
    def taps(specs):
        out = []
        for spec in specs:
            idc, irl = spec.split(':')
            out.append(SimpleTap(int(idc, 0), int(irl)))
        return out
    nb = taps(a.neighbour)
    nbi = taps(a.neighbour_tdi)
    dev = Chain(tap, nb, nbi) if nb or nbi else tap
    shifts = []
    tlr_shifts = []
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    try:
        serve(conn, dev, a.short_shift, shifts, tlr_shifts)
    finally:
        if a.ir_log:
            with open(a.ir_log, 'w') as f:
                f.write(''.join('0x%02x\n' % x for x in tap.irs))
        if a.cfg_out_shift_log:
            with open(a.cfg_out_shift_log, 'w') as f:
                f.write(''.join('%d\n' % x for x in shifts))
        if a.tlr_shift_log:
            with open(a.tlr_shift_log, 'w') as f:
                f.write(''.join('%d\n' % x for x in tlr_shifts))
    conn.close()
    srv.close()


if __name__ == '__main__':
    main()
