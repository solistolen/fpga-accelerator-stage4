// Testbench for Stage 4a echo_core, at the real settings (200 MHz, 115200 baud).
// Plays the PC: sends bytes back to back on uart_rx, receives everything that
// comes back on uart_tx, and checks every reply is the sent byte + 1, in order,
// with none missing, and that every reply is a full 10-bit frame.
//
// A real USB-UART chip's baud rate never exactly matches the FPGA's, so the
// run has three phases of N_BYTES each:
//   1. PC at exactly 115200 baud (8680.6 ns per bit; the FPGA's 1736-clock
//      divider gives 8680.0 ns)
//   2. PC 2.5% FAST:  replies back up, so the FIFO and back-to-back frames
//      are exercised (a transmitter that skips the stop bit fails here)
//   3. PC 2.5% SLOW:  the receiver's sampling point drifts toward the bit
//      edges (a receiver that samples at the edge instead of the middle
//      fails here)
`timescale 1ns/1ps
module tb_echo_core;
    localparam N_BYTES = 300;
    localparam N_TOTAL = 3 * N_BYTES;
    localparam real FPGA_BIT_NS = 1736 * 5.0;

    reg        clk = 0;
    reg        rx  = 1'b1;          // PC -> FPGA
    wire       tx;                  // FPGA -> PC
    wire [7:0] led;

    echo_core #(.CLK_HZ(200_000_000), .BAUD(115_200)) dut (
        .clk(clk), .uart_rx(rx), .uart_tx(tx), .led(led));

    always #2.5 clk = ~clk;         // 200 MHz

    // ---------------- PC transmitter ----------------
    reg [7:0] sent [0:N_TOTAL-1];
    real      pc_bit_ns;
    integer   i, b, ph;
    task send_byte(input [7:0] d);
        begin
            rx = 1'b0; #(pc_bit_ns);                        // start bit
            for (b = 0; b < 8; b = b + 1) begin rx = d[b]; #(pc_bit_ns); end
            rx = 1'b1; #(pc_bit_ns);                        // stop bit
        end
    endtask

    // ---------------- PC receiver ----------------
    integer  got = 0, errors = 0, k;
    reg [7:0] r;
    realtime last_start = -1.0e9;
    always begin
        @(negedge tx);                                      // start bit
        // a frame is 10 bits (start, 8 data, stop): two starts closer than that
        // mean a bit is missing, even if the line happened to be idle (high)
        if ($realtime - last_start < FPGA_BIT_NS * 10 - 1.0) begin
            errors = errors + 1;
            if (errors <= 10) $display("FAIL: reply #%0d started %.0f ns after the previous one (a frame is %.0f ns)",
                                       got, $realtime - last_start, FPGA_BIT_NS * 10);
        end
        last_start = $realtime;
        #(FPGA_BIT_NS * 1.5);                               // middle of data bit 0
        for (k = 0; k < 8; k = k + 1) begin r[k] = tx; #(FPGA_BIT_NS); end
        if (tx !== 1'b1) begin
            errors = errors + 1;
            if (errors <= 10) $display("FAIL: reply #%0d has a bad stop bit", got);
        end
        if (got < N_TOTAL && r !== sent[got] + 8'd1) begin
            errors = errors + 1;
            if (errors <= 10) $display("FAIL: reply #%0d = %02x, expected %02x", got, r, sent[got] + 8'd1);
        end
        got = got + 1;
    end

    initial begin
        for (i = 0; i < N_TOTAL; i = i + 1)
            sent[i] = (i < 256) ? i : $random;              // every value 0..255, then random
        #(400_000);                                         // power-on reset: 2^16 clocks = 328 us

        for (ph = 0; ph < 3; ph = ph + 1) begin
            pc_bit_ns = (ph == 0) ? 8680.6 : (ph == 1) ? 8680.6 * 0.975 : 8680.6 * 1.025;
            for (i = ph * N_BYTES; i < (ph + 1) * N_BYTES; i = i + 1) send_byte(sent[i]);
            #(FPGA_BIT_NS * 10 * 20);                       // let the FIFO drain
            $display("phase %0d (PC bit %.1f ns): %0d replies so far, %0d errors", ph + 1, pc_bit_ns, got, errors);
        end

        if (led[6:0] !== sent[N_TOTAL-1][6:0]) begin
            errors = errors + 1;
            $display("FAIL: LEDs show %02x, expected %02x", led[6:0], sent[N_TOTAL-1][6:0]);
        end
        if (errors == 0 && got == N_TOTAL)
            $display("PASS: %0d bytes echoed +1 in order (PC exact, 2.5%% fast, 2.5%% slow)", got);
        else
            $display("FAIL: %0d errors, %0d replies (expected %0d)", errors, got, N_TOTAL);
        $finish;
    end
endmodule
