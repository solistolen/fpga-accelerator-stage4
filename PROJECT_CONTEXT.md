# Project context and handoff

Everything needed to continue this project on another computer (or in a new Claude session):
what's been built, what was learned, how the tools are set up, and what comes next. Written at
the end of Stage 4a (2026-11-19).

## Goal

A small image-processing / CNN accelerator in Verilog on a **Xilinx ML605** (Virtex-6
XC6VLX240T-1FF1156), built one measured step at a time. It is the FPGA side of an **FPGA-vs-GPU
comparison for a real-time video pipeline** (a senior design trade-study task): build the same
image operation on both, measure processing time, transfer time and latency, and recommend a
platform.

## Repositories

| Repo | Contents |
|---|---|
| [fpga-accelerator-stage2](https://github.com/solistolen/fpga-accelerator-stage2) | Stage 1 MAC, 2a pipelined MAC, 2b–2e Sobel edge detector (5 versions) |
| [fpga-accelerator-stage3](https://github.com/solistolen/fpga-accelerator-stage3) | 3a systolic engine, 3b 4-filter conv layer, 3c complete int8 CNN layer |
| [fpga-accelerator-stage4](https://github.com/solistolen/fpga-accelerator-stage4) | 4a board bring-up (this repo) |

Each repo has RTL, testbenches, golden models (Python), XST report excerpts, images and a README
with results and planted-bug tables. Commits are authored as `solistolen` with the GitHub noreply
address.

## Results so far (XST synthesis estimates, ISE 14.7, IMG_W = 640)

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

All stages pass their testbenches in **both ISim 14.7 and Icarus Verilog 12**. 640×480 at 30 fps
needs ≈9.2 Mpixel/s; every design does one pixel per clock, so 365 MHz is ≈40× headroom.

Recurring lessons:
- Pipeline until the slowest path moves; then look at what it moved to.
- Control signals into a DSP48E1's mode pins (OPMODE, ~1.9 ns setup) are slow: turn the decision
  into registered data a stage earlier (2a, 3c).
- How storage is written decides the hardware (3b: array vs registers = 864 LUTs vs 576 FFs).
- Every valid/bank flag must be delayed exactly as much as its data; off-by-one errors often only
  show at switch points, so tests need many switch points (3b, 3c).
- Tests must be tried against planted bugs; several first versions missed bugs (3a tap 4, 3b bank
  timing, 4a baud mismatch).

## Stage 3c design in one paragraph

`cnn_stream`: pixels (8-bit, with a per-pixel bank bit) → row/column counters, BRAM line buffer,
3×3 window → `conv_layer` (4 filters × 9 systolic DSP taps, shared skew delay, two weight banks
selected per window, weights in registers; latency 11) → `requant` per filter (bias, ReLU,
`round(r × mult / 2^shift)`, saturate to 0..255; two parameter banks; latency 6) → 4 output
maps of 8-bit pixels. Total latency 19 clocks. Weight-port rule: rewrite a bank ≥ 8 clocks after
the last window that used it; requant parameters ≥ 12 clocks.

## Stage 4 plan

- **4a (passed on the board, 2026-11-23):** heartbeat LED + UART echo (+1). Timing met at 200 MHz
  after place and route (score 0), LED 7 blinks, `scripts/uart_test.py` PASS at 11,453 bytes/s
  (99.4% of 115200 baud). JTAG chain = `xccace` (bypass) + `xc6vlx240t`. Windows needed the
  Silicon Labs CP210x VCP driver.
- **4b (passed on the board, 2026-11-23; all 46,624 output bytes match, 40 DSPs, 11 BRAMs, timing
  met at 200 MHz):** `cnn_board` puts `cnn_stream` behind the
  UART. The PC sends weights (`W`), requant parameters (`Q`) and a 96×64 image (`I`) into an image
  BRAM. `R` + bank streams the frame at one pixel per clock into a result BRAM and returns the
  cycle count; `O` reads back the 4 maps. `scripts/cnn_host.py` checks every byte against
  `scripts/cnn_ref.py`. Simulated result: 6165 clocks per frame (6144 + 21), 30.8 µs at 200 MHz.
  `tb_cnn_board` drives only the UART pins; 7 planted bugs were all caught. The `cnn_stream` reset
  before every frame is required, because its row counter doesn't wrap. ISE project: `Board4b`.
- **4c:** GPU side of the comparison (same filters on the PC GPU, e.g. Python/OpenCV or
  PyTorch), and the measured FPGA-vs-GPU table: compute time, transfer time, latency. Faster
  board I/O (Ethernet or PCIe) is a possible later step.

## ML605 facts (checked against UG534)

- 200 MHz system clock: LVDS on **J9 (P) / H9 (N)**.
- FPGA package pins (ball positions such as J24) are not the board's connector numbers. On the
  board, **J21** is the USB UART mini-B connector and **J22** is the USB JTAG connector.
- USB-UART (CP2103): the FPGA **receives on J24** (net `USB_1_TX`) and **transmits on J25** (net
  `USB_1_RX`) — the net names are from the bridge's point of view.
- LEDs 0–7: AC22, AC24, AE22, AE23, AB23, AG23, AE24, AD24.
- CPU_RESET button: H10, active high (I/O standard not confirmed, so 4a uses an internal power-on
  reset instead).
- I/O standards used: LVDS_25 (+ DIFF_TERM) for SYSCLK, LVCMOS25 for UART and LEDs.

## Environment

**ISE 14.7 runs in a VirtualBox Linux VM** (user `ise`). Files are moved through a VirtualBox
shared folder. On the main PC (from 2026-11-22) the share is named `FPGA` and maps to
`D:\FPGA Accelerator (Virtex 6 ML605)`, which holds clones of the three repos (the original PC used
a share named `Downloads`):

```
sudo mount -t vboxsf FPGA /mnt/share             # once per VM boot
cp /mnt/share/fpga-accelerator-stageN/<path>/*.v /home/ise/<Project>/
```

`mount.vboxsf: … Protocol error` means no share with that name exists: VirtualBox names a new
share after the folder unless you type a name. The VM's Guest Additions are 5.1.30 (host
VirtualBox 7.2.16), and that works.

ISE projects in the VM (one per top module): `/home/ise/MACmodule` (stage 1/2a), `Sobel` (2b–3a),
`Conv` (3b), `CNN` (3c), `Board4a` (4a). In ISE: Add Source with association **All** for design
files, **Simulation** for testbenches, **Implementation** for UCFs; ISim: Simulate Behavioral
Model → `run all`; after replacing a file click **Yes** to reload and use **Re-launch** in ISim.
Shut the VM down with VirtualBox **Machine → ACPI Shutdown** (the VM's System menu has no shut
down item) or `sudo poweroff`.

**Windows side:** Git, GitHub CLI (`gh auth login`), Icarus Verilog (`C:\iverilog\bin`), Python
with `pyserial`. To set up a new PC (admin PowerShell):

```
winget install --id Git.Git -e --source winget
winget install --id GitHub.cli -e --source winget
winget install --id Icarus.Verilog -e --source winget
pip install pyserial
```

Note: pip run from inside the Claude desktop app installs per-user packages into the app's
private folder (Windows redirects `AppData\Roaming` for packaged apps), invisible to a normal
terminal. Run `pip install` from your own terminal, or use `pip install --target <folder>`.

## Working method that worked well

1. Write the RTL and a self-checking testbench (plus a Python golden model where needed).
2. Verify in Icarus Verilog, then plant several realistic bugs and confirm the tests catch them;
   strengthen the tests when they don't.
3. Copy to the VM, run in ISim (second simulator) and synthesize with XST.
4. Compare the XST report against a written prediction; explain every difference; fix the
   slowest path if it's worth it.
5. Record results, report excerpts, images and lessons in the repo README; commit and push.

## Moving to a new PC — checklist

1. Install the tools above; `gh auth login`; clone the three repos.
2. Move the ISE VM: in VirtualBox Manager on the old PC, shut it down, **File → Export
   Appliance** → `.ova`; on the new PC **File → Import Appliance**. Re-create the shared folder
   (Settings → Shared Folders → Downloads, name `Downloads`). Install the VirtualBox Extension
   Pack for USB 2.0 (board JTAG passthrough).
3. Board: Silicon Labs CP210x driver if the UART doesn't appear as a COM port.
4. Continue with Stage 4a "On the board" in the README.
