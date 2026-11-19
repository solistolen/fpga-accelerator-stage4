# FPGA Accelerator, Stage 4: running on the ML605 board

Stage 4 takes the accelerator from simulation onto the real Xilinx ML605 board (Virtex-6
XC6VLX240T-1FF1156). Earlier stages: [stage 2](https://github.com/solistolen/fpga-accelerator-stage2)
(MAC unit, Sobel edge detector) and [stage 3](https://github.com/solistolen/fpga-accelerator-stage3)
(systolic engine → complete int8 CNN layer at ~365 MHz in synthesis).

| Step | What | Status |
|---|---|---|
| **4a** | Board bring-up: heartbeat LED + UART echo | Verified in simulation; **not yet run on the board** |
| 4b | The CNN layer behind the UART: PC sends weights, parameters and an image; the board returns the 4 feature maps and a cycle count | Planned |
| 4c | Measured FPGA vs GPU comparison | Planned |

See [PROJECT_CONTEXT.md](PROJECT_CONTEXT.md) for the full project history, environment and how to
continue.

## Stage 4a: heartbeat LED and UART echo

The first design that runs on the board. It does nothing clever on purpose: it proves every piece
of the path from Verilog to hardware works (clock, pins, place-and-route, bitstream, programming,
PC link) before the CNN goes on the board.

- **LED 7 blinks** (about 1.5 times a second): the FPGA is configured and the 200 MHz clock runs.
- **UART echo + 1**: every byte the PC sends over the board's USB-UART comes back plus 1 (so a
  wiring loopback can't fake it). A 16-byte FIFO absorbs baud-rate mismatch between PC and FPGA.
- **LEDs 6–0** show the low 7 bits of the last byte received.
- Reset is generated internally at power-up (no reset button needed).

| File | What it is |
|---|---|
| rtl/4a_board_bringup/top_4a.v | Top level: 200 MHz LVDS clock → `IBUFGDS` → `BUFG` → `echo_core` |
| rtl/4a_board_bringup/echo_core.v | Power-on reset, heartbeat, UART receiver → FIFO (+1) → UART transmitter, LEDs |
| rtl/4a_board_bringup/uart_rx.v, uart_tx.v | 8N1 UART, 115200 baud (1736 clocks per bit at 200 MHz) |
| rtl/4a_board_bringup/ml605_4a.ucf | Pins and the 200 MHz timing constraint |
| sim/tb_echo_core.v | Testbench: 900 bytes in three phases (PC baud exact, 2.5% fast, 2.5% slow) |
| scripts/uart_test.py | PC side (Windows): checks the echo and measures throughput |

### Pins (UG534, ML605 Hardware User Guide)

| Port | Pin | Notes |
|---|---|---|
| SYSCLK_P / SYSCLK_N | J9 / H9 | 200 MHz 2.5 V LVDS oscillator U11 |
| UART_RX (FPGA input) | **J24** | board net `USB_1_TX` = CP2103 TXD (pin 25) |
| UART_TX (FPGA output) | **J25** | board net `USB_1_RX` = CP2103 RXD (pin 24) |
| GPIO_LED 0–7 | AC22, AC24, AE22, AE23, AB23, AG23, AE24, AD24 | |

The board's `USB_1_RX/TX` names describe the CP2103 bridge's pins, so the FPGA *receives* on the
net called `USB_1_TX`. Checked against UG534's master UCF (Appendix D), its USB-to-UART table
(Table 1-15), and the CP2103 datasheet.

### Verification (Icarus Verilog 12)

`tb_echo_core`: `PASS: 900 bytes echoed +1 in order (PC exact, 2.5% fast, 2.5% slow)`

| Planted bug | Result | Caught in |
|---|---|---|
| Receiver bit order reversed | FAIL | all phases |
| Receiver samples at bit edges instead of the middle | FAIL | PC 2.5% slow |
| Plain echo (no +1) | FAIL | all phases |
| Transmitter drops the stop bit | FAIL | PC 2.5% fast (replies back to back) |
| FIFO only 2 deep | FAIL | PC 2.5% fast |

The first version of the testbench ran only at the exact baud rate and missed the 2nd and 4th
bugs: with perfect timing, edge sampling still lands on the right bit, and a missing stop bit hides
in the idle time between replies. Hence the three phases, and a check that no two replies start
less than one 10-bit frame apart.

```
cd sim
iverilog -o echo_sim tb_echo_core.v ../rtl/4a_board_bringup/echo_core.v ../rtl/4a_board_bringup/uart_rx.v ../rtl/4a_board_bringup/uart_tx.v
vvp echo_sim
```

### On the board

**1. Build in ISE.** New project (xc6vlx240t, ff1156, -1, XST, ISim, Verilog). Add `top_4a.v`,
`echo_core.v`, `uart_rx.v`, `uart_tx.v` (association **All**), `tb_echo_core.v` (**Simulation**)
and `ml605_4a.ucf` (**Implementation**). Top = `top_4a` → **Generate Programming File** (runs
synthesis, translate, map, place & route, bitgen → `top_4a.bit`). Check the Design Summary says
**All Constraints Met** (`TS_sysclk`, 5 ns). If Map/Bitgen complains about `DIFF_TERM` on SYSCLK,
delete `| DIFF_TERM = TRUE` from both SYSCLK lines and rebuild.

**2. Connect.** 12 V power, power switch on. Two USB cables: the **USB JTAG** mini-B (programming)
and the **USB UART** mini-B (CP2103). If ISE runs in a VirtualBox VM: pass only the JTAG device to
the VM (**Devices → USB**); leave the Silicon Labs CP210x on Windows.

**3. Program.** iMPACT → Boundary Scan → Initialize Chain → assign `top_4a.bit` to the
xc6vlx240t (bypass other devices) → Program. **LED 7 should blink.**

**4. Test the UART (Windows).** Device Manager → Ports → "Silicon Labs CP210x USB to UART Bridge
(COMx)" (install the CP210x driver if missing). `pip install pyserial`, then
`python scripts/uart_test.py` (finds the port itself; or give it, e.g. `COM5`; `--list` shows all
ports). Expected:

```
  all values 0..255 (16 at a time)     PASS (256 bytes)
  2000 random bytes in one burst       PASS (2000 bytes)
  throughput: ~11500 bytes/s each way
PASS: the ML605 UART link works
```

| Symptom | Likely cause |
|---|---|
| iMPACT finds no cable | JTAG USB not passed to the VM, or cable drivers missing in the VM |
| Programmed, but LED 7 doesn't blink | Clock not running: check the Map report for SYSCLK pin/IOSTANDARD messages |
| LED 7 blinks, but no UART reply | Wrong COM port, or the UART USB was passed to the VM |
| Replies but wrong values | Baud mismatch: script and FPGA must both be 115200 |
