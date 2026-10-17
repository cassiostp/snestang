// Smoke-test ROM loader: streams a make_rom.py .hex through the real
// loader/smc_parser path. SIZE is the largest image in the suite (build
// time); the per-game stream length comes from roms/size.txt at runtime so
// one model build serves every ROM. The .hex starts with a 512-byte header
// whose first 64 bytes are the ROM's real SNES header; bytes 64-511 are
// skipped.

module test_loader (
    input clk,
    input resetn,
    output reg [7:0] dout,
    output reg dout_valid,
    output loading,
    output fail
);

localparam SIZE = @SIZE@;
localparam string FILE = "roms/game.hex";
localparam [$clog2(SIZE)-1:0] SIZEM1 = $clog2(SIZE)'(SIZE - 1);

reg [7:0] rom [0:SIZE-1];
reg [$clog2(SIZE)-1:0] LAST;
initial begin
   integer fd;
   $readmemh(FILE, rom);
   LAST = SIZEM1;
   fd = $fopen("roms/size.txt", "r");
   if (fd != 0) begin
      if ($fscanf(fd, "%d", LAST) != 1) LAST = SIZEM1;
      $fclose(fd);
   end
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
            if (addr == 63)     // header is 64 bytes long (parser window)
                addr <= 512;
        end
        2'd2: ;
        2'd3:
            if (addr == LAST)
                cnt <= 3;       // done
        endcase
    end
end

endmodule
