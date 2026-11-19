// UART receiver, 8N1 (8 data bits, no parity, 1 stop bit), LSB first.
//
// The line idles high. A byte is: start bit (0), 8 data bits, stop bit (1).
// The receiver waits for the falling edge of the start bit, waits half a bit
// to land in the middle of it, then samples every DIV clocks, i.e. in the
// middle of each data bit and of the stop bit.
//
// rx comes from outside the FPGA and is not synchronous to clk, so it goes
// through two flip-flops first (a synchronizer) before any logic looks at it.
module uart_rx #(
    parameter CLK_HZ = 200_000_000,
    parameter BAUD   = 115_200
)(
    input  wire       clk, rst,
    input  wire       rx,           // serial line, idles high
    output reg        valid,        // 1 for one clock when data holds a new byte
    output reg  [7:0] data
);
    localparam DIV  = CLK_HZ / BAUD;    // clocks per bit (200 MHz / 115200 = 1736)
    localparam HALF = DIV / 2;

    localparam IDLE = 2'd0, START = 2'd1, BITS = 2'd2, STOP = 2'd3;

    reg        rx_s1 = 1'b1, rx_s2 = 1'b1;  // synchronizer
    reg [1:0]  state = IDLE;
    reg [15:0] cnt   = 0;
    reg [2:0]  idx   = 0;
    reg [7:0]  sh    = 0;

    always @(posedge clk) begin
        rx_s1 <= rx;
        rx_s2 <= rx_s1;
        valid <= 1'b0;

        if (rst) begin
            state <= IDLE;
            cnt   <= 0;
        end else case (state)
            IDLE:
                if (!rx_s2) begin                   // falling edge: start bit begins
                    state <= START;
                    cnt   <= 0;
                end
            START:                                  // go to the middle of the start bit
                if (cnt == HALF - 1) begin
                    cnt <= 0;
                    if (!rx_s2) begin state <= BITS; idx <= 0; end
                    else         state <= IDLE;     // just a glitch
                end else cnt <= cnt + 1;
            BITS:                                   // middle of each data bit
                if (cnt == DIV - 1) begin
                    cnt <= 0;
                    sh  <= {rx_s2, sh[7:1]};        // LSB arrives first
                    if (idx == 3'd7) state <= STOP;
                    else             idx   <= idx + 1;
                end else cnt <= cnt + 1;
            STOP:                                   // middle of the stop bit
                if (cnt == DIV - 1) begin
                    cnt   <= 0;
                    state <= IDLE;
                    if (rx_s2) begin                // a valid stop bit: keep the byte
                        valid <= 1'b1;
                        data  <= sh;
                    end
                end else cnt <= cnt + 1;
        endcase
    end
endmodule
