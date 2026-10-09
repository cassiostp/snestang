// Battery-save channel testbench for iosys_bl616 (SAVE_IF=1, SAVE_RDY=1).
//
// Drives real 2 Mbaud UART bit timing into the iosys save channel and decodes
// the UART TX. snestang's save RAM is not on-chip: it lives in the SDRAM's
// BSRAM region behind a bridge, so this models the bridge side of the channel
// -- byte accesses answer through the sv_req/sv_ack and sv_rreq/sv_rack
// toggles, a few clocks after they start, like sdram_cl2_*.v does. Run with
// run.sh (iverilog, `define SIM to skip textdisp):
//   restore/dump a 512-byte block, the 0x0B dirty notice, the block-0 dump
//   clearing dirty, joypad/core-ID interleaving with a block reply, and that
//   slow bridge acks never lose or duplicate a byte.

`timescale 1ns/1ps

module tb_saveram;

parameter FREQ = 21_484_000;          // snestang mclk
parameter BIT = 500.0;                // 2 Mbaud, ns
parameter LATE = 8;                   // clocks the "sdram" takes per byte access

reg clk = 0;
always #23.273 clk = ~clk;            // 1/(2*FREQ)
reg resetn = 0;
reg uart_rx = 1;
wire uart_tx;

// ---- dut: iosys with the save channel, SAVE_AW=17 (128 KB, 256 blocks) ----
wire [16:0] sv_addr;
wire [7:0]  sv_din;
reg  [7:0]  sv_q;
wire        sv_we, sv_req, sv_rreq;
wire [7:0]  tb_kbd;                   // PS/2 path unused; iosys registers this port itself
reg         sv_ack = 0, sv_rack = 0;
wire        sv_core_we;               // the "SNES" wrote save RAM
reg         core_we = 0;
reg  [16:0] core_a = 0;
reg  [7:0]  core_d = 0;
reg  [11:0] joy1 = 0, joy2 = 0;

iosys_bl616 #(.FREQ(FREQ), .CORE_ID(2), .SAVE_IF(1), .SAVE_AW(17), .SAVE_RDY(1)) dut (
    .clk(clk), .hclk(clk), .resetn(resetn),
    .overlay(), .overlay_x(8'h00), .overlay_y(8'h00), .overlay_color(),
    .joy1(joy1), .joy2(joy2), .hid1(), .hid2(),
    .rom_loading(), .rom_do(), .rom_do_valid(), .core_config(),
    .mgmt_address(), .mgmt_read(), .mgmt_readdata(16'h0), .mgmt_write(), .mgmt_writedata(),
    .fdd_request(2'b0), .kbd_data(tb_kbd), .kbd_data_valid(),
    .sv_addr(sv_addr), .sv_din(sv_din), .sv_we(sv_we),
    .sv_req(sv_req), .sv_ack(sv_ack), .sv_rreq(sv_rreq), .sv_rack(sv_rack),
    .sv_q(sv_q), .sv_core_we(sv_core_we),
    .uart_rx(uart_rx), .uart_tx(uart_tx)
);

// ---- the bridge + "sdram" model ----
// One RAM: the SNES side is port A (core_a/core_we), the save channel is port B
// through the handshake. An access starts at the req toggle and answers LATE
// clocks later, holding nothing until then; addr/din must be held that long.
reg [7:0] ram [0:131071];
reg         req_seen = 0, rreq_seen = 0;
reg         pend_w = 0, pend_r = 0;
reg [3:0]   cnt = 0;
reg [16:0]  addr_w = 0;
reg [7:0]   din_w = 0;
reg [16:0]  addr_r = 0;

always @(posedge clk) begin
    req_seen  <= sv_req;
    rreq_seen <= sv_rreq;
    if (~pend_w && (sv_req ^ req_seen)) begin     // a write access starts
        pend_w <= 1; cnt <= 0; addr_w <= sv_addr; din_w <= sv_din;
    end else if (pend_w) begin
        if (cnt == LATE-1) begin
            ram[addr_w] = din_w;
            sv_ack <= ~sv_ack;
            pend_w <= 0;
        end else cnt <= cnt + 1;
    end
    if (~pend_r && (sv_rreq ^ rreq_seen)) begin   // a read access starts
        pend_r <= 1; cnt <= 0; addr_r <= sv_addr;
    end else if (pend_r) begin
        if (cnt == LATE-1) begin
            sv_q <= ram[addr_r];
            sv_rack <= ~sv_rack;
            pend_r <= 0;
        end else cnt <= cnt + 1;
    end
end

// ---- capture dut's uart_tx ----
wire [7:0] cap_data;
wire cap_valid;
async_receiver #(.ClkFrequency(FREQ), .Baud(2_000_000)) cap (
    .clk(clk), .RxD(uart_tx), .RxD_data(cap_data), .RxD_data_ready(cap_valid)
);
reg [7:0] cap_mem [0:65535];
integer ncap = 0, rcnt = 0, errs = 0;
always @(posedge clk)
    if (cap_valid && ncap < 65536) begin
        cap_mem[ncap] = cap_data;
        ncap = ncap + 1;
    end

// block byte pattern
function [7:0] pat(input [7:0] seed, input integer i);
    pat = seed + i[7:0];
endfunction

// ---- stimulus ----
task tx_byte(input [7:0] b);
    integer k;
begin
    uart_rx = 1'b0; #BIT;
    for (k = 0; k < 8; k = k + 1) begin uart_rx = b[k]; #BIT; end
    uart_rx = 1'b1; #BIT;
end
endtask

task send_hdr(input [15:0] len, input [7:0] cmd);
begin
    tx_byte(8'hAA); tx_byte(len[15:8]); tx_byte(len[7:0]); tx_byte(cmd);
end
endtask

task restore(input [15:0] blk, input [7:0] seed);
    integer k;
begin
    send_hdr(16'd515, 8'h11); tx_byte(blk[15:8]); tx_byte(blk[7:0]);
    for (k = 0; k < 512; k = k + 1) tx_byte(pat(seed, k));
end
endtask

// a SNES bus write: one clock of sv_core_we plus the RAM write
task core_write(input [16:0] a, input [7:0] d);
begin
    @(posedge clk); core_a <= a; core_d <= d; core_we <= 1;
    @(posedge clk); core_we <= 0;
end
endtask

task core_read_check(input [16:0] a, input [7:0] e);
begin
    @(posedge clk);
    if (ram[a] !== e) begin
        errs = errs + 1;
        $display("FAIL: ram[%0h] = %02x, expected %02x", a, ram[a], e);
    end
end
endtask

task wait_for(input integer want);
    integer t;
begin
    t = 0;
    while (ncap < want && t < 4_000_000) begin @(posedge clk); t = t + 1; end
    if (ncap < want) begin
        errs = errs + 1;
        $fatal(1, "FAIL: timeout waiting for byte %0d (have %0d)", want, ncap);
    end
end
endtask

task expect_byte(input [7:0] e);
    reg [7:0] b;
begin
    wait_for(rcnt + 1);
    b = cap_mem[rcnt]; rcnt = rcnt + 1;
    if (b !== e) begin
        errs = errs + 1;
        $display("FAIL: byte %0d = %02x, expected %02x", rcnt - 1, b, e);
    end
end
endtask

task expect_dirty;
begin
    expect_byte(8'hAA); expect_byte(8'h00); expect_byte(8'h02);
    expect_byte(8'h0B); expect_byte(8'h00);
end
endtask

task expect_core_id;
begin
    expect_byte(8'hAA); expect_byte(8'h00); expect_byte(8'h02);
    expect_byte(8'h01); expect_byte(8'h02);   // CORE_ID = 2 (snestang)
end
endtask

task dump_header(input [15:0] blk);
begin
    expect_byte(8'hAA); expect_byte(8'h02); expect_byte(8'h03);
    expect_byte(8'h0A); expect_byte(blk[15:8]); expect_byte(blk[7:0]);
end
endtask

task request_dump(input [15:0] blk);
begin
    send_hdr(16'd3, 8'h12); tx_byte(blk[15:8]); tx_byte(blk[7:0]);
end
endtask

task expect_dump(input [15:0] blk, input [7:0] seed);
    integer k;
begin
    request_dump(blk);
    dump_header(blk);
    for (k = 0; k < 512; k = k + 1) expect_byte(pat(seed, k));
end
endtask

integer k;

initial begin
    // model FF power-on state (Gowin FFs come up 0; these regs have no reset)
    dut.send_idx = 0; dut.response_req = 0; dut.response_ack = 0;
    dut.joy1_reg = 0; dut.joy2_reg = 0; dut.send_state_next = 0;
    dut.fdd_state = 0; dut.kbd_len = 0;

    repeat (10) @(posedge clk);
    resetn = 1;
    repeat (50) @(posedge clk);

    // 1. a core write earns exactly one dirty notice
    core_write(17'h0100, 8'hAB);
    expect_dirty;
    expect_no_traffic(20_000);

    // 2. restore blocks, read back through the SNES's port; the last byte of
    //    each block must survive the next frame's block-number byte
    restore(16'd0,  8'h11);
    restore(16'd5,  8'hA5);
    restore(16'd6,  8'h3C);
    for (k = 0; k < 512; k = k + 64) begin
        core_read_check({7'd0, 6'd0, k[8:0]}, pat(8'h11, k));
        core_read_check({7'd0, 6'd5, k[8:0]}, pat(8'hA5, k));
        core_read_check({7'd0, 6'd6, k[8:0]}, pat(8'h3C, k));
    end
    core_read_check(17'h001FF, pat(8'h11, 511));
    core_read_check(17'h00BFF, pat(8'hA5, 511));
    core_read_check(17'h00DFF, pat(8'h3C, 511));

    // 3. dump them back, byte exact (each byte via the multi-clock handshake)
    expect_dump(16'd5, 8'hA5);
    expect_dump(16'd6, 8'h3C);

    // 4. a write landing mid-dump dirties again and re-notifies: dump block 0
    //    (clears dirty), game-write during it, 0x0B follows the block
    request_dump(16'd0);
    dump_header(16'd0);
    for (k = 0; k < 100; k = k + 1) expect_byte(pat(8'h11, k));
    core_write(17'h0300, 8'h77);              // block 3: doesn't disturb dump
    for (k = 100; k < 512; k = k + 1) expect_byte(pat(8'h11, k));
    expect_dirty;

    // 5. dump block 0 again (clean: no core write) while a 0x01 core-ID
    //    request is pending: the block reply must not swallow the core ID
    request_dump(16'd0);
    dump_header(16'd0);
    for (k = 0; k < 200; k = k + 1) expect_byte(pat(8'h11, k));
    send_hdr(16'd1, 8'h01);                   // request during the reply
    for (k = 200; k < 512; k = k + 1) expect_byte(pat(8'h11, k));
    expect_core_id;                           // ... answered, RX not stuck

    // 6. a joypad change and a block reply arbitrate: joypad wins from idle,
    //    and a 0x01 arriving during the reply still comes out after it
    restore(16'd17, 8'h5A);
    joy1 = 12'h008;                           // pad 1 B pressed
    request_dump(16'd17);
    expect_byte(8'hAA); expect_byte(8'h00); expect_byte(8'h05); expect_byte(8'h03);
    expect_byte(8'h00); expect_byte(8'h08); expect_byte(8'h00); expect_byte(8'h00);
    dump_header(16'd17);
    for (k = 0; k < 300; k = k + 1) expect_byte(pat(8'h5A, k));
    send_hdr(16'd1, 8'h01);
    for (k = 300; k < 512; k = k + 1) expect_byte(pat(8'h5A, k));
    expect_core_id;

    // 7. dump the top block: block numbers must reach 255 with SAVE_AW=17
    restore(16'd255, 8'h77);
    expect_dump(16'd255, 8'h77);

    // 8. protocol still healthy: dump block 6 once more
    expect_dump(16'd6, 8'h3C);

    if (errs == 0) $display("tb_saveram: PASS");
    else $fatal(1, "tb_saveram: FAIL, %0d errors", errs);
    $finish;
end

// nothing at all must appear on uart_tx for `cycles` clocks
task expect_no_traffic(input integer cycles);
    integer base, t;
begin
    base = ncap; t = 0;
    while (ncap == base && t < cycles) begin @(posedge clk); t = t + 1; end
    if (ncap != base) begin
        errs = errs + 1;
        $display("FAIL: unexpected byte %02x (byte %0d) on uart_tx", cap_mem[base], base);
    end
end
endtask

// a core-side write also raises sv_core_we
assign sv_core_we = core_we;

endmodule
