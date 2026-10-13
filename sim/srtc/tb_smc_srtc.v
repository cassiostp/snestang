// smc_parser S-RTC decode: a 0x35/0x55 header becomes rom_type 0x09
// (HiROM + S-RTC bit), with regressions for the neighbouring cases.
`timescale 1ns/1ps

module tb_smc_srtc;

reg clk = 0;
always #5 clk = ~clk;

reg resetn = 0;
reg [7:0] rom_d = 0;
reg rom_strb = 0;
wire [7:0] rom_type;
wire [23:0] rom_mask, ram_mask;
wire [3:0] rom_size, ram_size;
wire header_finished;

integer errs = 0;

smc_parser dut (
    .clk(clk), .resetn(resetn),
    .rom_d(rom_d), .rom_strb(rom_strb),
    .rom_type(rom_type), .rom_mask(rom_mask), .ram_mask(ram_mask),
    .rom_size(rom_size), .ram_size(ram_size),
    .header_finished(header_finished)
);

task check(input cond, input [8*64-1:0] what);
    if (!cond) begin
        errs = errs + 1;
        $display("FAIL: %0s (t=%0t)", what, $time);
    end
endtask

// Feed one 64-byte header ($15 map, $16 chipset, $17/$18 sizes, $1A company).
task feed(input [7:0] mapper, input [7:0] chipset);
    integer k;
    begin
        resetn = 0;
        repeat (4) @(negedge clk);
        resetn = 1;
        for (k = 0; k < 64; k = k + 1) begin
            @(negedge clk);
            case (k)
            6'h15: rom_d = mapper;
            6'h16: rom_d = chipset;
            6'h17: rom_d = 8'h0b;
            6'h18: rom_d = 8'h02;
            6'h1A: rom_d = 8'h01;
            default: rom_d = 8'h00;
            endcase
            rom_strb = 1;
            @(negedge clk);
            rom_strb = 0;
        end
        repeat (4) @(negedge clk);
    end
endtask

initial begin
    feed(8'h35, 8'h55);                 // Daikaijuu Monogatari II
    check(header_finished, "header finishes");
    check(rom_type == 8'h09, "S-RTC rom_type is HiROM + bit3");

    feed(8'h20, 8'h03);                 // DSP-1 LoROM
    check(rom_type == 8'h80, "DSP-1 decode unchanged");

    feed(8'h21, 8'h00);                 // plain HiROM
    check(rom_type == 8'h01, "plain HiROM unchanged");

    feed(8'h20, 8'h13);                 // Super FX
    check(rom_type == 8'h70, "GSU decode unchanged");

    feed(8'h23, 8'h32);                 // SA-1
    check(rom_type == 8'h63, "SA-1 decode unchanged");

    feed(8'h35, 8'h00);                 // 0x35 map, other chipset: no S-RTC bit
    check(rom_type == 8'h01, "map 0x35 alone stays plain HiROM");

    if (errs == 0) $display("tb_smc_srtc: PASS");
    else $fatal(1, "tb_smc_srtc: FAIL, %0d errors", errs);
    $finish;
end

initial begin #(1_000_000); $fatal(1, "TIMEOUT: sim hang"); end

endmodule
