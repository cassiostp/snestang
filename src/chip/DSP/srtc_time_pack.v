// Pack the firmware wall-clock frame (0x14, via iosys) into the S-RTC's
// nibble map: the MiSTer hps_io RTC format that SRTC.v reloads whenever
// bit 64 toggles. The firmware sends BCD bytes year mon day wday hour min
// sec, so each byte splits straight into its two nibbles; the S-RTC
// free-runs at 1 Hz between the firmware's 10 s resyncs.
module srtc_time_pack(
    input      [55:0] time_bcd,     // BCD year mon day wday hour min sec
    input             time_strobe,  // toggles per received frame
    output     [64:0] ext_rtc
);

assign ext_rtc = {time_strobe, 12'b0,
                  time_bcd[27:24],                  // wday [51:48]
                  time_bcd[55:52], time_bcd[51:48], // year [47:40]
                  3'b0, time_bcd[44], time_bcd[43:40], // mon +10 [36], [35:32]
                  time_bcd[39:36], time_bcd[35:32], // day [31:24]
                  time_bcd[23:20], time_bcd[19:16], // hour [23:16]
                  time_bcd[15:12], time_bcd[11:8],  // min [15:8]
                  time_bcd[7:4], time_bcd[3:0]};    // sec [7:0]

endmodule
