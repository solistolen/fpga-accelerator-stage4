"""Stage 4c: check the FPGA's cnn_stream at video sizes in Icarus Verilog.

For each size: makes a random test image (fixed seed), runs sim/tb_cnn_scale.v
(cnn_stream fed one pixel per clock), compares every result with numpy_cnn
(bank A), and reports the clock count. Results go to ../results/fpga_scale.json.

Run:  python fpga_scale.py              (640x480 and 1920x1080; 1080p takes a few minutes)
      python fpga_scale.py 640x480
"""
import gpu_cnn            # first: it puts ./gpulib (NumPy) on the path
import json
import os
import re
import subprocess
import sys
import time

import numpy as np
import cnn_ref

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
SIM = os.path.join(REPO, "sim")
IVERILOG_DIRS = [r"C:\iverilog\bin", ""]

SIZES = {"640x480": (640, 480, 10, 9), "1920x1080": (1920, 1080, 11, 11)}


def tool(name):
    for d in IVERILOG_DIRS:
        p = os.path.join(d, name + ".exe") if d else name
        if not d or os.path.exists(p):
            return p


def run_size(key, wts, qnt):
    W, H, cb, rb = SIZES[key]
    rng = np.random.default_rng(4)
    img = rng.integers(0, 256, size=(H, W), dtype=np.uint8)
    with open(os.path.join(SIM, "scale_img.hex"), "w") as f:
        f.write("\n".join("%02x" % v for v in img.ravel()) + "\n")
    rtl = [os.path.join(REPO, "rtl", "3c_cnn_layer", m + ".v")
           for m in ("cnn_stream", "feature_stream", "conv_layer", "requant")]
    exe = os.path.join(SIM, "scale_sim")
    subprocess.run([tool("iverilog"), "-o", exe,
                    "-Ptb_cnn_scale.IMG_W=%d" % W, "-Ptb_cnn_scale.IMG_H=%d" % H,
                    "-Ptb_cnn_scale.COL_BITS=%d" % cb, "-Ptb_cnn_scale.ROW_BITS=%d" % rb,
                    "tb_cnn_scale.v"] + rtl, cwd=SIM, check=True)
    t0 = time.time()
    log = subprocess.run([tool("vvp"), "-n", exe], cwd=SIM, check=True,
                         capture_output=True, text=True).stdout
    m = re.search(r"SCALE \S+: (\d+) outputs \(expected (\d+)\), (\d+) clocks", log)
    got, n_out, clocks = int(m.group(1)), int(m.group(2)), int(m.group(3))
    hw = np.loadtxt(os.path.join(SIM, "scale_out.hex"), dtype=str, ndmin=2)
    hw = np.vectorize(lambda s: int(s, 16))(hw).astype(np.uint8).reshape(H - 2, W - 2, 4) \
        if got == n_out else None
    ref = gpu_cnn.numpy_cnn(img, wts[:36], qnt[:4])
    ok = hw is not None and np.array_equal(hw, ref)
    for f in ("scale_img.hex", "scale_out.hex", "scale_sim"):
        try:
            os.remove(os.path.join(SIM, f))
        except OSError:
            pass
    res = {"size": key, "pixels": W * H, "outputs": got, "match": bool(ok),
           "stream_clocks": clocks, "board_clocks": clocks + 2,
           "board_us_at_200MHz": (clocks + 2) / 200.0, "sim_seconds": round(time.time() - t0, 1)}
    print("%-10s %s  %d outputs, cnn_stream %d clocks (= pixels + %d); on the board %d clocks = %.1f us"
          % (key, "MATCH" if ok else "MISMATCH", got, clocks, clocks - W * H,
             clocks + 2, (clocks + 2) / 200.0))
    return res


if __name__ == "__main__":
    wts, qnt = cnn_ref.load_weights(), cnn_ref.load_quant()
    keys = sys.argv[1:] or list(SIZES)
    out = [run_size(k, wts, qnt) for k in keys]
    os.makedirs(os.path.join(REPO, "results"), exist_ok=True)
    path = os.path.join(REPO, "results", "fpga_scale.json")
    old = json.load(open(path)) if os.path.exists(path) else []
    merged = {r["size"]: r for r in old}
    merged.update({r["size"]: r for r in out})
    json.dump(list(merged.values()), open(path, "w"), indent=2)
