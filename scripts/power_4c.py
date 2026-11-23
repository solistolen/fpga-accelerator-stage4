"""Stage 4c: energy per frame, GPU (measured) vs FPGA (XPower Analyzer estimate).

GPU: the RX 7800 XT's own board-power sensor, read through the AMD driver's ADL
library (adl_power.py; sensor 73 = total board power in W, which reads about
24 W idle and about 275 W under full load). For each implementation and frame
size, frames run back to back for SECONDS while the sensor is sampled. Then:
    energy per frame = average power / frames per second
    extra energy     = (average power - idle power) / frames per second

FPGA: no power meter is available, so the ML605 numbers come from ISE 14.7's
XPower Analyzer for the routed Board4b design at 200 MHz (results/xpower_4b.txt).
Continuous-mode frame rates (6169 clocks per 96x64 frame, measured in simulation;
pixels + 25 in general) give the FPGA's frames per second.

Writes ../results/power_4c.json and ../results/power_4c.md.
Run:  python power_4c.py      (about 1 minute; leave the PC otherwise idle)
"""
import gpu_cnn            # first: puts ./gpulib and ./torchlib on the path
import json
import os
import threading
import time

import numpy as np
import adl_power
import cnn_ref

HERE = os.path.dirname(os.path.abspath(__file__))
RES = os.path.join(os.path.dirname(HERE), "results")
SECONDS = 6.0
WARMUP = 1.5
BOARD_POWER = 73          # ADL sensor: total board power (W)

# FPGA, XPower Analyzer (ISE 14.7, Board4b routed design, 200 MHz, default activity,
# ambient 50 C). See results/xpower_4b.txt.
FPGA_TOTAL_W = 3.579
FPGA_STATIC_W = 3.442
FPGA_DYNAMIC_W = 0.137
FPGA_CLK = 200e6
FPGA_OVERHEAD_CLOCKS = 25          # continuous mode: pixels + 21 (pipeline) + 4 (restart)


def sample_power(sensors, seconds, busy=None):
    """Average board power over `seconds`; if busy() is given it runs in a thread meanwhile and
    must return (frames, seconds) per call. Returns (avg_W, fps or None)."""
    stop = threading.Event()
    done = {"frames": 0, "secs": 0.0}
    window = {"on": False}

    def worker():
        while not stop.is_set():
            t0 = time.perf_counter()
            n = busy()
            dt = time.perf_counter() - t0
            if window["on"]:
                done["frames"] += n
                done["secs"] += dt

    th = None
    if busy:
        th = threading.Thread(target=worker, daemon=True)
        th.start()
        time.sleep(WARMUP)                 # let clocks and power ramp up
    window["on"] = True
    vals, t0 = [], time.time()
    while time.time() - t0 < seconds:
        vals.append(sensors.read()[BOARD_POWER])
        time.sleep(0.05)
    window["on"] = False
    if th:
        stop.set()
        th.join()
    fps = done["frames"] / done["secs"] if busy and done["secs"] else None
    return sum(vals) / len(vals), fps


def main():
    sensors = adl_power.AdlSensors()
    wts, qnt = cnn_ref.load_weights(), cnn_ref.load_quant()
    w, q = wts[:36], qnt[:4]
    rng = np.random.default_rng(4)
    frames = {"96x64": np.array(cnn_ref.load_image(), dtype=np.uint8).reshape(64, 96),
              "640x480": rng.integers(0, 256, (480, 640), dtype=np.uint8),
              "1920x1080": rng.integers(0, 256, (1080, 1920), dtype=np.uint8)}

    time.sleep(2)
    idle_w, _ = sample_power(sensors, SECONDS)
    print("GPU idle board power: %.1f W" % idle_w)

    torch_eng = gpu_cnn.TorchCnn()
    torch_eng.set_params(w, q)
    out = {"gpu": torch_eng.name, "gpu_idle_W": idle_w, "seconds": SECONDS,
           "fpga_xpower": {"total_W": FPGA_TOTAL_W, "static_W": FPGA_STATIC_W, "dynamic_W": FPGA_DYNAMIC_W},
           "sizes": {}}

    for key, img in frames.items():
        H, W = img.shape
        r = {}
        ocl = gpu_cnn.OclCnn(W, H)
        ocl.set_params(w, q)
        ocl.run(img)
        per = ocl.run_kernel_only(20)
        reps = max(20, int(0.05 / per))   # batches of about 50 ms
        p, fps = sample_power(sensors, SECONDS, lambda: (ocl.run_kernel_only(reps), reps)[1])
        r["gpu_opencl"] = {"W": p, "fps": fps, "mJ_per_frame": 1e3 * p / fps,
                           "extra_mJ_per_frame": 1e3 * (p - idle_w) / fps}

        torch_eng.run(img)
        per = torch_eng.run_compute_only(img, 20)
        reps = max(50, int(0.1 / per))    # batches of about 100 ms (the image stays on the GPU)
        p, fps = sample_power(sensors, SECONDS, lambda: (torch_eng.run_compute_only(img, reps), reps)[1])
        r["gpu_torch"] = {"W": p, "fps": fps, "mJ_per_frame": 1e3 * p / fps,
                          "extra_mJ_per_frame": 1e3 * (p - idle_w) / fps}

        f_fps = FPGA_CLK / (W * H + FPGA_OVERHEAD_CLOCKS)
        r["fpga"] = {"W_total": FPGA_TOTAL_W, "W_dynamic": FPGA_DYNAMIC_W, "fps": f_fps,
                     "mJ_per_frame": 1e3 * FPGA_TOTAL_W / f_fps,
                     "extra_mJ_per_frame": 1e3 * FPGA_DYNAMIC_W / f_fps}
        out["sizes"][key] = r
        print("%-10s GPU OpenCL %5.1f W %9.0f fps %8.4f mJ | PyTorch %5.1f W %8.0f fps %8.4f mJ | "
              "FPGA %4.2f W %7.0f fps %8.4f mJ (dynamic only %8.4f mJ)"
              % (key, r["gpu_opencl"]["W"], r["gpu_opencl"]["fps"], r["gpu_opencl"]["mJ_per_frame"],
                 r["gpu_torch"]["W"], r["gpu_torch"]["fps"], r["gpu_torch"]["mJ_per_frame"],
                 FPGA_TOTAL_W, f_fps, r["fpga"]["mJ_per_frame"], r["fpga"]["extra_mJ_per_frame"]))

    json.dump(out, open(os.path.join(RES, "power_4c.json"), "w"), indent=2)
    write_md(out)
    print("wrote results/power_4c.json and results/power_4c.md")


def mj(x):
    return "%.3f" % x if x < 10 else "%.1f" % x


def write_md(o):
    L = ["# Stage 4c: energy per frame", "",
         "GPU: %s, board power measured with its own sensor (idle %.1f W), frames back to back for %.0f s per row. "
         "FPGA: XPower Analyzer estimate for the routed ML605 design at 200 MHz (%.3f W total = %.3f W static + %.3f W dynamic), "
         "with the continuous-mode frame rate." % (o["gpu"], o["gpu_idle_W"], o["seconds"],
                                                   FPGA_TOTAL_W, FPGA_STATIC_W, FPGA_DYNAMIC_W), "",
         "| Frame | | Power (W) | Frames/s | **Energy per frame (mJ)** | Above idle (mJ) |", "|---|---|---|---|---|---|"]
    for k, r in o["sizes"].items():
        o_, t, f = r["gpu_opencl"], r["gpu_torch"], r["fpga"]
        L.append("| %s | GPU OpenCL | %.1f | {:,.0f} | **%s** | %s |".format(o_["fps"]) % (k, o_["W"], mj(o_["mJ_per_frame"]), mj(o_["extra_mJ_per_frame"])))
        L.append("| | GPU PyTorch | %.1f | {:,.0f} | **%s** | %s |".format(t["fps"]) % (t["W"], mj(t["mJ_per_frame"]), mj(t["extra_mJ_per_frame"])))
        L.append("| | FPGA (XPower estimate) | %.2f | {:,.0f} | **%s** | %s (dynamic only) |".format(f["fps"]) % (f["W_total"], mj(f["mJ_per_frame"]), mj(f["extra_mJ_per_frame"])))
    open(os.path.join(RES, "power_4c.md"), "w", encoding="utf-8").write("\n".join(L) + "\n")


if __name__ == "__main__":
    main()
