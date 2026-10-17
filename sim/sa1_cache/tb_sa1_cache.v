// sa1_rom_cache + bwram_256k testbench.
//
// The cache sits against a behavioral CPU2 responder with the real
// controller's contract (req toggles; after a few mclk the word is in
// cpu2_dout and ack toggles). A consumer modeled on the SA-1 drives it:
// it presents a byte address with rom_req and holds both while rom_wait
// is up, samples the byte, then steps to the next address (mostly
// sequential, occasional jumps, and a second interleaved stream standing
// in for DMA/VBP competing for the same muxed address). Every sampled
// byte is checked; total stall cycles are reported so the effective
// SA-1 fetch rate is visible.
//
// bwram_256k gets port A/B write-read checks across both ports.
`timescale 1ns/1ps

module tb_sa1_cache;

reg mclk = 0;
always #15 mclk = ~mclk;
reg resetn = 0;
integer seed = 7;
integer i;

function [15:0] rom_word(input [21:0] w);
    rom_word = w[15:0] ^ {w[21:16], 10'h2a5} ^ 16'h5a3c;
endfunction
function [7:0] rom_byte(input [22:0] a);
    rom_byte = a[0] ? rom_word(a[22:1]) >> 8 : rom_word(a[22:1]);
endfunction

// ---- cache + CPU2 responder ----------------------------------------------
reg  [22:0] rom_addr = 0;
reg         rom_req = 0;
wire [15:0] rom_q;
wire        rom_wait;
wire [22:1] cpu2_addr;
wire        cpu2_req;
reg         cpu2_req_ack = 0;
reg  [15:0] cpu2_dout = 0;

sa1_rom_cache cache (
    .mclk(mclk), .resetn(resetn), .active(1'b1),
    .rom_addr(rom_addr), .rom_req(rom_req), .rom_q(rom_q), .rom_wait(rom_wait),
    .cpu2_addr(cpu2_addr), .cpu2_req(cpu2_req),
    .cpu2_req_ack(cpu2_req_ack), .cpu2_dout(cpu2_dout)
);

integer svc_delay = 0;
integer fetches = 0;
always @(posedge mclk) begin
    if (cpu2_req != cpu2_req_ack) begin
        if (svc_delay == 0)
            svc_delay <= 2 + ($urandom(seed) % 5);   // 2..6 mclk, like the real lane
        else if (svc_delay == 1) begin
            cpu2_dout <= rom_word(cpu2_addr);
            cpu2_req_ack <= cpu2_req;
            svc_delay <= 0;
            fetches = fetches + 1;
        end else
            svc_delay <= svc_delay - 1;
    end
end

// consumer: one byte every 2 mclk at best (SA-1 CE), held by rom_wait
integer errs = 0, reads = 0, stalls = 0, total = 0;
integer stream = 0;
reg [22:0] pc_a = 23'h00_8000, pc_b = 23'h40_0000;
reg [22:0] cur;
reg seq_only = 0;
reg running = 0;
integer phase = 0;
always @(posedge mclk) if (running) begin
    total = total + 1;
    if (phase == 0) begin
        // pick the next byte address
        if (!seq_only && $urandom(seed) % 11 == 0) begin          // switch streams (DMA/VBP interleave)
            stream = ~stream;
            cur = stream ? pc_a : pc_b;
        end else if (!seq_only && $urandom(seed) % 13 == 0) begin // jump
            cur = {$urandom(seed)} % (1 << 21);
            if (stream) pc_a = cur; else pc_b = cur;
        end else begin
            cur = (stream ? pc_a : pc_b) + 1;
            if (stream) pc_a = cur; else pc_b = cur;
        end
        rom_addr <= cur;
        rom_req <= 1;
        phase <= 1;
    end else begin
        if (rom_wait)
            stalls = stalls + 1;
        phase <= phase + 1;
        if (phase >= 2 && !rom_wait) begin           // CE: sample the byte
            reads = reads + 1;
            if ((cur[0] ? rom_q[15:8] : rom_q[7:0]) !== rom_byte(cur)) begin
                errs = errs + 1;
                if (errs < 10) $display("%0t addr %06x: got %02x want %02x (word %04x)",
                    $time, cur, cur[0] ? rom_q[15:8] : rom_q[7:0], rom_byte(cur), rom_q);
            end
            rom_req <= 0;
            phase <= 0;
        end
        if (phase > 40) begin
            $display("STUCK: rom_wait never dropped for %06x", cur);
            errs = errs + 1;
            phase <= 0;
            rom_req <= 0;
        end
    end
end

// ---- bwram ---------------------------------------------------------------
reg  [17:0] bw_aa = 0, bw_ab = 0;
reg   [7:0] bw_da = 0, bw_db = 0;
reg         bw_wea = 0, bw_web = 0;
wire  [7:0] bw_qa, bw_qb;
bwram_256k bwram (
    .clk(mclk),
    .addr_a(bw_aa), .din_a(bw_da), .q_a(bw_qa), .we_a(bw_wea),
    .addr_b(bw_ab), .din_b(bw_db), .q_b(bw_qb), .we_b(bw_web)
);
integer bw_errs = 0;
task bw_write_a(input [17:0] a, input [7:0] d);
    begin
        @(negedge mclk) begin bw_aa = a; bw_da = d; bw_wea = 1; end
        @(negedge mclk) bw_wea = 0;
    end
endtask
task bw_check_b(input [17:0] a, input [7:0] want);
    begin
        @(negedge mclk) bw_ab = a;
        @(posedge mclk) #1;
        if (bw_qb !== want) begin
            bw_errs = bw_errs + 1;
            $display("bwram port B %05x: got %02x want %02x", a, bw_qb, want);
        end
    end
endtask
task bw_check_a(input [17:0] a, input [7:0] want);
    begin
        @(negedge mclk) bw_aa = a;
        @(posedge mclk) #1;
        if (bw_qa !== want) begin
            bw_errs = bw_errs + 1;
            $display("bwram port A %05x: got %02x want %02x", a, bw_qa, want);
        end
    end
endtask

initial begin
    if ($test$plusargs("SEQ")) seq_only = 1;
    repeat (4) @(posedge mclk);
    resetn = 1;
    // bwram checks first (cache traffic is independent)
    for (i = 0; i < 64; i = i + 1) bw_write_a(18'h2_0000 + i, i[7:0] ^ 8'hc3);
    for (i = 0; i < 64; i = i + 1) bw_check_b(18'h2_0000 + i, i[7:0] ^ 8'hc3);
    @(negedge mclk) begin bw_ab = 18'h3_FFFF; bw_db = 8'h5a; bw_web = 1; end
    @(negedge mclk) bw_web = 0;
    bw_check_a(18'h3_FFFF, 8'h5a);
    bw_check_a(18'h2_0000, 8'hc3);

    running <= 1;
    wait (reads >= 30000);
    running <= 0;
    $display("cache: %0d byte reads, %0d errors, %0d fetches, %0d stall mclk of %0d total",
             reads, errs, fetches, stalls, total);
    $display("bwram: %0d errors", bw_errs);
    if (errs == 0 && bw_errs == 0) $display("tb_sa1_cache: PASS");
    else $display("tb_sa1_cache: FAIL");
    $finish;
end

endmodule
