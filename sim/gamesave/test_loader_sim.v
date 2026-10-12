// Sim-only replacement for src/verilator/test_loader.v: streams a ROM image to
// the core the way iosys does for the firmware's loadsnes(): the 64-byte
// header, then the whole ROM, one byte every 4 clocks, `loading` high until
// the last byte. The image comes from the command line:
//   +rom=<hex file, one byte per line>  +size=<bytes, header included>
module test_loader (
    input clk,
    input resetn,
    output reg [7:0] dout,
    output reg dout_valid,
    output loading,
    output fail
);

localparam MAX = 4 * 1024 * 1024 + 64;
reg [7:0] rom [0:MAX-1];
integer size = 0;
reg [255:0] path;
reg [22:0] addr = 0;
reg [1:0] cnt;
reg [17:0] wait_cnt;

initial begin
    if (!$value$plusargs("size=%d", size)) size = 0;
    if ($value$plusargs("rom=%s", path)) $readmemh(path, rom);
end

// The testbench holds the core in its loading state after the last byte (hold=1,
// public) until it has restored a save, like the firmware does.
reg hold = 1;
assign fail = 1'b0;
assign loading = (addr != size) | hold;

// The firmware streams only after the core answers on the UART, long after the
// SDRAM controller has finished its power-up sequence; start after the same
// kind of wait.
always @(posedge clk) begin
    if (~resetn) begin
        addr <= 0;
        cnt <= 0;
        dout_valid <= 0;
        wait_cnt <= 0;
    end else if (wait_cnt != 18'h3ffff) begin
        wait_cnt <= wait_cnt + 1;
    end else begin
        cnt <= cnt + 1;
        case (cnt)
        2'd0: begin
            dout_valid <= 1;
            dout <= rom[addr];
        end
        2'd1: begin
            dout_valid <= 0;
            if (addr != size)
                addr <= addr + 1;
        end
        2'd2: ;
        2'd3:
            if (addr == size)
                cnt <= 3;       // done
        endcase
    end
end

endmodule
