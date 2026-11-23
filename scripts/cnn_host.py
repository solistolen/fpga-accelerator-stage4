"""Stage 4b PC side: runs the CNN layer on the ML605 and checks every output.

Steps:
  1. 'P'  ping: the board answers "4B" and its image size (96 x 64)
  2. 'W', 'Q', 'I'  load the 72 weights, the 8 requant parameter sets and the image
                    (the same weights.hex / quant.hex / image.hex as Stage 3c, in ../sim)
  3. for bank 0 and bank 1:
       'R' bank  the board runs the whole frame on chip and returns the cycle count
       'O'       read back the 4 feature maps (5828 x 4 bytes) and compare every byte
                 with the Python reference model (cnn_ref.py)
  4. print the measured compute time and the UART transfer times; save the
     board's feature maps as board_bank0.png / board_bank1.png

Needs pyserial:   pip install pyserial
Run:              python cnn_host.py            (finds the CP210x port by itself)
                  python cnn_host.py COM3       (or name the port)
"""
import os
import sys
import time

_HERE = os.path.dirname(os.path.abspath(__file__))
_PYLIB = os.path.join(_HERE, "pylib")
if os.path.isdir(_PYLIB):
    sys.path.insert(0, _PYLIB)

try:
    import serial
except ImportError:
    sys.exit("pyserial is not installed. Run:  pip install pyserial")

import cnn_ref
from png_util import write_png
from uart_test import find_port

BAUD = 115200
CLK_MHZ = 200.0
N_F = 4


class Board:
    def __init__(self, port):
        self.s = serial.Serial(port, BAUD, bytesize=8, parity="N", stopbits=1, timeout=3)
        time.sleep(0.1)
        self.s.reset_input_buffer()

    def read(self, n, what):
        data = self.s.read(n)
        if len(data) != n:
            sys.exit("FAIL: %s: expected %d bytes from the board, got %d (%r)"
                     % (what, n, len(data), data[:16]))
        return data

    def ack(self, want, what):
        got = self.read(1, what)
        if got != want:
            sys.exit("FAIL: %s: board answered %r, expected %r" % (what, got, want))

    def send(self, cmd, payload, ack, what):
        t0 = time.perf_counter()
        self.s.write(cmd + payload)
        self.ack(ack, what)
        return time.perf_counter() - t0


def main():
    port = sys.argv[1] if len(sys.argv) > 1 else find_port()
    img, wts, qnt = cnn_ref.load_image(), cnn_ref.load_weights(), cnn_ref.load_quant()
    W, H = cnn_ref.IMG_W, cnn_ref.IMG_H
    n_out = (W - 2) * (H - 2)

    print("Opening %s at %d baud, 8N1" % (port, BAUD))
    b = Board(port)

    # 1. ping
    b.s.write(b"P")
    r = b.read(6, "ping")
    bw, bh = r[2] | r[3] << 8, r[4] | r[5] << 8
    if r[:2] != b"4B" or (bw, bh) != (W, H):
        sys.exit("FAIL: ping answered %r (expected '4B', %dx%d). Is the Stage 4b bitstream loaded?"
                 % (r, W, H))
    print("  ping: Stage 4b board, image %d x %d" % (bw, bh))

    # 2. load
    wbytes = bytes(v & 0xFF for v in wts)
    qbytes = bytearray()
    for bias, mult, shift in qnt:
        bias &= (1 << cnn_ref.SUM_W) - 1
        qbytes += bytes([bias & 0xFF, bias >> 8 & 0xFF, bias >> 16 & 0xFF,
                         mult & 0xFF, mult >> 8, shift])
    t_w = b.send(b"W", wbytes, b"w", "weights")
    t_q = b.send(b"Q", bytes(qbytes), b"q", "requant parameters")
    t_i = b.send(b"I", bytes(img), b"i", "image")
    print("  loaded weights (%d B, %.3f s), requant (%d B, %.3f s), image (%d B, %.3f s)"
          % (len(wbytes), t_w, len(qbytes), t_q, len(img), t_i))

    ok = True
    for bank in (0, 1):
        # 3a. run
        b.s.write(b"R" + bytes([bank]))
        b.ack(b"r", "run")
        r = b.read(6, "run result")
        cycles = int.from_bytes(r[:4], "little")
        got_n = r[4] | r[5] << 8

        # 3b. read back
        t0 = time.perf_counter()
        b.s.write(b"O")
        data = b.read(4 * n_out, "feature maps")
        b.ack(b"o", "end of feature maps")
        t_o = time.perf_counter() - t0

        hw = [list(data[4 * i:4 * i + 4]) for i in range(n_out)]
        ref = cnn_ref.cnn_frame(img, wts, qnt, bank)
        bad = [i for i in range(n_out) if hw[i] != ref[i]]

        print("\n  bank %d:" % bank)
        print("    compute on the FPGA: %d clocks = %.2f us at %.0f MHz (%d pixels in, %d x %d out)"
              % (cycles, cycles / CLK_MHZ, CLK_MHZ, W * H, got_n, N_F))
        print("    read back %d bytes in %.2f s (%.0f bytes/s)" % (len(data), t_o, len(data) / t_o))
        if got_n != n_out:
            print("    FAIL: the board produced %d outputs, expected %d" % (got_n, n_out))
            ok = False
        if bad:
            ok = False
            print("    FAIL: %d of %d outputs differ from the reference" % (len(bad), n_out))
            for i in bad[:5]:
                print("      output %d (row %d, col %d): board %s, reference %s"
                      % (i, i // (W - 2) + 1, i % (W - 2) + 1, hw[i], ref[i]))
        else:
            print("    PASS: all %d x %d outputs match the reference model" % (n_out, N_F))

        # 4. picture: the 4 feature maps side by side
        rows = []
        for y in range(H - 2):
            row = []
            for f in range(N_F):
                row += [hw[y * (W - 2) + x][f] for x in range(W - 2)] + [128] * 4
            rows.append(row[:-4])
        png = os.path.join(_HERE, "board_bank%d.png" % bank)
        write_png(png, rows, scale=3)
        print("    saved %s" % os.path.basename(png))

    b.s.close()
    print()
    if ok:
        print("PASS: the CNN layer on the ML605 matches the reference for both banks")
    else:
        sys.exit("FAIL: see above")


if __name__ == "__main__":
    main()
