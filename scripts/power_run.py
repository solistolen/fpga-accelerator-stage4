"""Stage 4c power measurement helper: keeps the ML605 computing frames non-stop.

A single 'R' computes for only 30.8 us. To measure power, the board has to
compute continuously, so this script:
  1. loads the weights, requant parameters and test image (as cnn_host.py does);
  2. sends 'C' + bank: the board runs the frame back to back (LED 5 on);
  3. waits while you read the power (or for --seconds N);
  4. sends 'S': the board stops after the current frame and reports how many
     frames ran in how many clocks, so the frame rate during the measurement is exact.

Measure the board's power twice and subtract:
  idle    : Stage 4b bitstream loaded, nothing running (before you start this script)
  compute : while this script says RUNNING
The difference is the power the CNN computation adds. Energy per frame =
difference x the time per frame this script prints.

Run:  python power_run.py               (runs until you press Enter)
      python power_run.py --seconds 60  (stops by itself)
      python power_run.py COM3 --bank 1
"""
import argparse
import sys
import time

import cnn_host           # puts ./pylib on the path, imports pyserial, has Board
import cnn_ref
from uart_test import find_port

CLK_HZ = 200e6


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("port", nargs="?")
    ap.add_argument("--seconds", type=float, default=0, help="stop after this many seconds (default: wait for Enter)")
    ap.add_argument("--bank", type=int, default=0, choices=(0, 1))
    a = ap.parse_args()

    port = a.port or find_port()
    img, wts, qnt = cnn_ref.load_image(), cnn_ref.load_weights(), cnn_ref.load_quant()
    b = cnn_host.Board(port)

    b.s.write(b"P")
    r = b.read(6, "ping")
    if r[:2] != b"4B":
        sys.exit("FAIL: ping answered %r. Is the Stage 4b bitstream (with continuous mode) loaded?" % r)

    qbytes = bytearray()
    for bias, mult, shift in qnt:
        bias &= (1 << cnn_ref.SUM_W) - 1
        qbytes += bytes([bias & 0xFF, bias >> 8 & 0xFF, bias >> 16 & 0xFF, mult & 0xFF, mult >> 8, shift])
    b.send(b"W", bytes(v & 0xFF for v in wts), b"w", "weights")
    b.send(b"Q", bytes(qbytes), b"q", "requant parameters")
    b.send(b"I", bytes(img), b"i", "image")
    print("Loaded weights, requant parameters and the 96x64 image on %s." % port)

    b.s.write(b"C" + bytes([a.bank]))
    got = b.read(1, "continuous ack")
    if got == b"?":
        sys.exit("FAIL: the board doesn't know 'C'. Rebuild and program the Stage 4b bitstream with continuous mode.")
    if got != b"c":
        sys.exit("FAIL: continuous ack: board answered %r" % got)
    t0 = time.time()
    print("RUNNING: the board is computing frames back to back (LED 5 on). Read the power now.")
    try:
        if a.seconds > 0:
            time.sleep(a.seconds)
        else:
            input("Press Enter to stop... ")
    finally:
        b.s.write(b"S")
        b.ack(b"s", "continuous stop")
        r = b.read(9, "continuous result")
    wall = time.time() - t0
    frames = int.from_bytes(r[:4], "little")
    clocks = int.from_bytes(r[4:9], "little")      # 40-bit counter
    t_frame = clocks / frames / CLK_HZ
    print("Stopped. %d frames in %d clocks (%.2f s at 200 MHz; %.2f s by the PC clock)"
          % (frames, clocks, clocks / CLK_HZ, wall))
    print("  %.1f clocks = %.2f us per frame, %.0f frames/s, compute duty %.2f%%"
          % (clocks / frames, t_frame * 1e6, 1 / t_frame, 100.0 * frames * 6165 / clocks))
    print("  energy per frame = (compute power - idle power) x %.2f us" % (t_frame * 1e6))
    b.s.close()


if __name__ == "__main__":
    main()
