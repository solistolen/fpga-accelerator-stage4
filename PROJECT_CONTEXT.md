# Project context and handoff

Everything needed to continue this project on another computer, or in a new Claude session: what's
been built, what was learned, how the tools are set up, and what comes next. Updated at the end of
**Stage 4 (2026-11-23)**. Stage 4 is complete.

## Goal

A small image-processing / CNN accelerator in Verilog on a **Xilinx ML605** (Virtex-6
XC6VLX240T-1FF1156), built one measured step at a time. It is the FPGA side of an **FPGA-vs-GPU
comparison for a real-time video pipeline**, a senior design trade-study task: build the same image
operation on both, measure processing time, transfer time, latency and power, and recommend a
platform. The requirement used throughout is **640×480 at 30 fps** (about 9.2 Mpixel/s).

**Where the accelerator sits in the project (Proposal Part 2):** a vision-guided drone whose
processing is all on the **ground**:
- The drone carries only its camera and a wireless FPV video link.
- The video reaches a **ground PC** through a capture device over USB. Fixed room cameras and an
  SDR-based RF sensing module also connect to the PC over USB, and everything runs from the wall.
- In the PC, the **GPU/FPGA accelerator** preprocesses the video for the AI host (Claude Code with
  an MCP server).
- The AI host sends flight commands to a Raspberry Pi, which drives the drone controller (or a
  Pixhawk over MAVLink as a fallback).
- Stage 4 is the plan's task "Prototype FPGA vs. GPU video preprocessing" and the input to
  "Select AI processing platform (PC GPU vs. FPGA)". Nothing in this design has to fly.

## Status at a glance

| Stage | What | Status |
|---|---|---|
| 1–2e | MAC unit → Sobel edge detector, 5 versions | Done (stage2 repo) |
| 3a–3c | Systolic engine → 4-filter conv layer → complete int8 CNN layer | Done (stage3 repo) |
| 4a | Board bring-up: heartbeat LED, UART echo | **Passed on the ML605** |
| 4b | The CNN layer on the board, behind the UART | **Passed on the ML605**: all 46,624 output bytes correct |
| 4c | FPGA vs GPU vs CPU: speed, latency, energy per frame | **Done**: all implementations bit-exact |

## Repositories

| Repo | Contents |
|---|---|
| [fpga-accelerator-stage2](https://github.com/solistolen/fpga-accelerator-stage2) | Stage 1 MAC, 2a pipelined MAC, 2b–2e Sobel edge detector (5 versions) |
| [fpga-accelerator-stage3](https://github.com/solistolen/fpga-accelerator-stage3) | 3a systolic engine, 3b 4-filter conv layer, 3c complete int8 CNN layer |
| [fpga-accelerator-stage4](https://github.com/solistolen/fpga-accelerator-stage4) | 4a bring-up, 4b CNN on the board, 4c FPGA vs GPU (this repo; latest commit `fb6fe78`) |

Each repo has RTL, testbenches, golden models (Python), XST report excerpts, images, and a README
with results and planted-bug tables. Commits are authored as `solistolen` with the GitHub noreply
address. The stage4 repo is self-contained: it includes copies of the Stage 3c RTL
(`rtl/3c_cnn_layer/`) and of its test data.

## Results, Stages 1–3 (XST synthesis estimates, ISE 14.7, IMG_W = 640)

| Stage | Design | DSPs | LUTs | Est. clock | Slowest path / lesson |
|---|---|---|---|---|---|
| 1 | int8 MAC | 1 | 1 | ≈245 MHz | multiply + add in one clock |
| 2a | pipelined MAC | 1 | 1 | ≈314 MHz | product register → DSP MREG; limit moved to `clr_r` → DSP OPMODE |
| 2b | Sobel, 2 × conv3x3 | 18 | 110 | 72 MHz | 9-product sum became a 7-DSP cascade in one clock |
| 2c | + pipelined adder tree | 18 | 206 | 247 MHz | magnitude logic (17 levels) |
| 2d | + pipelined magnitude | 18 | 255 | 270 MHz | one unregistered DSP→DSP hop |
| 2e | fixed Sobel kernel | 0 | 227 | 365 MHz | line-buffer BRAM read → write loop |
| 3a | systolic conv3x3_sys | 18 | 239 | 328 MHz | magnitude add/clamp (fabric); DSP chain no longer the limit |
| 3b | 4-filter conv layer, runtime ping-pong weights | 36 | 453 | 365 MHz | weights as an array became 72 LUT-RAM copies (864 LUTs, 340 MHz); as registers → BRAM loop |
| 3c | + bias, ReLU, requantize to 8 bits | 40 | 1,261 | 365 MHz | rounding constant into DSP OPMODE (282 MHz); registering it a stage early fixed it |

All stages pass their testbenches in **both ISim 14.7 and Icarus Verilog 12**.

### Stage 3c design in one paragraph

`cnn_stream`: pixels (8-bit, each with a bank bit) → row/column counters, BRAM line buffer,
3×3 window → `conv_layer` (4 filters × 9 systolic DSP taps, shared skew delay, two weight banks
selected per window, weights in registers; latency 11) → `requant` per filter (bias, ReLU,
`round(r × mult / 2^shift)`, saturate to 0..255; two parameter banks; latency 6) → 4 output maps
of 8-bit pixels. Total latency 19 clocks. Weight-port rule: rewrite a bank ≥ 8 clocks after the
last window that used it; requant parameters ≥ 12 clocks. `rst` clears only counters and valid
flags, not weights.

## Stage 4 results

### 4a: board bring-up (passed on the board)

- **Design:** heartbeat LED 7 plus a UART echo (+1) with a 16-byte FIFO; internal power-on reset.
- **Build:** timing met at 200 MHz after place and route (score 0).
- **Test:** `scripts/uart_test.py` PASS at 11,453 bytes/s (99.4% of 115200 baud).

### 4b: the CNN layer on the board (passed on the board)

- **Design:** `cnn_board` (in `rtl/4b_cnn_board/`) puts `cnn_stream` behind the UART, with an
  image BRAM, a result BRAM, a cycle counter and LEDs. The protocol:

  | Command | Answer | |
  |---|---|---|
  | `P` | `4B` + size | ping |
  | `W` + 72 bytes | `w` | weights |
  | `Q` + 48 bytes | `q` | requant parameters |
  | `I` + 6144 bytes | `i` | the image |
  | `R` + bank | `r` + cycles + outputs | run one frame |
  | `O` | 23,312 bytes + `o` | read back the 4 maps |
  | `C` + bank / `S` | `c` / `s` + frames + clocks | continuous mode: frames back to back, for power measurement (LED 5) |

  The board drops a half-received command after 0.67 s of silence.
- **Build:** 40 DSP48E1, 11 block RAMs, 1,891 LUTs; All Constraints Met at 200 MHz. XST's estimate
  is 272 MHz, and its slowest path is the UART command FSM, not the CNN.
- **Results:**
  - Both banks: every output byte matches `scripts/cnn_ref.py`.
  - **6165 clocks per 96×64 frame = 30.8 µs** (pixels + 21), identical in Icarus, ISim and on the board.
  - Continuous mode on the board: 324,265 frames in 10.00 s, **6169.0 clocks per frame**, 99.94%
    compute duty. The board's clock agrees with the PC's to 0.02%, which confirms 200 MHz.
- **Verification:** `tb_cnn_board` drives only the UART pins, and 7 planted bugs were all caught.
  The `cnn_stream` reset before every frame is required, because its row counter doesn't wrap.
- **PC side:** `cnn_host.py` (load, run both banks, check, PNGs), `power_run.py` (continuous mode).

### 4c: FPGA vs GPU vs CPU (done)

- **What was compared:** the same layer on the ML605; on an **AMD Radeon RX 7800 XT** (a
  hand-written OpenCL kernel, and PyTorch 2.15 on ROCm 10.2); and on a Ryzen 7 5800X (NumPy). All
  are bit-exact against the reference at every size.
- **Where the FPGA numbers at 640×480 and 1080p come from:** cycle-exact Icarus simulation of the
  board RTL (`fpga_scale.py`, `tb_cnn_scale.v`; every output checked). The board's memories only
  hold 96×64 frames.
- **Results at 640×480:**
  - Compute: FPGA 1,536 µs, OpenCL 10.1 µs, NumPy about 40 ms.
  - Throughput: FPGA 651 fps, OpenCL about 122,000 fps, PyTorch about 3,700 fps (CPU-bound, by the
    wall clock; GPU event timers overstate it about 2×), NumPy 25–27 fps.
  - Latency: FPGA **105 ns** after the last pixel (it streams), versus 0.65–0.95 ms for one GPU
    frame from host memory (2.7–3.4 ms at 1080p).
- **Energy:**
  - The GPU is **measured** with its own board-power sensor through the AMD driver's ADL library
    (`adl_power.py`, sensor 73): about 20 W idle, 234 W at VGA flat out, 275 W at 1080p.
  - The FPGA is **estimated** with XPower Analyzer: 3.58 W = 3.44 W static + 0.137 W dynamic. The
    DSP figure of 0.000 W is too low. No meter was available; the board runs from a PC power
    supply's PCIe 12 V cable.
  - Per VGA frame: GPU 2.0 mJ vs FPGA 5.5 mJ, counting the whole chip; 1.83 vs 0.21 mJ, counting
    only what computing adds.
  - At the 30 fps requirement: **GPU card about 20 W vs FPGA chip about 3.45 W.**
- **System level (README section):** these are chip/card figures. The GPU also needs a host PC,
  while the FPGA can sit in the video path on its own board, so the system-level gap at 30 fps is
  most likely larger. That wasn't measured.

### Conclusions for the trade study

**Recommendation for the drone project's ground PC: the GPU.** It meets 480p30 and 1080p60 with
a large margin (1–3 ms per frame end to end), is already in the PC that runs the AI host, integrates
directly with the vision software, has cheap PCIe transfers, and leaves room for a much larger
network. Its power (about 20 W at 30 fps, about 275 W flat out) matters little on mains.

What the measurements show, and how they apply here:
1. **Speed:** the GPU wins raw throughput by about 150× (VGA) to 225× (1080p). The FPGA design uses
   5% of the chip at 1 pixel per clock, but still meets 480p30 (20× margin) and 1080p60 (1.6×,
   simulated).
2. **Network size is the real limit on an FPGA:** about 16,700 multiply-adds per pixel are available
   at 480p30 on the LX240T, but only about 1,235 at 1080p60. This layer uses 40.
3. **Latency:** the FPGA's 105 ns only applies when it sits in the video path. As a card attached to
   the ground PC, it pays transfers like the GPU. Either way, preprocessing (about 1–3 ms) is small
   next to the FPV link and capture device (typically tens of ms) and the AI's decision time
   (typically seconds). The end-to-end latency hasn't been measured yet; it's in the project plan.
4. **Power:** the FPGA uses about 6× less at 30 fps at chip level (3.45 W versus 20 W). That's
   decisive for an embedded or on-drone version, and secondary on a mains-powered ground PC.
5. **Energy per frame at full speed:** the GPU wins at chip level (2.0 vs 5.5 mJ at VGA). A wider
   or right-sized FPGA would likely reverse that (a projection).
6. **Where the FPGA stays relevant:** as the measured alternative in the trade study, in the video
   path (between the capture device and the PC), and for a future on-drone version.
   - The team's Basys 3 (Artix-7 35T: 90 DSPs, 50 block RAMs) could hold this layer (40 DSPs).
     At 100 MHz it would handle 1080p at 30 fps, not 60. Not built.
7. **Resolution** on the ground PC is set by the cameras, the FPV link, the capture device and
   what the vision pipeline needs, not by compute.

## Recurring lessons

- Pipeline until the slowest path moves; then look at what it moved to.
- Control signals into a DSP48E1's mode pins (OPMODE, ~1.9 ns setup) are slow: turn the decision
  into registered data a stage earlier (2a, 3c).
- How storage is written decides the hardware (3b: array vs registers = 864 LUTs vs 576 FFs).
- Every valid/bank flag must be delayed exactly as much as its data. Off-by-one errors often only
  show at switch points, so tests need many switch points (3b, 3c).
- Try tests against planted bugs. Several first versions missed bugs (3a tap 4, 3b bank timing,
  4a baud mismatch).
- Measure what matters, the way it matters: PyTorch's GPU-event throughput was 2× too optimistic,
  and the wall clock is the honest number. Size counters for the measurement: continuous mode's
  32-bit clock counter would have overflowed in 21.5 s, so it's 40 bits.

## ML605 facts (checked against UG534 and confirmed on the board)

- 200 MHz system clock: LVDS on **J9 (P) / H9 (N)**, LVDS_25 + DIFF_TERM.
- USB-UART (CP2103): the FPGA **receives on J24** (net `USB_1_TX`) and **transmits on J25** (net
  `USB_1_RX`). The net names are from the bridge's point of view. LVCMOS25.
- LEDs 0–7: AC22, AC24, AE22, AE23, AB23, AG23, AE24, AD24 (LVCMOS25).
- FPGA package balls (such as J24) are not the board's connector numbers: **J21** is the USB UART
  mini-B connector and **J22** is the USB JTAG connector. JTAG uses dedicated pins, never the UCF.
- JTAG chain: device 1 `xccace` (System ACE, choose **Bypass**: its dialog asks for `*.mpm *.bsd`),
  device 2 `xc6vlx240t`.
- CPU_RESET button: H10, active high (its I/O standard isn't confirmed, so designs use an internal
  power-on reset).
- Power monitoring: two TI UCD9240 controllers on PMBus; VCCINT is rail 1 at address 52. It needs a
  TI USB Interface Adapter on **J3** and TI Fusion Digital Power Designer (not available here).
- Here the board is powered from a PC power supply's PCIe 12 V cable.

## Environment (main PC, from 2026-11-22)

**Project folder:** `D:\FPGA Accelerator (Virtex 6 ML605)`, which holds clones of the three repos.

**ISE 14.7 runs in a VirtualBox Linux VM** named `ISE_14.7_VIRTUAL_MACHINE` (user `ise`), on
VirtualBox 7.2.16. The VM's Guest Additions are 5.1.30.
- **Shared folder:** it maps to the project folder, and its name is still
  **`FPGA_Accelerator_(Virtex_6_ML605)`**. VirtualBox named it after the folder. Mount it once per
  VM boot:
  ```
  sudo mount -t vboxsf "FPGA_Accelerator_(Virtex_6_ML605)" /mnt/share
  cp /mnt/share/fpga-accelerator-stageN/<path>/*.v /home/ise/<Project>/
  ```
  To get the short name `FPGA`, rename the share while the VM is **powered off** (Settings → Shared
  Folders). A share added while the VM is running ("transient") does **not** work with these old
  Guest Additions: the mount fails with `Protocol error`. The same error appears if the name is wrong.
- **USB:** the VM has filters for the Xilinx/Digilent cables, so the board's JTAG goes to the VM
  automatically. The Silicon Labs CP2103 (the UART) must stay with Windows.
- **ISE projects** (one per top module): `/home/ise/MACmodule` (1/2a), `Sobel` (2b–3a), `Conv` (3b),
  and `CNN` (3c), which came from the old PC's VM and may not exist on this one. Rebuilt on this PC:
  `Board4a`, `Board4b` (current, with continuous mode).
- **ISE workflow:** Add Source with association **All** for design files, **Simulation** for
  testbenches, **Implementation** for UCFs. ISim: Simulate Behavioral Model → `run all`. After
  replacing a file, click **Yes** to reload it and use **Re-launch** in ISim. XPower: Place & Route
  → Analyze Power Distribution.
- **Shut the VM down** with VirtualBox **Machine → ACPI Shutdown** or `sudo poweroff`.

**Windows side:**
- Git, GitHub CLI (signed in as `solistolen`), Icarus Verilog 12 (`C:\iverilog\bin`) and Python 3.12
  (`python` / `py`). pyserial is installed.
- Silicon Labs CP210x VCP driver: the board's UART is **COM3**.
- GPU libraries are installed with pip `--target` into the stage4 repo (gitignored; about 4.6 GB):
  ```
  pip install --target scripts/gpulib numpy pyopencl
  pip install --target scripts/torchlib --index-url https://stable.repo.amd.com/rocm/whl-next/ --extra-index-url https://pypi.org/simple "torch[device-gfx1101]==2.15.0+rocm10.2.0"
  ```
  `gpu_cnn.py` adds both folders to Python's path. MIOpen prints harmless "file is unreadable"
  tuning-database warnings.
- Note: `pip install` run from inside the Claude desktop app may put per-user packages into the
  app's private folder, where a normal terminal can't see them. Run pip from your own terminal, or
  use `--target`.

**Main scripts** (in `fpga-accelerator-stage4/scripts`):

| Script | What it does |
|---|---|
| `uart_test.py` | 4a UART check |
| `cnn_host.py` | 4b: run the CNN on the board, check every output, save PNGs |
| `power_run.py` | Board continuous mode |
| `bench_4c.py` | Speed comparison (about 1 minute) |
| `fpga_scale.py` | FPGA RTL at 640×480 and 1080p (about 6 minutes) |
| `power_4c.py` | GPU power and energy per frame (about 1 minute) |

## Working method that worked well

1. Write the RTL and a self-checking testbench (plus a Python golden model where needed).
2. Verify in Icarus Verilog, then plant several realistic bugs and confirm the tests catch them.
   Strengthen the tests when they don't.
3. Copy to the VM, run in ISim (the second simulator) and synthesize with XST.
4. Compare the XST report against a written prediction, and explain every difference. Fix the
   slowest path if it's worth it.
5. Build, program, and check on the board from Windows scripts. The board result must match
   simulation exactly, including the cycle counts.
6. Record results, report excerpts, images and lessons in the repo README; commit and push.

## Possible next steps (none required for the trade study)

- **Measure the FPGA's power** if equipment can be borrowed:
  - a TI USB Interface Adapter on J3 (VCCINT directly), or an inline PCIe power meter on the board's
    12 V cable;
  - procedure: idle versus `power_run.py`, as described in the README.
- **Measure system-level power:** a wall meter on the PC (idle versus `power_4c.py`).
- **Better XPower estimate:** simulation activity (SAIF), plus ambient set to room temperature.
- **Wider FPGA design:** for example 4 pixels per clock (about 160 DSPs), to show throughput scaling
  at constant static power. 19 pixels per clock (all DSPs) is possible but risky.
- **Right-sized device:** a power estimate for a smaller, newer FPGA for a deployed design.
- **Faster board I/O** (PCIe on the ML605's ×8 edge connector, or Ethernet) for end-to-end
  comparisons.

## Moving to a new PC: checklist

1. Install the Windows tools above, run `gh auth login`, and clone the three repos into the project folder.
2. **Move the ISE VM** (this keeps the projects and the MAC-locked license):
   - On the old PC: shut the VM down, then **File → Export Appliance** → `.ova`.
   - On the new PC: **File → Import Appliance**, with MAC Address Policy **Include all network
     adapter MAC addresses**.
   - With the VM powered off, re-create the shared folder (name it `FPGA` while you're there) and
     enable USB 2.0. If only USB 1.1 is offered, install the matching Extension Pack.
3. Board: install the Silicon Labs CP210x VCP driver; the UART appears as a COM port.
4. Reinstall the GPU libraries (the two pip commands above). The ROCm device extra depends on the GPU.
5. Check: `python scripts/uart_test.py` (with `top_4a.bit` loaded) or `python scripts/cnn_host.py` (with `top_4b.bit` loaded).
