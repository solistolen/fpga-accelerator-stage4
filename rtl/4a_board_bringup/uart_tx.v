// UART transmitter, 8N1, LSB first.
// Pulse start for one clock with data; busy stays high for the 10 bit times
// (start bit, 8 data bits, stop bit) it takes to send the byte.
module uart_tx #(
    parameter CLK_HZ = 200_000_000,
    parameter BAUD   = 115_200
)(
    input  wire       clk, rst,
    input  wire       start,
    input  wire [7:0] data,
    output reg        tx = 1'b1,    // serial line, idles high
    output wire       busy
);
    localparam DIV = CLK_HZ / BAUD;

    reg [9:0]  sh  = 10'h3FF;       // {stop, data[7:0], start}, sent LSB first
    reg [3:0]  n   = 0;             // bits left to send
    reg [15:0] cnt = 0;

    assign busy = (n != 0);

    always @(posedge clk) begin
        if (rst) begin
            n  <= 0;
            tx <= 1'b1;
        end else if (!busy) begin
            if (start) begin
                sh  <= {1'b1, data, 1'b0};
                n   <= 4'd10;
                cnt <= 0;
                tx  <= 1'b0;                // start bit goes out right away
            end
        end else if (cnt == DIV - 1) begin
            cnt <= 0;
            n   <= n - 1;
            sh  <= {1'b1, sh[9:1]};
            tx  <= (n == 1) ? 1'b1 : sh[1]; // next bit (line stays high when done)
        end else
            cnt <= cnt + 1;
    end
endmodule
