# Stage 4c: energy per frame

GPU: AMD Radeon RX 7800 XT, board power measured with its own sensor (idle 19.9 W), frames back to back for 6 s per row. FPGA: XPower Analyzer estimate for the routed ML605 design at 200 MHz (3.579 W total = 3.442 W static + 0.137 W dynamic), with the continuous-mode frame rate.

| Frame | | Power (W) | Frames/s | **Energy per frame (mJ)** | Above idle (mJ) |
|---|---|---|---|---|---|
| 96x64 | GPU OpenCL | 69.4 | 270,710 | **0.256** | 0.183 |
| | GPU PyTorch | 46.3 | 6,739 | **6.867** | 3.917 |
| | FPGA (XPower estimate) | 3.58 | 32,420 | **0.110** | 0.004 (dynamic only) |
| 640x480 | GPU OpenCL | 233.5 | 116,457 | **2.005** | 1.834 |
| | GPU PyTorch | 198.6 | 3,731 | **53.2** | 47.9 |
| | FPGA (XPower estimate) | 3.58 | 651 | **5.498** | 0.210 (dynamic only) |
| 1920x1080 | GPU OpenCL | 275.2 | 20,237 | **13.6** | 12.6 |
| | GPU PyTorch | 199.7 | 370 | **539.1** | 485.4 |
| | FPGA (XPower estimate) | 3.58 | 96 | **37.1** | 1.420 (dynamic only) |
