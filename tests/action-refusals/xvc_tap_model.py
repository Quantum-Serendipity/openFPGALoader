#!/usr/bin/env python3
import argparse
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
IR_IDCODE = 0x09


class Tap:
    def __init__(self, idcode, stat, done):
        self.idcode = idcode
        self.stat = stat
        self.ir_capture = 0x01 | 0x10 | (0x20 if done else 0)
        self.state = 'TLR'
        self.ir = IR_IDCODE
        self.ir_sr = 0
        self.dr = []

    def capture_dr(self):
        if self.ir == IR_IDCODE:
            self.dr = [(self.idcode >> i) & 1 for i in range(32)]
        elif self.ir == IR_CFG_OUT:
            self.dr = [(self.stat >> (31 - i)) & 1 for i in range(32)]
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
                tdo = self.dr.pop(0) if self.dr else 0
            else:
                tdo = self.dr.pop(0)
                self.dr.append(tdi)
        elif st == 'CAPIR':
            self.ir_sr = self.ir_capture
        elif st == 'CAPDR':
            self.capture_dr()
        elif st == 'UPIR':
            self.ir = self.ir_sr & ((1 << IR_LEN) - 1)
        nxt = NEXT[st][tms]
        if nxt == 'TLR':
            self.ir = IR_IDCODE
        self.state = nxt
        return tdo


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


def serve(conn, tap):
    while True:
        try:
            cmd = recv_command(conn)
        except EOFError:
            return
        if cmd == b'getinfo:':
            conn.sendall(b'xvcServer_v1.0:2048\n')
        elif cmd == b'settck:':
            conn.sendall(recv_exact(conn, 4))
        elif cmd == b'shift:':
            nbits = int.from_bytes(recv_exact(conn, 4), 'little')
            nbytes = (nbits + 7) // 8
            tms = recv_exact(conn, nbytes)
            tdi = recv_exact(conn, nbytes)
            out = bytearray(nbytes)
            for i in range(nbits):
                b = tap.clock((tms[i >> 3] >> (i & 7)) & 1,
                              (tdi[i >> 3] >> (i & 7)) & 1)
                out[i >> 3] |= b << (i & 7)
            conn.sendall(bytes(out))
        else:
            raise ValueError('unknown command %r' % cmd)


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--port-file', required=True)
    p.add_argument('--idcode', type=lambda s: int(s, 0), default=0x03631093)
    p.add_argument('--stat', type=lambda s: int(s, 0), default=0x401079FC)
    p.add_argument('--done-low', action='store_true')
    p.add_argument('--accept-timeout', type=float, default=60.0)
    a = p.parse_args()
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
    serve(conn, Tap(a.idcode, a.stat, not a.done_low))
    conn.close()
    srv.close()


if __name__ == '__main__':
    main()
