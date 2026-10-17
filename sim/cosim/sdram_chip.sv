// Behavioral SDRAM chip for the co-sim: answers the exact command subset the
// real sdram_snes (sdram_cl2_2ch) issues (single-word accesses, burst length
// 1, CL2, auto-precharge on every CAS), adapted from the NES cosim's chip
// model. Not a full SDRAM model: refresh, mode-set and precharge are accepted
// and ignored; reads complete 2 fclk after the READ command and the last read
// word stays on DQ (the controller samples once, at cycle[4], and issues
// nothing else on the bus meanwhile).
//
// Address map (16-bit build, as snestang_top): ACT latches
// {bank, row} = {BA[1:0], A[12:0]}; the READ/WRITE column A[8:0] selects the
// word, so the word address is {bank, row, col} = the byte address [23:1] the
// controller builds at {next_addr[24:1]}: bank 0 = ROM/WRAM (with WRAM at the
// 7E/7F end, words 0x3F_0000+), bank 1 = BSRAM/save at word 0x78_0000
// ({5'b01_111, bsram_addr[19:0]}), bank 2 = ARAM at words 0x9E_0000+
// ({9'b10_1111000, aram_addr}); bank 3 is unused. So the array is the full
// 16M-word (32 MB) 4-bank chip. DQM masks write lanes; reads select the lane
// by the controller (it picks the byte by address bit 0 itself).
//
// Power-up: all 0xFFFF (blank BSRAM reads 0xFF, matching the firmware's SNES
// blank and SRAM power-up). Contents are RETAINED across resetn: on hardware
// reprogramming the FPGA does not clear the external SDRAM.
// COSIM debug port: combinational byte read of the array for expect-save-ram;
// mem is also `verilator public` for fast C++ reads. iverilog ignores both.
module sdram_chip (
    input fclk,
    input [12:0] A,
    input [1:0] BA,
    input [1:0] DQM,
    input nCS, nWE, nRAS, nCAS,
    inout [15:0] SDRAM_DQ
`ifdef COSIM
    , input [23:0] dbg_addr,
    output [7:0] dbg_data
`endif
);

reg [12:0] row_lat [0:3];
reg [15:0] mem [0:(1<<24)-1] /*verilator public*/;

integer i;
initial begin
    for (i = 0; i < (1 << 24); i = i + 1)
        mem[i] = 16'hFFFF;
end

wire [3:0] cmd = {nCS, nRAS, nCAS, nWE};
wire [23:0] word = {BA, row_lat[BA], A[8:0]};
reg rv0 = 0, rv1 = 0;
reg [15:0] rq0 = 0, rq1 = 0;

always @(posedge fclk) begin
    if (cmd == 4'b0011)
        row_lat[BA] <= A[12:0];
    else if (cmd == 4'b0100) begin
        if (!DQM[0])
            mem[word][7:0] <= SDRAM_DQ[7:0];
        if (!DQM[1])
            mem[word][15:8] <= SDRAM_DQ[15:8];
    end
    {rv1, rq1} <= {rv0, rq0};
    {rv0, rq0} <= {cmd == 4'b0101, mem[word]};
end

assign SDRAM_DQ = rv1 ? rq1 : 16'hzzzz;

`ifdef COSIM
wire [22:0] dbg_word = dbg_addr[23:1];
assign dbg_data = dbg_addr[0] ? mem[dbg_word][15:8] : mem[dbg_word][7:0];
`endif

endmodule
