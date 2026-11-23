// Stage 4c: cnn_stream (the exact RTL running on the board) at video frame sizes.
//
// The board build only holds 96x64 frames in its memories, so for 640x480 and
// 1920x1080 this testbench streams a frame straight into cnn_stream, one pixel
// per clock with no gaps (as cnn_board does), and reports:
//   - the clocks from the first pixel in to the last result out
//   - every result, to scale_out.hex, which fpga_scale.py compares with NumPy
// Set the size with -P on the iverilog command line (fpga_scale.py does this):
//   -Ptb_cnn_scale.IMG_W=640 -Ptb_cnn_scale.IMG_H=480 -Ptb_cnn_scale.COL_BITS=10 -Ptb_cnn_scale.ROW_BITS=9
// Inputs: scale_img.hex (W*H bytes), weights.hex, quant.hex (bank A is used).
`timescale 1ns/1ps
module tb_cnn_scale;
    parameter IMG_W = 640, IMG_H = 480, COL_BITS = 10, ROW_BITS = 9;
    localparam N_IN = IMG_W * IMG_H, N_OUT = (IMG_W - 2) * (IMG_H - 2);
    localparam N_F = 4, SUM_W = 20;

    reg              clk = 0, rst = 1;
    reg              in_valid = 0;
    reg  [7:0]       in_pix = 0;
    reg              w_we = 0;
    reg  [5:0]       w_addr = 0;
    reg  [7:0]       w_data = 0;
    reg              q_we = 0;
    reg  [1:0]       q_filt = 0;
    reg  [SUM_W-1:0] q_bias = 0;
    reg  [15:0]      q_mult = 0;
    reg  [4:0]       q_shift = 0;
    wire             out_valid;
    wire [31:0]      out_q;

    cnn_stream #(.IMG_W(IMG_W), .COL_BITS(COL_BITS), .ROW_BITS(ROW_BITS), .N_F(N_F), .SUM_W(SUM_W)) dut (
        .clk(clk), .rst(rst), .in_valid(in_valid), .in_pix(in_pix), .in_bank(1'b0),
        .w_we(w_we), .w_bank(1'b0), .w_addr(w_addr), .w_data(w_data),
        .q_we(q_we), .q_bank(1'b0), .q_filt(q_filt), .q_bias(q_bias), .q_mult(q_mult), .q_shift(q_shift),
        .out_valid(out_valid), .out_q(out_q));

    always #2.5 clk = ~clk;

    reg [7:0]  img [0:N_IN-1];
    reg [7:0]  wts [0:71];
    reg [31:0] qb, qm, qs;
    integer    i, n, fq, fout, got = 0;
    integer    clk_now = 0, t_first = -1, t_last = -1;

    always @(posedge clk) begin
        clk_now = clk_now + 1;
        if (in_valid && t_first < 0) t_first = clk_now;
        if (out_valid) begin
            $fdisplay(fout, "%02x %02x %02x %02x", out_q[7:0], out_q[15:8], out_q[23:16], out_q[31:24]);
            got = got + 1;
            t_last = clk_now;
        end
    end

    initial begin
        $readmemh("scale_img.hex", img);
        $readmemh("weights.hex", wts);
        fout = $fopen("scale_out.hex", "w");
        fq   = $fopen("quant.hex", "r");
        repeat (3) @(posedge clk);
        @(negedge clk) rst = 0;
        for (i = 0; i < 36; i = i + 1) begin          // bank A weights
            @(negedge clk); w_we = 1; w_addr = i; w_data = wts[i];
        end
        @(negedge clk) w_we = 0;
        for (i = 0; i < 4; i = i + 1) begin           // bank A requant
            n = $fscanf(fq, "%h %h %h\n", qb, qm, qs);
            @(negedge clk); q_we = 1; q_filt = i; q_bias = qb[SUM_W-1:0]; q_mult = qm[15:0]; q_shift = qs[4:0];
        end
        @(negedge clk) q_we = 0;
        repeat (5) @(posedge clk);

        for (i = 0; i < N_IN; i = i + 1) begin        // one pixel per clock, no gaps
            @(negedge clk); in_valid = 1; in_pix = img[i];
        end
        @(negedge clk) in_valid = 0;
        repeat (40) @(posedge clk);
        $fclose(fout);
        // t_last - t_first + 1 = clocks from the first pixel entering to the last result leaving
        $display("SCALE %0dx%0d: %0d outputs (expected %0d), %0d clocks from first pixel in to last result out",
                 IMG_W, IMG_H, got, N_OUT, t_last - t_first + 1);
        $finish;
    end
endmodule
