// Wrapper for the headless SNES game sim: the real snestang_top (VERILATOR
// build: clocks derived from sys_clk, ROM from test_loader, no iosys), with the
// REAL sdram_snes controller and the co-sim's behavioral SDRAM chip on its
// SDRAM pins instead of src/verilator/sdram_sim.v. That model drops a BSRAM
// request that lands in the same cycle as a ROM fetch; the controller queues it.
module gamesave_top (
    input sys_clk
);

wire        sdram_clk, sdram_cke, sdram_cs_n, sdram_cas_n, sdram_ras_n, sdram_wen_n;
wire [15:0] sdram_dq;
wire [12:0] sdram_addr;
wire [1:0]  sdram_ba, sdram_dqm;

snestang_top u (
    .sys_clk(sys_clk), .s0(1'b0), .UART_RXD(1'b1), .UART_TXD(),
    .tmds_clk_p(), .tmds_clk_n(), .tmds_d_p(), .tmds_d_n(), .led(),
    .O_sdram_clk(sdram_clk), .O_sdram_cke(sdram_cke), .O_sdram_cs_n(sdram_cs_n),
    .O_sdram_cas_n(sdram_cas_n), .O_sdram_ras_n(sdram_ras_n), .O_sdram_wen_n(sdram_wen_n),
    .IO_sdram_dq(sdram_dq), .O_sdram_addr(sdram_addr), .O_sdram_dqm(sdram_dqm),
    .O_sdram_ba(sdram_ba)
);

sdram_chip chip (
    .fclk(u.fclk),
    .A(sdram_addr), .BA(sdram_ba), .DQM(sdram_dqm),
    .nCS(sdram_cs_n), .nWE(sdram_wen_n), .nRAS(sdram_ras_n), .nCAS(sdram_cas_n),
    .SDRAM_DQ(sdram_dq)
);

endmodule
