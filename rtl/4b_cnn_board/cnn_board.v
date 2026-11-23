// Stage 4b: the Stage 3c CNN layer (cnn_stream) on the board, behind the UART.
//
// The PC loads the weights, the requant parameters and an image into the FPGA.
// On 'R' the board pushes the whole image through cnn_stream at full clock
// speed, one pixel per clock with no gaps, from an input block RAM into an
// output block RAM, and counts the clocks. Then the PC reads back the 4
// feature maps and the cycle count. The UART is slow (about 11.5 KB/s), but it
// is only used for loading and reading back: the run itself happens entirely
// on chip, so the cycle count measures the compute.
//
// Protocol (115200 8N1). Each command is one ASCII byte plus its data, and the
// board always answers:
//   'P'                        -> "4B", IMG_W (2 bytes), IMG_H (2 bytes)      ping / info
//   'W' + 72 bytes             -> 'w'   weights: bank A filters 0-3 (9 taps each), then bank B
//   'Q' + 8 x 6 bytes          -> 'q'   requant: bank A filters 0-3, then bank B;
//                                       each = bias (3 bytes, 20-bit signed), mult (2), shift (1)
//   'I' + IMG_W*IMG_H bytes    -> 'i'   image, row by row
//   'R' + bank (1 byte)        -> 'r', cycles (4 bytes), outputs (2 bytes)    run the frame
//   'O'                        -> N_OUT x 4 bytes (f0 f1 f2 f3 per pixel), then 'o'
//   'C' + bank (1 byte)        -> 'c'   continuous mode: run the frame back to back,
//                                       non-stop, until the next byte arrives (send 'S');
//                                       then -> 's', frames (4 bytes), clocks (5 bytes)
//   anything else              -> '?'
// Continuous mode exists for power measurement: a single 'R' computes for only
// 30.8 us, far too short for a power meter to see. Each continuous frame is a
// normal run (results go to the result memory as usual, so 'O' afterwards still
// reads back a correct frame).
// Multi-byte numbers are little-endian. If a command's data stops coming for
// 2^TIMEOUT_BITS clocks (0.67 s at 200 MHz), the board drops it and waits for
// a new command, so a PC script that was interrupted can't leave it stuck.
//
// LEDs: 7 heartbeat, 6 busy (inside a command), 5 continuous mode running,
// 3 last run produced every output, 2 image loaded, 1 requant loaded,
// 0 weights loaded.
module cnn_board #(
    parameter CLK_HZ       = 200_000_000,
    parameter BAUD         = 115_200,
    parameter IMG_W        = 96,
    parameter IMG_H        = 64,
    parameter COL_BITS     = 7,         // enough for IMG_W - 1
    parameter ROW_BITS     = 7,         // enough for IMG_H
    parameter ADDR_BITS    = 13,        // enough for IMG_W * IMG_H
    parameter TIMEOUT_BITS = 27,
    parameter POR_BITS     = 16
)(
    input  wire       clk,
    input  wire       uart_rx,
    output wire       uart_tx,
    output wire [7:0] led
);
    localparam N_IN  = IMG_W * IMG_H;
    localparam N_OUT = (IMG_W - 2) * (IMG_H - 2);
    localparam N_F = 4, SUM_W = 20;
    localparam DRAIN = 63;              // clocks to wait for outputs after the last pixel
    localparam [15:0] W16 = IMG_W, H16 = IMG_H;

    // ---------------- power-on reset, heartbeat ----------------
    reg [POR_BITS:0] por = 0;
    always @(posedge clk) if (!por[POR_BITS]) por <= por + 1;
    wire rst = !por[POR_BITS];

    reg [26:0] beat = 0;
    always @(posedge clk) beat <= beat + 1;

    // ---------------- UART ----------------
    wire       rx_valid;
    wire [7:0] rx_data;
    uart_rx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) urx (
        .clk(clk), .rst(rst), .rx(uart_rx), .valid(rx_valid), .data(rx_data));

    reg        tx_go = 0;               // one-clock start pulse
    reg  [7:0] tx_byte = 0;
    wire       tx_busy;
    // uart_tx raises busy on the clock after it sees tx_go, so don't start
    // another byte while tx_go is still high.
    wire       tx_ready = !tx_busy && !tx_go;
    uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) utx (
        .clk(clk), .rst(rst), .start(tx_go), .data(tx_byte), .tx(uart_tx), .busy(tx_busy));

    // ---------------- the CNN layer ----------------
    reg                 cnn_rst = 1;
    reg                 c_valid = 0;
    reg                 c_bank  = 0;
    wire [7:0]          c_pix;
    reg                 w_we = 0, w_bank = 0;
    reg  [5:0]          w_addr = 0;
    reg  [7:0]          w_data = 0;
    reg                 q_we = 0, q_bank = 0;
    reg  [1:0]          q_filt = 0;
    reg  [SUM_W-1:0]    q_bias = 0;
    reg  [15:0]         q_mult = 0;
    reg  [4:0]          q_shift = 0;
    wire                o_valid;
    wire [N_F*8-1:0]    o_q;

    cnn_stream #(.IMG_W(IMG_W), .COL_BITS(COL_BITS), .ROW_BITS(ROW_BITS),
                 .N_F(N_F), .SUM_W(SUM_W)) cnn (
        .clk(clk), .rst(cnn_rst || rst),
        .in_valid(c_valid), .in_pix(c_pix), .in_bank(c_bank),
        .w_we(w_we), .w_bank(w_bank), .w_addr(w_addr), .w_data(w_data),
        .q_we(q_we), .q_bank(q_bank), .q_filt(q_filt),
        .q_bias(q_bias), .q_mult(q_mult), .q_shift(q_shift),
        .out_valid(o_valid), .out_q(o_q));

    // ---------------- image memory (block RAM) ----------------
    // Written by the UART ('I'), read by the run, one pixel per clock.
    reg [7:0]           img_mem [0:(1<<ADDR_BITS)-1];
    reg                 img_we = 0;
    reg [ADDR_BITS-1:0] img_waddr = 0;
    reg [7:0]           img_wdata = 0;
    reg [ADDR_BITS-1:0] img_raddr = 0;
    reg [7:0]           img_q = 0;

    always @(posedge clk) begin
        if (img_we) img_mem[img_waddr] <= img_wdata;
        img_q <= img_mem[img_raddr];
    end
    assign c_pix = img_q;

    // ---------------- result memory (block RAM) ----------------
    // One 32-bit word per output pixel: {f3, f2, f1, f0}.
    reg [31:0]          res_mem [0:(1<<ADDR_BITS)-1];
    reg                 res_we = 0;
    reg [ADDR_BITS-1:0] res_waddr = 0;
    reg [31:0]          res_wdata = 0;
    reg [ADDR_BITS-1:0] res_raddr = 0;
    reg [31:0]          res_q = 0;

    always @(posedge clk) begin
        if (res_we) res_mem[res_waddr] <= res_wdata;
        res_q <= res_mem[res_raddr];
    end

    // ---------------- run engine ----------------
    // feeding: issue one image read per clock. The pixel comes out of the
    // block RAM one clock later, so c_valid is 'feeding' delayed by one.
    // Outputs are registered once (o_valid/o_q -> res_we/res_wdata) and
    // written to res_mem in order. 'cycles' counts every clock from the first
    // image read to the clock the last result is written.
    reg                 run_go = 0;     // pulse from the command FSM
    reg                 running = 0, feeding = 0, run_done = 0;
    reg [ADDR_BITS-1:0] n_out = 0;      // results written so far
    reg [31:0]          cycles = 0;
    reg [5:0]           drain = 0;
    reg [1:0]           rst_cnt = 0;

    always @(posedge clk) begin
        run_done <= 1'b0;
        res_we   <= o_valid && running;
        res_wdata <= o_q;
        c_valid  <= feeding;

        if (rst) begin
            running <= 0;
            feeding <= 0;
            cnn_rst <= 1;
        end else if (run_go) begin
            // reset cnn_stream's row/column counters and valid pipelines (not
            // the weights) for 2 clocks, so every frame starts at row 0, col 0
            cnn_rst   <= 1;
            rst_cnt   <= 2'd2;
            running   <= 1;
            feeding   <= 0;
            img_raddr <= 0;
            n_out     <= 0;
            res_waddr <= 0;
            cycles    <= 0;
            drain     <= 0;
        end else if (running) begin
            if (rst_cnt != 0) begin
                rst_cnt <= rst_cnt - 1;
                if (rst_cnt == 2'd1) begin
                    cnn_rst <= 0;
                    feeding <= 1;       // first read is issued on the next clock
                end
            end else begin
                cycles <= cycles + 1;
                if (feeding) begin
                    if (img_raddr == N_IN - 1) feeding <= 0;
                    else                       img_raddr <= img_raddr + 1;
                end else
                    drain <= drain + 1;

                if (res_we) begin
                    res_waddr <= res_waddr + 1;
                    n_out     <= n_out + 1;
                end
                // done when the last result is written, or (if outputs went
                // missing) DRAIN clocks after the last pixel
                if ((res_we && n_out == N_OUT - 1) || drain == DRAIN) begin
                    running  <= 0;
                    run_done <= 1;
                end
            end
        end
    end

    // ---------------- command FSM ----------------
    localparam S_CMD = 4'd0, S_W = 4'd1, S_Q = 4'd2, S_I = 4'd3, S_RB = 4'd4,
               S_RUN = 4'd5, S_REPLY = 4'd6, S_O_RD = 4'd7, S_O_SEND = 4'd8,
               S_CB = 4'd9, S_CONT = 4'd10;

    reg [3:0]              state = S_CMD;
    reg [ADDR_BITS-1:0]    cnt = 0;             // bytes received in this command
    reg [2:0]              qb = 0;              // byte within a requant record
    reg [2:0]              qrec = 0;            // requant record (bank*4 + filter)
    reg [7:0]              qbuf0 = 0, qbuf1 = 0, qbuf2 = 0, qbuf3 = 0, qbuf4 = 0;
    reg [79:0]             rbuf = 0;            // reply bytes, sent low byte first
    reg [3:0]              rlen = 0;
    reg [1:0]              ob = 0;              // byte within a result word
    reg [TIMEOUT_BITS-1:0] idle = 0;
    reg                    w_ok = 0, q_ok = 0, i_ok = 0, run_ok = 0;
    reg [31:0]             cont_frames = 0;     // continuous mode: frames finished
    reg [39:0]             cont_clocks = 0;     // continuous mode: clocks since 'C' (40 bits: 1.5 h at 200 MHz)
    reg                    cont_stop = 0;       // 'S' (any byte) arrived: stop after this frame

    // reply helper: load up to 10 bytes and go to S_REPLY
    task reply;
        input [79:0] bytes;
        input [3:0]  n;
        begin
            rbuf  <= bytes;
            rlen  <= n;
            state <= S_REPLY;
        end
    endtask

    always @(posedge clk) begin
        tx_go  <= 1'b0;
        w_we   <= 1'b0;
        q_we   <= 1'b0;
        img_we <= 1'b0;
        run_go <= 1'b0;

        // data timeout for the commands that receive bytes
        if (rx_valid || state == S_CMD || state == S_RUN || state == S_REPLY ||
            state == S_O_RD || state == S_O_SEND || state == S_CONT)
            idle <= 0;
        else
            idle <= idle + 1;

        if (rst) begin
            state <= S_CMD;
        end else if (&idle) begin
            state <= S_CMD;                     // the PC stopped mid-command
        end else case (state)
            S_CMD:
                if (rx_valid) begin
                    cnt  <= 0;
                    qb   <= 0;
                    qrec <= 0;
                    case (rx_data)
                        "P": reply({16'd0, H16, W16, "B", "4"}, 4'd6);
                        "W": state <= S_W;
                        "Q": state <= S_Q;
                        "I": state <= S_I;
                        "R": state <= S_RB;
                        "C": state <= S_CB;
                        "O": begin res_raddr <= 0; ob <= 0; state <= S_O_RD; end
                        default: reply("?", 4'd1);
                    endcase
                end

            S_W:                                // 72 weights: bank A (0..35), bank B (36..71)
                if (rx_valid) begin
                    w_we   <= 1'b1;
                    w_bank <= (cnt >= 36);
                    w_addr <= (cnt >= 36) ? cnt - 36 : cnt;
                    w_data <= rx_data;
                    cnt    <= cnt + 1;
                    if (cnt == 71) begin w_ok <= 1; reply("w", 4'd1); end
                end

            S_Q:                                // 8 records of 6 bytes
                if (rx_valid) begin
                    case (qb)
                        3'd0: qbuf0 <= rx_data;
                        3'd1: qbuf1 <= rx_data;
                        3'd2: qbuf2 <= rx_data;
                        3'd3: qbuf3 <= rx_data;
                        3'd4: qbuf4 <= rx_data;
                        default: ;
                    endcase
                    if (qb == 3'd5) begin
                        q_we    <= 1'b1;
                        q_bank  <= qrec[2];
                        q_filt  <= qrec[1:0];
                        q_bias  <= {qbuf2[3:0], qbuf1, qbuf0};
                        q_mult  <= {qbuf4, qbuf3};
                        q_shift <= rx_data[4:0];
                        qb      <= 0;
                        qrec    <= qrec + 1;
                        if (qrec == 3'd7) begin q_ok <= 1; reply("q", 4'd1); end
                    end else
                        qb <= qb + 1;
                end

            S_I:                                // the image, one byte per pixel
                if (rx_valid) begin
                    img_we    <= 1'b1;
                    img_waddr <= cnt;
                    img_wdata <= rx_data;
                    cnt       <= cnt + 1;
                    if (cnt == N_IN - 1) begin i_ok <= 1; reply("i", 4'd1); end
                end

            S_RB:                               // bank byte, then run
                if (rx_valid) begin
                    c_bank <= rx_data[0];
                    run_go <= 1'b1;
                    state  <= S_RUN;
                end

            S_CB:                               // bank byte, then run continuously
                if (rx_valid) begin
                    c_bank      <= rx_data[0];
                    run_go      <= 1'b1;
                    tx_go       <= 1'b1;        // ack now; the UART is idle here
                    tx_byte     <= "c";
                    cont_frames <= 0;
                    cont_clocks <= 0;
                    cont_stop   <= 0;
                    state       <= S_CONT;
                end

            S_CONT: begin                       // frames back to back until a byte arrives
                cont_clocks <= cont_clocks + 1;
                if (run_done) begin
                    cont_frames <= cont_frames + 1;
                    run_ok      <= (n_out == N_OUT);
                    if (cont_stop || rx_valid)
                        reply({cont_clocks + 40'd1, cont_frames + 32'd1, "s"}, 4'd10);
                    else
                        run_go <= 1'b1;         // next frame starts right away
                end else if (rx_valid)
                    cont_stop <= 1'b1;
            end

            S_RUN:
                if (run_done) begin
                    run_ok <= (n_out == N_OUT);
                    reply({8'd0, {{(16-ADDR_BITS){1'b0}}, n_out}, cycles, "r"}, 4'd7);
                end

            S_REPLY:
                if (tx_ready) begin
                    if (rlen == 0)
                        state <= S_CMD;
                    else begin
                        tx_go   <= 1'b1;
                        tx_byte <= rbuf[7:0];
                        rbuf    <= rbuf >> 8;
                        rlen    <= rlen - 1;
                    end
                end

            S_O_RD:                             // res_q is valid one clock after res_raddr
                state <= S_O_SEND;

            S_O_SEND:
                if (tx_ready) begin
                    tx_go   <= 1'b1;
                    tx_byte <= res_q[8*ob +: 8];
                    ob      <= ob + 1;
                    if (ob == 2'd3) begin
                        if (res_raddr == N_OUT - 1)
                            reply("o", 4'd1);
                        else begin
                            res_raddr <= res_raddr + 1;
                            state     <= S_O_RD;
                        end
                    end
                end

            default: state <= S_CMD;
        endcase
    end

    assign led = {beat[26], (state != S_CMD), (state == S_CONT), 1'b0, run_ok, i_ok, q_ok, w_ok};
endmodule
