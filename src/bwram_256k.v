// 256 KB dual-port block RAM for SA-1 BW-RAM: port A is the cartridge bus
// (SA1Map's BSRAM port), port B the iosys save channel. Synchronous reads
// on both ports, like MiSTer's BSRAM dpram. q holds during a write cycle
// (Gowin DPBs have no read-before-write mode); the SA-1 never samples
// BWRAM data in the cycle it writes, and the save FSM reads a cycle after
// presenting the address, so the hold is unobservable.
module bwram_256k (
    input             clk,
    input      [17:0] addr_a,
    input       [7:0] din_a,
    output reg  [7:0] q_a,
    input             we_a,
    input      [17:0] addr_b,
    input       [7:0] din_b,
    output reg  [7:0] q_b,
    input             we_b
);

reg [7:0] mem [0:262143];

always @(posedge clk) begin
    if (we_a) mem[addr_a] <= din_a;
    else q_a <= mem[addr_a];
end

always @(posedge clk) begin
    if (we_b) mem[addr_b] <= din_b;
    else q_b <= mem[addr_b];
end

endmodule
