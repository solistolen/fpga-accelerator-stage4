"""Stage 4c: FPGA vs GPU vs CPU for the Stage 3c CNN layer (4 filters, 3x3, int8, requant).

For each frame size it:
  1. checks every implementation against NumPy, which is checked against cnn_ref.py
     (the model the board's outputs were verified against) on the real 96x64 test image;
  2. times one frame end to end: upload, compute, download (GPU: from the GPU's own
     event timers; plus host wall-clock time including launch overhead), median of REPS;
  3. times compute alone, frames back to back on data already on the GPU (throughput);
  4. adds the FPGA numbers: 96x64 measured on the ML605 (Stage 4b), larger sizes from
     the cycle-exact simulation of the same RTL (results/fpga_scale.json, fpga_scale.py).

Writes ../results/bench_4c.json and ../results/bench_4c.md.
Run:  python bench_4c.py
"""
import gpu_cnn            # first: it puts ./gpulib and ./torchlib on the path
import json
import os
import platform
import statistics as st
import time

import numpy as np
import cnn_ref

HERE = os.path.dirname(os.path.abspath(__file__))
RES = os.path.join(os.path.dirname(HERE), "results")
REPS = 50
FPGA_MHZ = 200.0
UART_BPS = 11520.0        # 115200 baud, 10 bits per byte (measured 11,512 B/s on the board)

# Stage 4b, measured on the ML605 (README "Result on the ML605")
FPGA_96x64 = {"clocks": 6165, "upload_s": 0.533, "readback_s": 2.03}


def med(xs):
    return st.median(xs)


def bench_cpu(img, w, q):
    gpu_cnn.numpy_cnn(img, w, q)
    ts = []
    for _ in range(max(5, REPS // 5)):
        t0 = time.perf_counter()
        gpu_cnn.numpy_cnn(img, w, q)
        ts.append(time.perf_counter() - t0)
    return {"compute_s": med(ts)}


def bench_gpu(eng, img, ref, compute_only):
    out, *_ = eng.run(img)                                   # warm-up (and compile / tune)
    name = {"OclCnn": "GPU OpenCL ", "TorchCnn": "GPU PyTorch"}.get(type(eng).__name__, type(eng).__name__)
    H, W = img.shape
    if np.array_equal(out, ref):
        print("  %s %dx%d: PASS, all %d x 4 outputs match" % (name, W, H, ref.shape[0] * ref.shape[1]))
    else:
        bad = int(np.any(out != ref, axis=2).sum())
        raise SystemExit("  %s %dx%d: FAIL, %d outputs differ from the reference" % (name, W, H, bad))
    h2d, krn, d2h, wall = [], [], [], []
    for _ in range(REPS):
        t0 = time.perf_counter()
        _, a, b, c = eng.run(img)
        wall.append(time.perf_counter() - t0)
        h2d.append(a); krn.append(b); d2h.append(c)
    return {"h2d_s": med(h2d), "compute_s": med(krn), "d2h_s": med(d2h),
            "end_to_end_s": med(wall), "compute_throughput_s": compute_only()}


def main():
    img96, wts, qnt = cnn_ref.load_image(), cnn_ref.load_weights(), cnn_ref.load_quant()
    w, q = wts[:36], qnt[:4]                                  # bank A
    a96 = np.array(img96, dtype=np.uint8).reshape(cnn_ref.IMG_H, cnn_ref.IMG_W)

    # NumPy against cnn_ref (the board's reference), real test image, both banks
    for bank in (0, 1):
        ref = np.array(cnn_ref.cnn_frame(img96, wts, qnt, bank), dtype=np.uint8).reshape(62, 94, 4)
        assert np.array_equal(gpu_cnn.numpy_cnn(a96, wts[36*bank:36*bank+36], qnt[4*bank:4*bank+4]), ref)
    print("NumPy matches cnn_ref.py on the 96x64 test image (both banks)")

    rng = np.random.default_rng(4)
    frames = {"96x64": a96,
              "640x480": rng.integers(0, 256, (480, 640), dtype=np.uint8),
              "1920x1080": rng.integers(0, 256, (1080, 1920), dtype=np.uint8)}
    scale = {}
    sp = os.path.join(RES, "fpga_scale.json")
    if os.path.exists(sp):
        scale = {r["size"]: r for r in json.load(open(sp))}

    torch_eng = gpu_cnn.TorchCnn()
    torch_eng.set_params(w, q)
    results = {"gpu": torch_eng.name, "cpu": platform.processor(), "reps": REPS, "sizes": {}}

    for key, img in frames.items():
        H, W = img.shape
        ref = gpu_cnn.numpy_cnn(img, w, q)
        r = {"pixels": W * H, "in_bytes": W * H, "out_bytes": (W - 2) * (H - 2) * 4}

        r["cpu_numpy"] = bench_cpu(img, w, q)

        ocl = gpu_cnn.OclCnn(W, H)
        ocl.set_params(w, q)
        r["gpu_opencl"] = bench_gpu(ocl, img, ref, lambda: ocl.run_kernel_only(200))

        r["gpu_torch"] = bench_gpu(torch_eng, img, ref, lambda: torch_eng.run_compute_only(img, 200))

        if key == "96x64":
            clocks, src = FPGA_96x64["clocks"], "measured on the ML605"
            up, down = FPGA_96x64["upload_s"], FPGA_96x64["readback_s"]
        elif key in scale and scale[key]["match"]:
            clocks, src = scale[key]["board_clocks"], "cycle-exact simulation of the board RTL"
            up, down = r["in_bytes"] / UART_BPS, r["out_bytes"] / UART_BPS
        else:
            clocks, src = W * H + 21, "formula pixels + 21 (not simulated)"
            up, down = r["in_bytes"] / UART_BPS, r["out_bytes"] / UART_BPS
        r["fpga"] = {"clocks": clocks, "compute_s": clocks / (FPGA_MHZ * 1e6), "source": src,
                     "uart_up_s": up, "uart_down_s": down,
                     "latency_after_last_pixel_s": 21 / (FPGA_MHZ * 1e6)}
        results["sizes"][key] = r
        print("%-10s FPGA %8.1f us | OpenCL kernel %7.1f us, end-to-end %7.1f us | "
              "PyTorch compute %7.1f us, end-to-end %7.1f us | NumPy %8.1f us"
              % (key, r["fpga"]["compute_s"] * 1e6,
                 r["gpu_opencl"]["compute_s"] * 1e6, r["gpu_opencl"]["end_to_end_s"] * 1e6,
                 r["gpu_torch"]["compute_s"] * 1e6, r["gpu_torch"]["end_to_end_s"] * 1e6,
                 r["cpu_numpy"]["compute_s"] * 1e6))

    os.makedirs(RES, exist_ok=True)
    json.dump(results, open(os.path.join(RES, "bench_4c.json"), "w"), indent=2)
    write_md(results)
    print("wrote results/bench_4c.json and results/bench_4c.md")


def us(s):
    """Seconds -> text in µs (or in s from 1 s up)."""
    if s >= 1:
        return "%.1f s" % s
    if s < 1e-6:
        return "%.3f" % (s * 1e6)
    return "%.1f" % (s * 1e6) if s < 1e-2 else "{:,.0f}".format(s * 1e6)


def write_md(res):
    L = ["# Stage 4c results: FPGA vs GPU vs CPU", "",
         "Same layer everywhere (4 filters, 3x3, int8 weights, bias + ReLU + requant to 8 bits), "
         "all outputs identical to the reference. GPU: %s. CPU: %s. Times are medians of %d runs, in µs."
         % (res["gpu"], res["cpu"], res["reps"]), ""]
    L += ["## Compute only (one frame, data already on the device)", "",
          "| Frame | FPGA ML605, 200 MHz | GPU OpenCL kernel | GPU PyTorch | CPU NumPy |", "|---|---|---|---|---|"]
    for k, r in res["sizes"].items():
        L.append("| %s | %s | %s | %s | %s |" % (k, us(r["fpga"]["compute_s"]), us(r["gpu_opencl"]["compute_s"]),
                                                us(r["gpu_torch"]["compute_s"]), us(r["cpu_numpy"]["compute_s"])))
    L += ["", "## Throughput (frames back to back, compute only)", "",
          "| Frame | FPGA fps | GPU OpenCL fps | GPU PyTorch fps | CPU NumPy fps |", "|---|---|---|---|---|"]
    for k, r in res["sizes"].items():
        L.append("| %s | {:,.0f} | {:,.0f} | {:,.0f} | {:,.0f} |".format(
            1 / r["fpga"]["compute_s"], 1 / r["gpu_opencl"]["compute_throughput_s"],
            1 / r["gpu_torch"]["compute_throughput_s"], 1 / r["cpu_numpy"]["compute_s"]) % k)
    L += ["", "## One frame end to end (host memory → result in host memory)", "",
          "| Frame | GPU OpenCL: upload + kernel + download (wall) | GPU PyTorch: upload + compute + download (wall) | FPGA over the UART: upload + compute + readback |",
          "|---|---|---|---|"]
    for k, r in res["sizes"].items():
        o, t, f = r["gpu_opencl"], r["gpu_torch"], r["fpga"]
        L.append("| %s | %s + %s + %s (%s) | %s + %s + %s (%s) | %s + %s + %s |" % (
            k, us(o["h2d_s"]), us(o["compute_s"]), us(o["d2h_s"]), us(o["end_to_end_s"]),
            us(t["h2d_s"]), us(t["compute_s"]), us(t["d2h_s"]), us(t["end_to_end_s"]),
            us(f["uart_up_s"]), us(f["compute_s"]), us(f["uart_down_s"])))
    L += ["", "## Latency once the last pixel of a frame exists", "",
          "| Frame | FPGA (streaming: last result 21 clocks after last pixel) | GPU OpenCL (whole frame: upload + kernel + download, wall) |",
          "|---|---|---|"]
    for k, r in res["sizes"].items():
        L.append("| %s | %s | %s |" % (k, us(r["fpga"]["latency_after_last_pixel_s"]), us(r["gpu_opencl"]["end_to_end_s"])))
    L += ["", "FPGA source per size: " + "; ".join("%s: %s" % (k, r["fpga"]["source"]) for k, r in res["sizes"].items()) + "."]
    open(os.path.join(RES, "bench_4c.md"), "w", encoding="utf-8").write("\n".join(L) + "\n")


if __name__ == "__main__":
    main()
