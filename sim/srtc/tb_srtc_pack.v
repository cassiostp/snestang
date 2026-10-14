// srtc_time_pack: a firmware-order BCD frame packs into the S-RTC nibble
// map (the MiSTer hps_io RTC format). Byte order must match
// clock_send_to_core: year mon day wday hour min sec; the GBA side once had
// year/sec swapped and only a comment records it now. The reload itself
// lives in the untouched SRTC.v (same indices as MiSTer's SRTC.vhd).
`timescale 1ns/1ps

module tb_srtc_pack;

reg clk = 0;
always #5 clk = ~clk;

reg [55:0] time_bcd = 0;
reg time_strobe = 0;
wire [64:0] ext_rtc;

integer errs = 0;

srtc_time_pack pack(
    .time_bcd(time_bcd), .time_strobe(time_strobe), .ext_rtc(ext_rtc)
);

task check(input cond, input [8*64-1:0] what);
    if (!cond) begin
        errs = errs + 1;
        $display("FAIL: %0s (t=%0t)", what, $time);
    end
endtask

initial begin
    // 2026-10-13 (Tue) 12:34:56, firmware BCD order
    time_bcd = {8'h26, 8'h10, 8'h13, 8'h02, 8'h12, 8'h34, 8'h56};
    repeat (2) @(negedge clk);
    check(ext_rtc[64] == 0, "strobe starts low");
    check(ext_rtc[63:52] == 12'h0, "upper bits zero");
    time_strobe = 1;
    repeat (2) @(negedge clk);
    check(ext_rtc[64] == 1, "strobe reaches the pack");
    // Nibble map, as SRTC.v unpacks it (REGS[i] <= EXT_RTC[4*i+3:4*i]):
    check(ext_rtc[7:0] == 8'h56, "sec nibbles");
    check(ext_rtc[15:8] == 8'h34, "min nibbles");
    check(ext_rtc[23:16] == 8'h12, "hour nibbles");
    check(ext_rtc[31:24] == 8'h13, "day nibbles");
    check(ext_rtc[35:32] == 4'h0 && ext_rtc[36] == 1'b1, "month 10");
    check(ext_rtc[39:37] == 3'b0, "month pad zero");
    check(ext_rtc[47:40] == 8'h26, "year nibbles");
    check(ext_rtc[51:48] == 4'h2, "weekday nibble");
    // A single-digit month has no +10 flag (May: 0x05).
    time_bcd = {8'h26, 8'h05, 8'h13, 8'h02, 8'h12, 8'h34, 8'h56};
    @(negedge clk);
    check(ext_rtc[35:32] == 4'h5 && ext_rtc[36] == 1'b0, "month 5");

    if (errs == 0) $display("tb_srtc_pack: PASS");
    else $fatal(1, "tb_srtc_pack: FAIL, %0d errors", errs);
    $finish;
end

initial begin #(1_000_000); $fatal(1, "TIMEOUT: sim hang"); end

endmodule
