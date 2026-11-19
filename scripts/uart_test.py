"""Stage 4a PC-side test: talks to the ML605 over its USB-UART (CP2103).

The board sends back every byte it receives, plus 1. This script:
  1. sends every value 0..255 in small chunks and checks each reply;
  2. sends 2000 random bytes in one burst (back to back) and checks them all;
  3. reports the measured throughput.

Needs pyserial:   pip install pyserial
Run:              python uart_test.py            (finds the CP210x port by itself)
                  python uart_test.py COM5       (or name the port)
                  python uart_test.py --list     (show all serial ports)
"""
import os
import sys
import time

# Use the copy of pyserial in ./pylib if it's there (installed with
# "pip install --target pylib pyserial"), so the script works from any terminal.
_PYLIB = os.path.join(os.path.dirname(os.path.abspath(__file__)), "pylib")
if os.path.isdir(_PYLIB):
    sys.path.insert(0, _PYLIB)

try:
    import serial
    from serial.tools import list_ports
except ImportError:
    sys.exit("pyserial is not installed. Run:  pip install pyserial")

BAUD = 115200


def find_port():
    ports = list(list_ports.comports())
    for p in ports:
        text = "%s %s %s" % (p.device, p.description, p.manufacturer or "")
        if "CP210" in text or "Silicon Labs" in text:
            return p.device
    names = ", ".join(p.device + " (" + p.description + ")" for p in ports) or "none"
    sys.exit("No CP210x (Silicon Labs) USB-UART found. Serial ports: %s\n"
             "Is the USB cable in the board's 'USB UART' connector, and the board on?" % names)


def check(sent, got, label):
    expect = bytes((b + 1) & 0xFF for b in sent)
    if got == expect:
        print("  %-36s PASS (%d bytes)" % (label, len(sent)))
        return True
    if len(got) != len(expect):
        print("  %-36s FAIL: sent %d bytes, got %d back" % (label, len(sent), len(got)))
    for i, (e, g) in enumerate(zip(expect, got)):
        if e != g:
            print("  %-36s FAIL: first mismatch at byte %d: got %02x, expected %02x" % (label, i, g, e))
            break
    return False


def main():
    if "--list" in sys.argv:
        for p in list_ports.comports():
            print(p.device, "-", p.description)
        return
    port = sys.argv[1] if len(sys.argv) > 1 else find_port()
    print("Opening %s at %d baud, 8N1" % (port, BAUD))
    with serial.Serial(port, BAUD, bytesize=8, parity="N", stopbits=1, timeout=2) as s:
        s.reset_input_buffer()
        ok = True

        # 1. every value, 16 at a time
        sent = bytes(range(256))
        got = b""
        for i in range(0, 256, 16):
            s.write(sent[i:i + 16])
            got += s.read(16)
        ok &= check(sent, got, "all values 0..255 (16 at a time)")

        # 2. one long back-to-back burst
        burst = os.urandom(2000)
        t0 = time.perf_counter()
        s.write(burst)
        got = s.read(len(burst))
        dt = time.perf_counter() - t0
        ok &= check(burst, got, "2000 random bytes in one burst")
        if got:
            print("  throughput: %.0f bytes/s each way (115200 baud, 10 bits/byte: max 11520)" % (len(got) / dt))

        leftovers = s.read(64)
        if leftovers:
            print("  FAIL: %d unexpected extra bytes" % len(leftovers))
            ok = False

    print("PASS: the ML605 UART link works" if ok else "FAIL")


if __name__ == "__main__":
    main()
