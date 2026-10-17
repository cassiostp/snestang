// Full snestang_top (VERILATOR clocks and loader) with the real sdram_snes
// controller on its pins and the cycle-accurate SDRAM chip from sim/cosim.
//
// Hardware clocks the SDRAM pin from fclk_p (gowin_pll_snes CLKOUT2, phase
// PE_COARSE=19 / PE_FINE=3; mclk and fclk themselves are both phase 0, so
// their rising edges line up, fclk = 3 * mclk). This chip model is not a
// timing model: it presents CL2 read data on the controller clock, valid at
// the sample in sdram_cl2_2ch (cycle[4] for the CPU lane, cycle[1] for
// ARAM). That is the same wiring sim/sdram_port and sim/gamesave use, and
// it is what a phase shift that meets that sample looks like. Driving the
// model from the shifted pin would move the data off the sample edge.
module snes_realsdram_top (
    input sys_clk,
    input s0,
    input UART_RXD,
    output UART_TXD
);

wire        sdram_clk, sdram_cke, sdram_cs_n, sdram_cas_n, sdram_ras_n, sdram_wen_n;
wire [15:0] sdram_dq;
wire [12:0] sdram_addr;
wire [1:0]  sdram_ba, sdram_dqm;

snestang_top snestang_top (
    .sys_clk(sys_clk), .s0(s0), .UART_RXD(UART_RXD), .UART_TXD(UART_TXD),
    .tmds_clk_p(), .tmds_clk_n(), .tmds_d_p(), .tmds_d_n(), .led(),
    .O_sdram_clk(sdram_clk), .O_sdram_cke(sdram_cke), .O_sdram_cs_n(sdram_cs_n),
    .O_sdram_cas_n(sdram_cas_n), .O_sdram_ras_n(sdram_ras_n), .O_sdram_wen_n(sdram_wen_n),
    .IO_sdram_dq(sdram_dq), .O_sdram_addr(sdram_addr), .O_sdram_dqm(sdram_dqm),
    .O_sdram_ba(sdram_ba)
);

sdram_chip chip (
    .fclk(snestang_top.fclk),
    .A(sdram_addr), .BA(sdram_ba), .DQM(sdram_dqm),
    .nCS(sdram_cs_n), .nWE(sdram_wen_n), .nRAS(sdram_ras_n), .nCAS(sdram_cas_n),
    .SDRAM_DQ(sdram_dq)
);

endmodule
