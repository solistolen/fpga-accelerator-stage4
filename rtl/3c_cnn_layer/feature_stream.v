// Stage 3b: streaming feature extractor. A camera-style pixel stream goes in;
// N_F feature maps (one per filter of conv_layer) come out, one pixel of each
// per clock.
//
// The front end (row/column counters, block-RAM line buffer, 3x3 window) is
// the same as the Stage 3a Sobel design. What's different:
//   - the window feeds conv_layer (N_F filters, runtime weights, two banks)
//     instead of two fixed-coefficient engines;
//   - every input pixel carries a bank bit (in_bank). A window uses the bank
//     of its newest (bottom-right) pixel, so switching in_bank between two
//     pixels switches the weights cleanly from that window on;
//   - there's no magnitude stage: the raw signed filter outputs come out,
//     the way a CNN layer's outputs would before its activation (Stage 3c).
//
// Latency: 1 (input reg) + 1 (window) + 11 (conv_layer) = 13 clocks.
//
// Stage 3c addition: out_bank, the bank bit of the window each result came
// from, delayed to line up with out_f, so a later stage (requant) can use the
// same bank for its own parameters. Otherwise identical to Stage 3b.
module feature_stream #(
    parameter IMG_W    = 640,
    parameter COL_BITS = 10,
    parameter ROW_BITS = 10,
    parameter N_F      = 4,
    parameter SUM_W    = 20
)(
    input  wire                 clk, rst,
    // pixels in
    input  wire                 in_valid,
    input  wire [7:0]           in_pix,
    input  wire                 in_bank,    // weight bank for windows ending at this pixel
    // weight write port (see conv_layer.v for the rules)
    input  wire                 w_we,
    input  wire                 w_bank,
    input  wire [5:0]           w_addr,     // filter*9 + tap
    input  wire [7:0]           w_data,
    // feature maps out
    output wire                 out_valid,
    output wire                 out_bank,   // bank used for this result (Stage 3c)
    output wire [N_F*SUM_W-1:0] out_f       // filter f = out_f[f*SUM_W +: SUM_W]
);
    // ---------------- row / column counters ----------------
    reg [COL_BITS-1:0] col;
    reg [ROW_BITS-1:0] row;

    always @(posedge clk) begin
        if (rst) begin
            col <= 0;
            row <= 0;
        end else if (in_valid) begin
            if (col == IMG_W-1) begin
                col <= 0;
                row <= row + 1;
            end else
                col <= col + 1;
        end
    end

    // ---------------- line buffer (block RAM) ----------------
    reg [15:0] lb [0:(1<<COL_BITS)-1];     // {pixel 2 rows up, pixel 1 row up}
    reg [15:0] lb_q;

    reg                s1_valid;
    reg [7:0]          s1_pix;
    reg                s1_bank;
    reg [COL_BITS-1:0] s1_col;
    reg [ROW_BITS-1:0] s1_row;

    always @(posedge clk) begin
        if (in_valid)
            lb_q <= lb[col];
        if (s1_valid)
            lb[s1_col] <= {lb_q[7:0], s1_pix};
    end

    always @(posedge clk) begin
        if (rst) s1_valid <= 0;
        else     s1_valid <= in_valid;
        s1_pix  <= in_pix;
        s1_bank <= in_bank;
        s1_col  <= col;
        s1_row  <= row;
    end

    // ---------------- 3x3 window ----------------
    reg [7:0] w0, w1, w2, w3, w4, w5, w6, w7, w8;
    reg       win_valid;
    reg       win_bank;                     // bank of the newest pixel in the window

    always @(posedge clk) begin
        if (s1_valid) begin
            w0 <= w1;  w1 <= w2;  w2 <= lb_q[15:8];   // 2 rows up
            w3 <= w4;  w4 <= w5;  w5 <= lb_q[7:0];    // 1 row up
            w6 <= w7;  w7 <= w8;  w8 <= s1_pix;       // current row
            win_bank <= s1_bank;
        end
        if (rst) win_valid <= 0;
        else     win_valid <= s1_valid && (s1_row >= 2) && (s1_col >= 2);
    end

    wire [71:0] win = {w8, w7, w6, w5, w4, w3, w2, w1, w0};

    // ---------------- the convolution layer ----------------
    conv_layer #(.N_F(N_F), .SUM_W(SUM_W)) layer (
        .clk(clk), .rst(rst),
        .in_valid(win_valid), .win(win), .bank(win_bank),
        .w_we(w_we), .w_bank(w_bank), .w_addr(w_addr), .w_data(w_data),
        .out_valid(out_valid), .sums(out_f));

    // ---------------- bank bit, aligned with the results ----------------
    // conv_layer takes 11 clocks, so delay the window's bank by 11 too.
    localparam CONV_LAT = 11;
    reg [CONV_LAT-1:0] bank_pipe;
    always @(posedge clk)
        bank_pipe <= {bank_pipe[CONV_LAT-2:0], win_bank};
    assign out_bank = bank_pipe[CONV_LAT-1];
endmodule
