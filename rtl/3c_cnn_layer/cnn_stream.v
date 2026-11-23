// Stage 3c: one complete int8 CNN layer on a pixel stream.
//
//   pixels (8-bit) -> feature_stream (line buffer, 3x3 window, conv_layer:
//   4 filters, runtime weights) -> requant (bias, ReLU, scale, round,
//   saturate) -> 4 feature maps of 8-bit pixels
//
// Everything is double-banked: each input pixel carries a bank bit, and the
// window that ends on that pixel uses that bank's weights in conv_layer AND
// that bank's bias/scale in requant. Banks can switch between any two pixels
// with no pause.
//
// Ports: a weight write port (as in Stage 3b) and a requant parameter port.
// Rules for both: only write the bank the incoming pixels are not using.
//   - weights:          from 8 clocks after the last window that used the bank
//                       entered conv_layer (see conv_layer.v)
//   - requant params:   read when a window's sums reach requant, 11 clocks after
//                       the window entered conv_layer, so wait 12 clocks
//
// Latency: 13 (feature_stream) + 6 (requant) = 19 clocks.
module cnn_stream #(
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
    input  wire                 in_bank,
    // weight write port
    input  wire                 w_we,
    input  wire                 w_bank,
    input  wire [5:0]           w_addr,
    input  wire [7:0]           w_data,
    // requant parameter write port
    input  wire                 q_we,
    input  wire                 q_bank,
    input  wire [1:0]           q_filt,
    input  wire [SUM_W-1:0]     q_bias,
    input  wire [15:0]          q_mult,
    input  wire [4:0]           q_shift,
    // 8-bit feature maps out
    output wire                 out_valid,
    output wire [N_F*8-1:0]     out_q       // filter f = out_q[8*f +: 8]
);
    wire                 f_valid, f_bank;
    wire [N_F*SUM_W-1:0] f_sums;

    feature_stream #(.IMG_W(IMG_W), .COL_BITS(COL_BITS), .ROW_BITS(ROW_BITS),
                     .N_F(N_F), .SUM_W(SUM_W)) conv (
        .clk(clk), .rst(rst),
        .in_valid(in_valid), .in_pix(in_pix), .in_bank(in_bank),
        .w_we(w_we), .w_bank(w_bank), .w_addr(w_addr), .w_data(w_data),
        .out_valid(f_valid), .out_bank(f_bank), .out_f(f_sums));

    requant #(.N_F(N_F), .SUM_W(SUM_W)) rq (
        .clk(clk), .rst(rst),
        .in_valid(f_valid), .in_bank(f_bank), .sums(f_sums),
        .q_we(q_we), .q_bank(q_bank), .q_filt(q_filt),
        .q_bias(q_bias), .q_mult(q_mult), .q_shift(q_shift),
        .out_valid(out_valid), .out_q(out_q));
endmodule
