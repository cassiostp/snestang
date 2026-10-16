// GSU test-ROM loader: same shape as equiv/loader_zelda.v. The .hex starts
// with a 512-byte SMC-style header whose first 64 bytes are the ROM's real
// SNES header (smc_parser samples stream offsets 0x15-0x1A), then the
// headerless 32KB image; bytes 64-511 are skipped.

module test_loader (
    input clk,
    input resetn,
    output reg [7:0] dout,
    output reg dout_valid,
    output loading,
    output fail
);

localparam SIZE = 33280;
localparam string FILE = "roms/gsu.hex";
localparam [$clog2(SIZE)-1:0] LAST = $clog2(SIZE)'(SIZE - 1);

reg [7:0] rom [0:SIZE-1];
initial begin
   $readmemh(FILE, rom);
end

reg [$clog2(SIZE)-1:0] addr = 0;
assign fail = 1'b0;
assign loading = addr != LAST;
reg [1:0] cnt;

always @(posedge clk) begin
    if (~resetn) begin
        addr <= 0;
    end else begin
        cnt <= cnt + 1;
        case (cnt)
        2'd0: begin
            dout_valid <= 1;
            dout <= rom[addr];
        end
        2'd1: begin
            dout_valid <= 0;
            addr <= addr + 1;
            if (addr == 63)
                addr <= 512;
        end
        2'd2: ;
        2'd3:
            if (addr == LAST)
                cnt <= 3;
        endcase
    end
end

endmodule
