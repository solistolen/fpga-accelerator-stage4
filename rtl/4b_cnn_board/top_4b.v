// Stage 4b top level for the ML605: clock input buffer + cnn_board.
// Same clock, UART and LED pins as Stage 4a (see ml605_4b.ucf).
module top_4b (
    input  wire       SYSCLK_P, SYSCLK_N,   // 200 MHz LVDS, pins J9 / H9
    input  wire       UART_RX,              // from the CP2103 USB-UART bridge (pin J24)
    output wire       UART_TX,              // to the CP2103 (pin J25)
    output wire [7:0] GPIO_LED
);
    wire clk_ibuf, clk;

    IBUFGDS clk_in (.I(SYSCLK_P), .IB(SYSCLK_N), .O(clk_ibuf));
    BUFG    clk_g  (.I(clk_ibuf), .O(clk));

    cnn_board #(.CLK_HZ(200_000_000), .BAUD(115_200),
                .IMG_W(96), .IMG_H(64), .COL_BITS(7), .ROW_BITS(7), .ADDR_BITS(13)) core (
        .clk(clk), .uart_rx(UART_RX), .uart_tx(UART_TX), .led(GPIO_LED));
endmodule
