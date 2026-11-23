"""Stage 4c: the Stage 3c CNN layer on the CPU (NumPy) and the GPU (OpenCL, PyTorch).

All three compute exactly what the FPGA computes, for one bank per frame:

    sum = 3x3 window of uint8 pixels x int8 weights        (4 filters, "valid" only)
    q   = min(255, round_half_up(max(sum + bias, 0) * mult / 2^shift))

Each one must match cnn_ref.py bit for bit (bench_4c.py checks that).

  numpy_cnn(img, w, q)           CPU, vectorized NumPy, int64
  OclCnn                         a hand-written OpenCL kernel, one work-item per output
                                 pixel computing all 4 filters in integer arithmetic
  TorchCnn                       PyTorch on the GPU (ROCm): conv2d in float32, then the
                                 requant in int64. float32 is exact here: |sum| <= 9 x 255
                                 x 128 = 293,760 < 2^24, so every sum is an exact integer.

img is a 2-D uint8 array (H x W). w is a list of 36 signed weights (4 filters x 9
taps, tap 0 = top-left). q is a list of 4 (bias, mult, shift). Outputs are
(H-2) x (W-2) x 4 uint8 arrays.
"""
import os
import sys
import time

_HERE = os.path.dirname(os.path.abspath(__file__))
for _lib in ("gpulib", "torchlib"):
    _p = os.path.join(_HERE, _lib)
    if os.path.isdir(_p) and _p not in sys.path:
        sys.path.append(_p)

import numpy as np

N_F = 4


# ---------------------------------------------------------------- CPU (NumPy)
def numpy_cnn(img, w, q):
    img = img.astype(np.int64)
    H, W = img.shape
    w = np.asarray(w, dtype=np.int64).reshape(N_F, 3, 3)
    out = np.empty((H - 2, W - 2, N_F), dtype=np.uint8)
    for f in range(N_F):
        s = np.zeros((H - 2, W - 2), dtype=np.int64)
        for r in range(3):
            for c in range(3):
                s += w[f, r, c] * img[r:r + H - 2, c:c + W - 2]
        bias, mult, shift = q[f]
        p = np.maximum(s + bias, 0) * mult
        if shift:
            p += 1 << (shift - 1)
        out[:, :, f] = np.minimum(p >> shift, 255)
    return out


# ---------------------------------------------------------------- GPU (OpenCL)
OCL_SRC = r"""
// One work-item per output pixel; all 4 filters. Same integer math as the FPGA.
__kernel void cnn_layer(__global const uchar *img, int W, int H,
                        __constant const char *w,        // 36 weights, filter*9 + tap
                        __constant const int  *bias,     // 4
                        __constant const int  *mult,     // 4
                        __constant const int  *shift,    // 4
                        __global uchar4 *out)            // (H-2) x (W-2)
{
    int x = get_global_id(0), y = get_global_id(1);
    if (x >= W - 2 || y >= H - 2) return;
    int p[9];
    for (int r = 0; r < 3; r++)
        for (int c = 0; c < 3; c++)
            p[r * 3 + c] = img[(y + r) * W + (x + c)];
    uchar res[4];
    for (int f = 0; f < 4; f++) {
        int s = 0;
        for (int t = 0; t < 9; t++) s += p[t] * (int)w[f * 9 + t];
        long r = (long)max(s + bias[f], 0);
        long v = r * (long)mult[f];
        if (shift[f]) v += 1L << (shift[f] - 1);
        v >>= shift[f];
        res[f] = (uchar)min(v, 255L);
    }
    out[y * (W - 2) + x] = (uchar4)(res[0], res[1], res[2], res[3]);
}
"""


class OclCnn:
    """Keeps the context, queue, compiled kernel and buffers for one image size."""

    def __init__(self, W, H):
        import pyopencl as cl
        self.cl = cl
        dev = None
        for p in cl.get_platforms():
            for d in p.get_devices(device_type=cl.device_type.GPU):
                dev = d
        if dev is None:
            raise RuntimeError("no OpenCL GPU found")
        self.device = dev
        self.ctx = cl.Context([dev])
        self.q = cl.CommandQueue(self.ctx, properties=cl.command_queue_properties.PROFILING_ENABLE)
        self.prg = cl.Program(self.ctx, OCL_SRC).build()
        self.kernel = cl.Kernel(self.prg, "cnn_layer")
        self.W, self.H = W, H
        mf = cl.mem_flags
        self.d_img = cl.Buffer(self.ctx, mf.READ_ONLY, W * H)
        self.d_out = cl.Buffer(self.ctx, mf.WRITE_ONLY, (W - 2) * (H - 2) * 4)
        self.h_out = np.empty((H - 2, W - 2, N_F), dtype=np.uint8)
        self.params = None

    def set_params(self, w, q):
        cl, mf = self.cl, self.cl.mem_flags
        self.d_w = cl.Buffer(self.ctx, mf.READ_ONLY | mf.COPY_HOST_PTR, hostbuf=np.asarray(w, dtype=np.int8))
        self.d_b = cl.Buffer(self.ctx, mf.READ_ONLY | mf.COPY_HOST_PTR, hostbuf=np.array([t[0] for t in q], dtype=np.int32))
        self.d_m = cl.Buffer(self.ctx, mf.READ_ONLY | mf.COPY_HOST_PTR, hostbuf=np.array([t[1] for t in q], dtype=np.int32))
        self.d_s = cl.Buffer(self.ctx, mf.READ_ONLY | mf.COPY_HOST_PTR, hostbuf=np.array([t[2] for t in q], dtype=np.int32))
        self.kernel.set_args(self.d_img, np.int32(self.W), np.int32(self.H),
                             self.d_w, self.d_b, self.d_m, self.d_s, self.d_out)

    def run(self, img):
        """Upload, compute, download one frame. Returns (out, t_h2d, t_kernel, t_d2h) in seconds,
        from the GPU's own event timestamps."""
        cl = self.cl
        img = np.ascontiguousarray(img, dtype=np.uint8)
        e1 = cl.enqueue_copy(self.q, self.d_img, img)
        gx = (self.W - 2 + 15) // 16 * 16
        gy = (self.H - 2 + 15) // 16 * 16
        e2 = cl.enqueue_nd_range_kernel(self.q, self.kernel, (gx, gy), (16, 16))
        e3 = cl.enqueue_copy(self.q, self.h_out, self.d_out)
        e3.wait()
        t = lambda e: (e.profile.end - e.profile.start) * 1e-9
        return self.h_out.copy(), t(e1), t(e2), t(e3)

    def run_kernel_only(self, reps):
        """reps kernel launches back to back on data already on the GPU; returns seconds per frame
        (first launch start to last launch end, from GPU timestamps)."""
        cl = self.cl
        gx = (self.W - 2 + 15) // 16 * 16
        gy = (self.H - 2 + 15) // 16 * 16
        evs = [cl.enqueue_nd_range_kernel(self.q, self.kernel, (gx, gy), (16, 16)) for _ in range(reps)]
        evs[-1].wait()
        return (evs[-1].profile.end - evs[0].profile.start) * 1e-9 / reps


# ---------------------------------------------------------------- GPU (PyTorch)
class TorchCnn:
    def __init__(self):
        import torch
        self.torch = torch
        if not torch.cuda.is_available():
            raise RuntimeError("PyTorch sees no GPU (torch.cuda.is_available() is False)")
        self.dev = torch.device("cuda")
        self.name = torch.cuda.get_device_name(0)

    def set_params(self, w, q):
        t = self.torch
        self.w = t.tensor(np.asarray(w, dtype=np.float32).reshape(N_F, 1, 3, 3), device=self.dev)
        self.bias = t.tensor([v[0] for v in q], dtype=t.int64, device=self.dev).view(1, N_F, 1, 1)
        self.mult = t.tensor([v[1] for v in q], dtype=t.int64, device=self.dev).view(1, N_F, 1, 1)
        sh = [v[2] for v in q]
        self.shift = t.tensor(sh, dtype=t.int64, device=self.dev).view(1, N_F, 1, 1)
        self.rnd = t.tensor([(1 << (s - 1)) if s else 0 for s in sh], dtype=t.int64, device=self.dev).view(1, N_F, 1, 1)

    def compute(self, d_img):
        """d_img: uint8 tensor (H, W) on the GPU -> uint8 tensor (H-2, W-2, 4) on the GPU."""
        t = self.torch
        x = d_img.to(t.float32)[None, None]
        s = t.nn.functional.conv2d(x, self.w)                   # exact integers in float32
        s = s.round().to(t.int64)
        p = t.clamp(s + self.bias, min=0) * self.mult + self.rnd
        p = t.clamp(p >> self.shift, max=255).to(t.uint8)
        return p[0].permute(1, 2, 0).contiguous()

    def run(self, img):
        """Upload, compute, download one frame; times from GPU events, in seconds."""
        t = self.torch
        ev = [t.cuda.Event(enable_timing=True) for _ in range(4)]
        h_img = t.from_numpy(np.ascontiguousarray(img, dtype=np.uint8))
        ev[0].record()
        d_img = h_img.to(self.dev, non_blocking=False)
        ev[1].record()
        d_out = self.compute(d_img)
        ev[2].record()
        out = d_out.cpu()
        ev[3].record()
        t.cuda.synchronize()
        ms = [ev[i].elapsed_time(ev[i + 1]) * 1e-3 for i in range(3)]
        return out.numpy(), ms[0], ms[1], ms[2]

    def run_compute_only(self, img, reps):
        """Seconds per frame for reps frames back to back, image already on the GPU.
        Measured by the host wall clock around the whole loop plus a final synchronize,
        i.e. the rate you actually get. (GPU event timers report about 2x faster here:
        PyTorch launches about 10 small kernels per frame and is limited by the CPU-side
        launch overhead, which the GPU events don't see.)"""
        t = self.torch
        d_img = t.from_numpy(np.ascontiguousarray(img, dtype=np.uint8)).to(self.dev)
        self.compute(d_img)
        t.cuda.synchronize()
        t0 = time.perf_counter()
        for _ in range(reps):
            self.compute(d_img)
        t.cuda.synchronize()
        return (time.perf_counter() - t0) / reps
