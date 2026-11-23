// Self-checking testbench for Stage 4b (cnn_board), driven only through the
// UART pins, exactly as the PC does it.
//
// To keep the run short, the UART runs at 8 clocks per bit instead of 1736
// (BAUD = CLK_HZ / 8) and the command timeout is 2^12 clocks. Everything
// else is the board configuration: 96x64 image, the real weights and
// requant parameters, the real protocol.
//
// Checks, in order:
//   1. 'P' answers "4B", 96, 64; an unknown command answers '?'
//   2. a 'W' that stops after 10 bytes is dropped after the timeout, and the
//      board answers the next command normally
//   3. 'W', 'Q', 'I' load weights, requant parameters and the image
//   4. 'R' bank 0: 5828 outputs, exact cycle count; 'O' returns all
//      5828 x 4 bytes, compared with expected_bank0.txt (cnn_ref.py)
//   5. 'R' bank 1 and 'O' again, against expected_bank1.txt (also proves a
//      second run starts cleanly at row 0, column 0)
//   6. LEDs 3..0 = all loaded, last run complete
`timescale 1ns/1ps
module tb_cnn_board;
    localparam CLK_HZ = 200_000_000, DIV = 8, BAUD = CLK_HZ / DIV;
    localparam IMG_W = 96, IMG_H = 64;
    localparam N_IN = IMG_W * IMG_H, N_OUT = (IMG_W - 2) * (IMG_H - 2);
    localparam TIMEOUT_BITS = 12;
    // first image read .. last result written: N_IN reads, then 1 (block RAM)
    // + 19 (cnn_stream) + 1 (result register) clocks for the last pixel
    localparam EXPECT_CYCLES = N_IN + 21;

    reg        clk = 0;
    reg        rx = 1;                  // PC -> board
    wire       tx;                      // board -> PC
    wire [7:0] led;

    cnn_board #(.CLK_HZ(CLK_HZ), .BAUD(BAUD), .IMG_W(IMG_W), .IMG_H(IMG_H),
                .COL_BITS(7), .ROW_BITS(7), .ADDR_BITS(13),
                .TIMEOUT_BITS(TIMEOUT_BITS), .POR_BITS(4)) dut (
        .clk(clk), .uart_rx(rx), .uart_tx(tx), .led(led));

    always #2.5 clk = ~clk;             // 200 MHz

    integer errors = 0;

    // ---------------- PC side of the UART ----------------
    task pc_send(input [7:0] b);
        integer k;
        begin
            rx = 0;                                 // start bit
            repeat (DIV) @(posedge clk);
            for (k = 0; k < 8; k = k + 1) begin
                rx = b[k];
                repeat (DIV) @(posedge clk);
            end
            rx = 1;                                 // stop bit
            repeat (DIV) @(posedge clk);
        end
    endtask

    task pc_recv(output [7:0] b);
        integer k, wait_clks;
        begin
            wait_clks = 0;
            while (tx !== 1'b0) begin
                @(posedge clk);
                wait_clks = wait_clks + 1;
                if (wait_clks > 200000) begin
                    $display("FAIL: no reply from the board (timeout)");
                    $finish;
                end
            end
            repeat (DIV / 2) @(posedge clk);        // middle of the start bit
            for (k = 0; k < 8; k = k + 1) begin
                repeat (DIV) @(posedge clk);
                b[k] = tx;
            end
            repeat (DIV) @(posedge clk);
            if (tx !== 1'b1) begin
                errors = errors + 1;
                $display("FAIL: missing stop bit");
            end
        end
    endtask

    task expect_byte(input [7:0] want, input [8*24-1:0] what);
        reg [7:0] got;
        begin
            pc_recv(got);
            if (got !== want) begin
                errors = errors + 1;
                $display("FAIL: %0s: got 0x%02x, expected 0x%02x", what, got, want);
            end
        end
    endtask

    // ---------------- data ----------------
    reg [7:0]  img [0:N_IN-1];
    reg [7:0]  wts [0:71];
    reg [31:0] qb, qm, qs;
    reg [7:0]  b0, b1, b2, b3;
    reg [31:0] cycles;
    reg [15:0] nout;
    reg [31:0] e [0:3];
    integer    i, k, n, fq, fe, bad;

    task run_and_check(input bank, input [8*24-1:0] expfile);
        begin
            // ---- run ----
            pc_send("R");
            pc_send(bank);
            expect_byte("r", "run reply");
            pc_recv(b0); pc_recv(b1); pc_recv(b2); pc_recv(b3);
            cycles = {b3, b2, b1, b0};
            pc_recv(b0); pc_recv(b1);
            nout = {b1, b0};
            $display("bank %0d run: %0d outputs in %0d clocks (%0.2f us at 200 MHz)",
                     bank, nout, cycles, cycles * 0.005);
            if (nout != N_OUT) begin
                errors = errors + 1;
                $display("FAIL: %0d outputs, expected %0d", nout, N_OUT);
            end
            if (cycles != EXPECT_CYCLES) begin
                errors = errors + 1;
                $display("FAIL: %0d clocks, expected %0d", cycles, EXPECT_CYCLES);
            end
            // ---- read back and compare ----
            fe = $fopen(expfile, "r");
            if (fe == 0) begin $display("ERROR: %0s not found (run scripts/cnn_ref.py)", expfile); $finish; end
            pc_send("O");
            bad = 0;
            for (i = 0; i < N_OUT; i = i + 1) begin
                n = $fscanf(fe, "%h %h %h %h\n", e[0], e[1], e[2], e[3]);
                pc_recv(b0); pc_recv(b1); pc_recv(b2); pc_recv(b3);
                if ({b3, b2, b1, b0} !== {e[3][7:0], e[2][7:0], e[1][7:0], e[0][7:0]}) begin
                    bad = bad + 1;
                    if (bad <= 5)
                        $display("FAIL bank %0d output #%0d (row %0d, col %0d): got %02x %02x %02x %02x, expected %02x %02x %02x %02x",
                                 bank, i, i / (IMG_W-2) + 1, i % (IMG_W-2) + 1,
                                 b0, b1, b2, b3, e[0][7:0], e[1][7:0], e[2][7:0], e[3][7:0]);
                end
            end
            $fclose(fe);
            expect_byte("o", "end of readback");
            errors = errors + bad;
            if (bad == 0)
                $display("bank %0d readback: %0d x 4 bytes match %0s", bank, N_OUT, expfile);
            else
                $display("bank %0d readback: %0d of %0d outputs wrong", bank, bad, N_OUT);
        end
    endtask

    initial begin
        $readmemh("image.hex", img);
        $readmemh("weights.hex", wts);
        repeat (40) @(posedge clk);                 // power-on reset

        // 1. ping, unknown command
        pc_send("P");
        expect_byte("4", "ping byte 0");
        expect_byte("B", "ping byte 1");
        expect_byte(IMG_W % 256, "ping IMG_W low");
        expect_byte(IMG_W / 256, "ping IMG_W high");
        expect_byte(IMG_H % 256, "ping IMG_H low");
        expect_byte(IMG_H / 256, "ping IMG_H high");
        pc_send("x");
        expect_byte("?", "unknown command");

        // 2. an interrupted command is dropped after the timeout
        pc_send("W");
        for (i = 0; i < 10; i = i + 1) pc_send(8'h55);
        repeat ((1 << TIMEOUT_BITS) + 100) @(posedge clk);
        pc_send("P");
        expect_byte("4", "ping after timeout");
        for (i = 0; i < 5; i = i + 1) pc_recv(b0);
        $display("ping, unknown command and timeout recovery checked");

        // 3. load everything
        pc_send("W");
        for (i = 0; i < 72; i = i + 1) pc_send(wts[i]);
        expect_byte("w", "weights ack");

        fq = $fopen("quant.hex", "r");
        pc_send("Q");
        for (i = 0; i < 8; i = i + 1) begin
            n = $fscanf(fq, "%h %h %h\n", qb, qm, qs);
            pc_send(qb[7:0]); pc_send(qb[15:8]); pc_send({4'd0, qb[19:16]});
            pc_send(qm[7:0]); pc_send(qm[15:8]);
            pc_send(qs[7:0]);
        end
        $fclose(fq);
        expect_byte("q", "requant ack");

        pc_send("I");
        for (i = 0; i < N_IN; i = i + 1) pc_send(img[i]);
        expect_byte("i", "image ack");
        $display("weights, requant parameters and image loaded");

        // 4, 5. run both banks
        run_and_check(0, "expected_bank0.txt");
        run_and_check(1, "expected_bank1.txt");

        // 6. LEDs
        if (led[3:0] !== 4'b1111) begin
            errors = errors + 1;
            $display("FAIL: LEDs 3..0 = %b, expected 1111", led[3:0]);
        end

        if (errors == 0)
            $display("PASS: board protocol, 2 runs x %0d pixels x 4 filters match the reference, %0d clocks per frame",
                     N_OUT, EXPECT_CYCLES);
        else
            $display("FAIL: %0d errors", errors);
        $finish;
    end
endmodule
