"""Reference model for the Stage 4b board run (the Stage 3c CNN layer, one bank per frame).

On the board the whole frame uses one bank (chosen in the 'R' command), so
this model is simpler than Stage 3's gen_cnn.py, which switched banks inside
the frame. The arithmetic is the same:

    sum = sum over the 3x3 window of pixel * weight        (int8 weights)
    q   = min(255, round_half_up(max(sum + bias, 0) * mult / 2^shift))

Inputs (in ../sim, the same files as Stage 3c):
  image.hex    96x64 test image, one byte per line
  weights.hex  72 signed weights: bank A filters 0-3 (9 taps each), then bank B
  quant.hex    8 lines "bias mult shift" (bias as 20-bit two's complement)

Run directly to write ../sim/expected_bank0.txt and expected_bank1.txt (one
line per output pixel: q0 q1 q2 q3 in hex), which tb_cnn_board.v checks.
"""
import os

IMG_W, IMG_H = 96, 64
N_F, N_T, SUM_W = 4, 9, 20
SIM = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "sim")


def read_hex_lines(name):
    with open(os.path.join(SIM, name)) as f:
        return [ln.split() for ln in f if ln.strip()]


def load_image():
    return [int(t[0], 16) for t in read_hex_lines("image.hex")]


def load_weights():
    """72 weights as signed ints."""
    w = [int(t[0], 16) for t in read_hex_lines("weights.hex")]
    return [v - 256 if v >= 128 else v for v in w]


def load_quant():
    """8 (bias, mult, shift) tuples, bias signed."""
    q = []
    for b, m, h in read_hex_lines("quant.hex"):
        b = int(b, 16)
        if b >= 1 << (SUM_W - 1):
            b -= 1 << SUM_W
        q.append((b, int(m, 16), int(h, 16)))
    return q


def requant(s, bias, mult, shift):
    r = max(s + bias, 0)
    p = r * mult
    if shift:
        p += 1 << (shift - 1)
    return min(p >> shift, 255)


def cnn_frame(img, weights, quant, bank):
    """All output pixels of one frame with one bank: list of [q0, q1, q2, q3]."""
    w = weights[bank * N_F * N_T:(bank + 1) * N_F * N_T]
    q = quant[bank * N_F:(bank + 1) * N_F]
    out = []
    for y in range(1, IMG_H - 1):
        for x in range(1, IMG_W - 1):
            win = [img[(y - 1 + r) * IMG_W + (x - 1 + c)] for r in range(3) for c in range(3)]
            res = []
            for f in range(N_F):
                s = sum(p * k for p, k in zip(win, w[f * N_T:(f + 1) * N_T]))
                res.append(requant(s, *q[f]))
            out.append(res)
    return out


if __name__ == "__main__":
    img, wts, qnt = load_image(), load_weights(), load_quant()
    assert len(img) == IMG_W * IMG_H and len(wts) == 2 * N_F * N_T and len(qnt) == 2 * N_F
    for bank in (0, 1):
        res = cnn_frame(img, wts, qnt, bank)
        name = "expected_bank%d.txt" % bank
        with open(os.path.join(SIM, name), "w") as f:
            for r in res:
                f.write(" ".join("%02x" % v for v in r) + "\n")
        print("Wrote %s (%d outputs x 4 filters)" % (name, len(res)))
