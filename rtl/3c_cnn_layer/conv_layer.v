// Stage 3b: a small convolution LAYER built from the Stage 3a systolic engine.
//
// N_F filters (default 4) each compute a full 3x3 convolution of the SAME
// window, all in parallel, one window per clock. In CNN terms this is one
// layer with 1 input channel and N_F output channels ("feature maps").
//
// What's new compared with Stage 3a:
//
// 1. One shared skew. In 3a each tap had its own delay line and XST merged
//    the duplicates. Here the skew is built once (tap i's pixel delayed by
//    i clocks) and fanned out to all N_F filters.
//
// 2. Weights loaded at runtime through a write port, into TWO banks (A, B).
//    This is "ping-pong" (double) buffering, the way real accelerators load
//    the next layer's weights while the current one is still running:
//      - every window carries a bank bit saying which weights it uses;
//      - the bank bit goes through the same skew as the pixels, so tap i
//        reads the bank exactly when it processes that window's pixel i.
//    You can therefore switch banks between ANY two windows with no idle
//    clocks, and the windows already in the pipeline finish with the bank
//    they started with.
//
// Rules for the weight port (the testbench follows them, see the README):
//   - Only write the bank that is NOT selected by the windows going in.
//   - A bank's weights may be overwritten starting 8 clock edges after the
//     last window that used it entered: tap 8 reads its weight 8 clocks after
//     its window arrives, and a write landing on that same edge is still safe
//     (the register reads the old value first). Measured with tb_conv_layer:
//     one clock earlier fails.
//   - Don't switch to a bank while it is being rewritten.
//
// Weight addressing: w_addr = filter*9 + tap, tap 0 = top-left ... tap 8 =
// bottom-right (same order as win). Weights are signed int8.
//
// Pipeline: identical to conv3x3_sys, LATENCY = 11 clocks from a window on
// `win` to its sums on `sums`. out_valid follows in_valid by 11 clocks.
module conv_layer #(
    parameter N_F   = 4,        // number of filters (output channels)
    parameter SUM_W = 20
)(
    input  wire                     clk, rst,
    // windows in
    input  wire                     in_valid,
    input  wire [71:0]              win,        // 9 unsigned pixels, p0 = win[7:0]
    input  wire                     bank,       // weights for THIS window: 0 = A, 1 = B
    // weight write port
    input  wire                     w_we,
    input  wire                     w_bank,     // bank to write: 0 = A, 1 = B
    input  wire [5:0]               w_addr,     // filter*9 + tap
    input  wire [7:0]               w_data,     // signed int8 weight
    // results out
    output wire                     out_valid,
    output wire [N_F*SUM_W-1:0]     sums        // filter f = sums[f*SUM_W +: SUM_W]
);
    localparam N_T = 9;         // taps per filter
    localparam LAT = 11;

    // ---------------- weight banks ----------------
    // Stored as plain flip-flops: 36 separate 8-bit registers per bank, packed
    // into one vector (weight a = wA[8*a +: 8]), each with its own write enable.
    //
    // Why not an array (reg [7:0] wA [0:35])? Every tap reads its own weight
    // at the same time, i.e. 36 read ports. XST turned the array into a small
    // LUT RAM and, because one RAM has only one or two read ports, built a
    // separate copy for every tap: 72 RAMs = 864 LUTs for 576 bits, and the
    // slow RAM read (1.67 ns) became the critical path. Registers give every
    // tap its own output for free. Addresses 36..63 are ignored.
    localparam N_W = N_F * N_T;
    reg [8*N_W-1:0] wA, wB;
    integer a;

    always @(posedge clk) begin
        for (a = 0; a < N_W; a = a + 1)
            if (w_we && w_addr == a) begin
                if (w_bank) wB[8*a +: 8] <= w_data;
                else        wA[8*a +: 8] <= w_data;
            end
    end

    // ---------------- shared skew ----------------
    // For each tap i: {bank, pixel i} delayed by i clocks. Built once, used by
    // every filter. xs/bs are the skewed pixel and bank bit for tap i.
    wire [8*N_T-1:0] xs;
    wire [N_T-1:0]   bs;

    genvar i, f;
    generate
        for (i = 0; i < N_T; i = i + 1) begin : skew
            if (i == 0) begin : none
                assign xs[7:0] = win[7:0];
                assign bs[0]   = bank;
            end else begin : dly
                reg [8:0] sr [0:i-1];       // {bank, pixel}, i clocks deep
                integer k;
                always @(posedge clk) begin
                    sr[0] <= {bank, win[8*i +: 8]};
                    for (k = 1; k < i; k = k + 1)
                        sr[k] <= sr[k-1];
                end
                assign xs[8*i +: 8] = sr[i-1][7:0];
                assign bs[i]        = sr[i-1][8];
            end
        end
    endgenerate

    // ---------------- N_F systolic chains ----------------
    // pc[f*(N_T+1) + i] = partial sum going INTO tap i of filter f
    wire signed [SUM_W-1:0] pc [0:N_F*(N_T+1)-1];

    generate
        for (f = 0; f < N_F; f = f + 1) begin : filt
            assign pc[f*(N_T+1)] = {SUM_W{1'b0}};
            for (i = 0; i < N_T; i = i + 1) begin : tap
                sys_mac #(.SUM_W(SUM_W)) m (
                    .clk  (clk),
                    .x    (xs[8*i +: 8]),
                    // tap i picks its weight from the bank this window was given
                    .w    (bs[i] ? wB[8*(f*N_T + i) +: 8] : wA[8*(f*N_T + i) +: 8]),
                    .pin  (pc[f*(N_T+1) + i]),
                    .pout (pc[f*(N_T+1) + i + 1])
                );
            end
            assign sums[f*SUM_W +: SUM_W] = pc[f*(N_T+1) + N_T];
        end
    endgenerate

    // ---------------- valid flag ----------------
    reg [LAT-1:0] v_pipe;
    always @(posedge clk) begin
        if (rst) v_pipe <= 0;
        else     v_pipe <= {v_pipe[LAT-2:0], in_valid};
    end
    assign out_valid = v_pipe[LAT-1];
endmodule


// One multiply-accumulate step of a systolic chain (Stage 3a's sys_tap
// without the delay line, which now lives in conv_layer and is shared).
// Everything here fits in one DSP48E1 with AREG/BREG, MREG and PREG on.
module sys_mac #(parameter SUM_W = 20)(
    input  wire                     clk,
    input  wire [7:0]               x,      // unsigned pixel (already skewed)
    input  wire signed [7:0]        w,      // signed weight (already bank-selected)
    input  wire signed [SUM_W-1:0]  pin,    // partial sum from the previous tap
    output reg  signed [SUM_W-1:0]  pout    // partial sum to the next tap
);
    reg signed [8:0]  a_r;      // pixel with a 0 on top (0..255)
    reg signed [7:0]  b_r;
    reg signed [16:0] m_r;      // fits in 16 bits since a_r >= 0; see Stage 3a

    always @(posedge clk) begin
        a_r  <= {1'b0, x};
        b_r  <= w;
        m_r  <= a_r * b_r;
        pout <= pin + m_r;
    end
endmodule
