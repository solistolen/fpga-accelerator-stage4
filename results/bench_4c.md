# Stage 4c results: FPGA vs GPU vs CPU

Same layer everywhere (4 filters, 3x3, int8 weights, bias + ReLU + requant to 8 bits), all outputs identical to the reference. GPU: AMD Radeon RX 7800 XT. CPU: AMD64 Family 25 Model 33 Stepping 2, AuthenticAMD. Times are medians of 50 runs, in µs.

## Compute only (one frame, data already on the device)

| Frame | FPGA ML605, 200 MHz | GPU OpenCL kernel | GPU PyTorch | CPU NumPy |
|---|---|---|---|---|
| 96x64 | 30.8 | 4.0 | 308.2 | 338.2 |
| 640x480 | 1536.1 | 9.6 | 677.7 | 40,685 |
| 1920x1080 | 10,368 | 46.1 | 3434.3 | 310,013 |

## Throughput (frames back to back, compute only)

| Frame | FPGA fps | GPU OpenCL fps | GPU PyTorch fps | CPU NumPy fps |
|---|---|---|---|---|
| 96x64 | 32,441 | 328,019 | 6,738 | 2,957 |
| 640x480 | 651 | 122,456 | 3,671 | 25 |
| 1920x1080 | 96 | 21,359 | 375 | 3 |

## One frame end to end (host memory → result in host memory)

| Frame | GPU OpenCL: upload + kernel + download (wall) | GPU PyTorch: upload + compute + download (wall) | FPGA over the UART: upload + compute + readback |
|---|---|---|---|
| 96x64 | 1.4 + 4.0 + 2.1 (268.1) | 133.9 + 308.2 + 80.9 (639.0) | 533,000 + 30.8 + 2.0 s |
| 640x480 | 86.6 + 9.6 + 121.8 (892.1) | 148.7 + 677.7 + 79.0 (1062.9) | 26.7 s + 1536.1 + 105.9 s |
| 1920x1080 | 132.2 + 46.1 + 786.0 (2939.1) | 156.8 + 3434.3 + 127.7 (3951.1) | 180.0 s + 10,368 + 717.9 s |

## Latency once the last pixel of a frame exists

| Frame | FPGA (streaming: last result 21 clocks after last pixel) | GPU OpenCL (whole frame: upload + kernel + download, wall) |
|---|---|---|
| 96x64 | 0.105 | 268.1 |
| 640x480 | 0.105 | 892.1 |
| 1920x1080 | 0.105 | 2939.1 |

FPGA source per size: 96x64: measured on the ML605; 640x480: cycle-exact simulation of the board RTL; 1920x1080: cycle-exact simulation of the board RTL.
