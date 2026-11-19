// Stage 4a top level for the ML605: clock input buffer + echo_core.
// Pin locations are in ml605_4a.ucf.
//
// The 200 MHz system clock arrives as a differential (LVDS) pair, so it goes
// through IBUFGDS (differential input buffer) and BUFG (global clock buffer,
// which drives the clock to every flip-flop on the chip with low skew).
// These are Xilinx primitives: they exist in ISE/ISim, not in Icarus, which is
// why the testbench simulates echo_core directly.
module top_4a (
    input  wire       SYSCLK_P, SYSCLK_N,   // 200 MHz LVDS, pins J9 / H9
    input  wire       UART_RX,              // from the CP2103 USB-UART bridge (pin J24)
    output wire       UART_TX,              // to the CP2103 (pin J25)
    output wire [7:0] GPIO_LED
);
    wire clk_ibuf, clk;

    IBUFGDS clk_in (.I(SYSCLK_P), .IB(SYSCLK_N), .O(clk_ibuf));
    BUFG    clk_g  (.I(clk_ibuf), .O(clk));

    echo_core #(.CLK_HZ(200_000_000), .BAUD(115_200)) core (
        .clk(clk), .uart_rx(UART_RX), .uart_tx(UART_TX), .led(GPIO_LED));
endmodule
