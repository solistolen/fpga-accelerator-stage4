// Stage 3c: CNN output stage. Turns each filter's 20-bit convolution sum back
// into an 8-bit value, the way an int8 CNN layer does after its convolution:
//
//     s   = sum + bias                       (bias: signed, per filter)
//     r   = max(s, 0)                        (ReLU)
//     q   = round(r * mult / 2^shift)        (mult: 16-bit unsigned, shift: 0..31)
//     out = min(q, 255)                      (saturate to an unsigned 8-bit pixel)
//
// mult / 2^shift is the layer's scale factor: e.g. mult = 24576, shift = 16 is
// 0.375. Using an integer multiply plus a shift instead of a real division or
// floating point is how integer-only accelerators (and TensorFlow Lite's int8
// kernels) apply scales. Rounding is "round half up": add 2^(shift-1) before
// shifting.
//
// The output is the same format as the input pixels (unsigned 0..255), so a
// second conv_layer could take this layer's output as its input.
//
// Parameters are per filter and double-banked like the weights in conv_layer:
// each sum arrives with the bank bit of its window and uses that bank's bias,
// mult and shift. The parameters are read once, on the clock edge the sum
// enters, so the idle bank can be rewritten from the next clock on.
//
// Pipeline, one result per clock per filter, LATENCY = 6:
//   1: s1 = sum + bias            (select bank)
//   2: r2 = ReLU(s1)
//   3: p3 = r2 * mult             (one DSP48E1 per filter); k3 = 2^(shift-1)
//   4: p4 = p3 + k3               (rounding; done inside the same DSP)
//   5: q5 = p4 >> shift           (barrel shifter)
//   6: out = saturate(q5)
module requant #(
    parameter N_F   = 4,
    parameter SUM_W = 20
)(
    input  wire                 clk, rst,
    input  wire                 in_valid,
    input  wire                 in_bank,        // bank of the window these sums came from
    input  wire [N_F*SUM_W-1:0] sums,           // filter f = sums[f*SUM_W +: SUM_W], signed
    // parameter write port: one filter's bias, mult and shift per write
    input  wire                 q_we,
    input  wire                 q_bank,
    input  wire [1:0]           q_filt,
    input  wire [SUM_W-1:0]     q_bias,         // signed
    input  wire [15:0]          q_mult,         // unsigned
    input  wire [4:0]           q_shift,        // 0..31
    output wire                 out_valid,
    output wire [N_F*8-1:0]     out_q           // filter f = out_q[8*f +: 8], unsigned
);
    localparam LAT = 6;

    genvar f;
    generate
        for (f = 0; f < N_F; f = f + 1) begin : filt
            // ---- parameters, two banks ----
            reg signed [SUM_W-1:0] biasA, biasB;
            reg        [15:0]      multA, multB;
            reg        [4:0]       shA,   shB;

            always @(posedge clk)
                if (q_we && q_filt == f) begin
                    if (q_bank) begin biasB <= q_bias; multB <= q_mult; shB <= q_shift; end
                    else        begin biasA <= q_bias; multA <= q_mult; shA <= q_shift; end
                end

            wire signed [SUM_W-1:0] sum = sums[f*SUM_W +: SUM_W];

            // ---- pipeline ----
            reg signed [SUM_W:0]  s1;       // one bit wider: sum + bias can't overflow
            reg        [15:0]     m1, m2;
            reg        [4:0]      h1, h2, h3, h4;
            reg        [SUM_W-1:0] r2;      // after ReLU: 0 .. 2^SUM_W - 1
            reg        [SUM_W+15:0] p3;     // 20 x 16 bits = 36 bits
            reg        [SUM_W+16:0] p4, q5; // + rounding constant: 37 bits
            reg        [SUM_W+16:0] k3;     // rounding constant, registered (see stage 3)
            reg        [7:0]      o6;

            always @(posedge clk) begin
                // 1: add the bias of this window's bank
                s1 <= sum + (in_bank ? biasB : biasA);
                m1 <= in_bank ? multB : multA;
                h1 <= in_bank ? shB   : shA;
                // 2: ReLU
                r2 <= s1[SUM_W] ? {SUM_W{1'b0}} : s1[SUM_W-1:0];
                m2 <= m1;  h2 <= h1;
                // 3: scale (multiply), and work out the rounding constant
                //    2^(shift-1) (0 for shift = 0) a stage early, into a register.
                //    The first version computed it on the way into stage 4. XST
                //    folded that add into the DSP and steered the "shift = 0"
                //    case through the DSP's OPMODE pins, which need ~1.9 ns of
                //    setup: 3.55 ns, 282 MHz. With k3 registered, the DSP always
                //    adds a register value and its mode never changes.
                p3 <= r2 * m2;
                h3 <= h2;
                k3 <= (h2 == 0) ? {(SUM_W+17){1'b0}} : ({{(SUM_W+16){1'b0}}, 1'b1} << (h2 - 1));
                // 4: add the rounding constant
                p4 <= p3 + k3;
                h4 <= h3;
                // 5: divide by 2^shift
                q5 <= p4 >> h4;
                // 6: saturate to 0..255
                o6 <= (|q5[SUM_W+16:8]) ? 8'd255 : q5[7:0];
            end

            assign out_q[8*f +: 8] = o6;
        end
    endgenerate

    reg [LAT-1:0] v_pipe;
    always @(posedge clk) begin
        if (rst) v_pipe <= 0;
        else     v_pipe <= {v_pipe[LAT-2:0], in_valid};
    end
    assign out_valid = v_pipe[LAT-1];
endmodule
