// Stage 4a: everything that runs on the board, except the clock buffer.
//   - power-on reset (no reset button needed)
//   - LED 7 blinks (heartbeat): proof the FPGA is configured and the clock runs
//   - every byte received on the UART is sent back plus 1, so the PC can tell
//     the data really went through FPGA logic (a plain echo could also come
//     from a wiring loopback)
//   - LEDs 6..0 show the low 7 bits of the last byte received
//
// A 16-byte FIFO sits between receiver and transmitter. Without it, a PC that
// sends back-to-back bytes at a baud rate slightly faster than ours would
// eventually overrun the transmitter (each byte arrives a hair before the
// previous reply has finished going out).
module echo_core #(
    parameter CLK_HZ = 200_000_000,
    parameter BAUD   = 115_200
)(
    input  wire       clk,
    input  wire       uart_rx,
    output wire       uart_tx,
    output wire [7:0] led
);
    // ---- power-on reset: held for 2^16 clocks after configuration ----
    reg [16:0] por = 0;
    always @(posedge clk) if (!por[16]) por <= por + 1;
    wire rst = !por[16];

    // ---- heartbeat: bit 26 toggles every 2^26 clocks (0.34 s at 200 MHz) ----
    reg [26:0] beat = 0;
    always @(posedge clk) beat <= beat + 1;

    // ---- UART ----
    wire       rx_valid;
    wire [7:0] rx_data;
    uart_rx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) urx (
        .clk(clk), .rst(rst), .rx(uart_rx), .valid(rx_valid), .data(rx_data));

    // ---- 16-byte FIFO of replies (received byte + 1) ----
    reg [7:0] fifo [0:15];
    reg [4:0] wr = 0, rd = 0;                   // one extra bit tells full from empty
    wire      empty = (wr == rd);
    wire      full  = (wr[3:0] == rd[3:0]) && (wr[4] != rd[4]);

    wire tx_busy;
    wire tx_start = !empty && !tx_busy;

    always @(posedge clk) begin
        if (rst) begin
            wr <= 0;
            rd <= 0;
        end else begin
            if (rx_valid && !full) begin
                fifo[wr[3:0]] <= rx_data + 8'd1;
                wr <= wr + 1;
            end
            if (tx_start) rd <= rd + 1;
        end
    end

    uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) utx (
        .clk(clk), .rst(rst), .start(tx_start), .data(fifo[rd[3:0]]),
        .tx(uart_tx), .busy(tx_busy));

    // ---- LEDs ----
    reg [6:0] last = 0;
    always @(posedge clk) if (rx_valid) last <= rx_data[6:0];
    assign led = {beat[26], last};
endmodule
