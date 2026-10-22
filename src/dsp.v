// Timing
// - DSP is active roughly once every 4 mclk cycles
// - Every active DSP cycle increments SUBSTEP (0~3), then STEP (0~31)
// - SMP is active (SMP_EN) when SUBSTEP == 3

module DSP(
    input CLK,                  // mclk: 21.6Mhz
    input RST_N,
    input ENABLE,               // 0: switch to debug memory access
    input PAL,

    // SMP interface
    output SMP_EN,              // SMP is active on SUBSTEP 3
    input [15:0] SMP_A,
    input [7:0] SMP_DO,
    output reg [7:0] SMP_DI,
    input SMP_WE_N  /* synthesis syn_keep=1 */,
    output SMP_CE,

    // memmux interface
    output reg [15:0] RAM_A,
    input [7:0] RAM_Q,
    output reg [7:0] RAM_D,
    output RAM_WE_N,
    output RAM_OE_N,
    output RAM_CE_N,

    output reg [15:0] AUDIO_L,
    output reg [15:0] AUDIO_R,
    output reg SND_RDY,         // pulse when AUDIO_L and AUDIO_R is ready

    // debug
    input [7:0] DBG_REG,
    input [7:0] DBG_DAT_IN,
    output reg [7:0] DBG_DAT_OUT,
    input DBG_DAT_WR

`ifdef SNES_SAVESTATE
    ,input ss_hold,
    input [12:0] ss_a,
    input [7:0] ss_d,
    input ss_we,
    output reg [7:0] ss_q
`endif
);
`ifdef SNES_SAVESTATE
wire [7:0] ss_q_ce;
`endif


`include "dsp.vh"

// set this to non-zero to mute voices corresponding to 1's
// e.g. 8'b1111_1110 will only play voice 0
localparam [7:0] MUTE_MASK = 8'b0;
// reg started;                // for debug: when first KON is set

reg RAM_WE, RAM_OE, RAM_CE;
wire [7:0] RAM_DI;
reg [7:0] RAM_DO;

wire LRCK, BCK, SDAT;       // obsolete audio output interface

reg [7:0] RI;               // register value from SMP
reg [6:0] REGN_RD, REGN_WR; // current register for read/write
wire [6:0] REGS_ADDR_WR, REGS_ADDR_RD;
wire [7:0] REGS_DI;         // value to write to register
`ifdef SNES_SAVESTATE
wire [7:0] REGS_DO;
`else
reg [7:0] REGS_DO;
`endif          // value read from reg
wire REGS_WE;               // 1: write to register

wire SMP_EN_INT;            // run SMP in this cycle when last_phase is 1
reg [4:0] STEP_CNT;
reg [1:0] SUBSTEP_CNT;
wire [4:0] STEP;            // 0-31
wire [1:0] SUBSTEP;         // 0-3
wire [2:0] BRR_VOICE;       // current active voice

reg RST_FLG, MUTE_FLG, ECEN_FLG;
reg [7:0] WKON;             // Key-ON from register write
reg [7:0] TKON, TKOFF;      // Start/fade off the voice specified
reg [2:0] KON_CNT[0:7];     // After Key-ON, a voice goes through 5,4,3,2,1

reg [7:0] TSRCN;            // $x4: source/sample number (0-255)
reg [7:0] TDIR;             // $5D: DIR location: {TDIR, 8'b0}
reg [14:0] TPITCH;          // $x2/$x3: Pitch
reg [7:0] TADSR1, TADSR2;   // $x5/$x6: Per voice Attach-Decay-Sustain-Release control
reg [7:0] TNON;             // $3D: 1bit per voice: noise on
reg [7:0] TESA;             // $6D: global: echo waveform directory location
reg [7:0] TEON;             // $4D: 1bit per voice: echo on
reg [7:0] TPMON;            // $2D: 1bit per voice: pitch modulation ON
reg [7:0] ENDX, ENDX_BUF;   // $7C: 1bit per voice: BRR decoder has reached the block in sample
reg [7:0] OUTX_OUT;         // $x9: wave height multiplied by the ADSR/GAIN envelope value
reg [7:0] ENVX_OUT;         // $x8: present ADSR/GAIN envelope value
reg [7:0] TENVX [8];
reg EVEN_SAMPLE;            // flip every 32-cycle loop at VS_ESA time
reg BRR_DECODE_EN;

shortint TOUT;
reg signed [14:0] NOISE;
reg [15:0] OUTL;
reg [15:0] OUTR;
reg [31:0] OUTPUT;
shortint MOUT[0:1];
shortint EOUT[0:1];

reg [15:0] TDIR_ADDR;           // dir address for current sample
reg [15:0] BRR_NEXT_ADDR;       // next sample address
reg [15:0] BRR_ADDR[0:7];       // sample address for each channel
reg [2:0] BRR_OFFS[0:7];
reg [15:0] TBRRDAT;             // sample data (a pair of bytes)
reg [7:0] TBRRHDR;              // sample header
reg [7:0] BRR_END;
reg [3:0] BRR_BUF_ADDR [8];     // last written pos in the ring buffer

reg [6:0] BRR_BUF_ADDR_A;
reg BRR_BUF_WE;
reg signed [15:0] BRR_BUF_DI;
`ifdef SNES_SAVESTATE
wire signed [15:0] BRR_BUF_DO;
`else
reg signed [15:0] BRR_BUF_DO;
`endif
reg [6:0] BRR_BUF_ADDR_B;
`ifdef SNES_SAVESTATE
wire signed [15:0] BRR_BUF_GAUSS_DO;
`else
reg signed [15:0] BRR_BUF_GAUSS_DO;
`endif
reg [3:0] BRR_BUF_ADDR_B_NEXT;

reg [2:0] GS_STATE;
reg [8:0] GTBL_ADDR;
reg signed [11:0] GTBL_DO;
reg [7:0] GTBL_POS;
reg [2:0] G_VOICE;
reg signed [16:0] SUM012;

reg [1:0] BD_STATE;
reg signed [15:0] SR;
reg [2:0] BD_VOICE;
reg signed [16:0] P0;

reg [14:0] ECHO_POS;
reg [15:0] ECHO_ADDR;
reg [14:0] ECHO_BUF[0:1][0:7];
reg [14:0] ECHO_LEN;
reg [6:0] ECHO_DATA_TEMP;
reg ECHO_WR_EN;
reg signed [15:0] ECHO_FIR[2];
reg signed [7:0] ECHO_FFC[8];
reg [2:0] FFC_CNT;
reg signed [15:0] ECHO_FIR_TEMP[2];

reg [1:0] ENV_MODE[0:7];        // envelope mode
reg signed [11:0] ENV[0:7];
reg [7:0] BENT_INC_MODE;
reg [15:0] INTERP_POS[0:7];     // interpolation position, [14:12]: BBRpos, [11:0]: GTBLpos
reg signed [11:0] LAST_ENV;

reg [11:0] GCNT_BY1;
reg [11:0] GCNT_BY3;
reg [11:0] GCNT_BY5;

typedef logic [11:0] GCntMask_t [0:31];
localparam GCntMask_t GCNT_MASK = '{
    12'hFFF, 12'h7FF, 12'h7FF,
    12'h7FF, 12'h3FF, 12'h3FF,
    12'h3FF, 12'h1FF, 12'h1FF,
    12'h1FF, 12'h0FF, 12'h0FF,
    12'h0FF, 12'h07F, 12'h07F,
    12'h07F, 12'h03F, 12'h03F,
    12'h03F, 12'h01F, 12'h01F,
    12'h01F, 12'h00F, 12'h00F,
    12'h00F, 12'h007, 12'h007,
    12'h007, 12'h003, 12'h003,
             12'h001,
             12'h000 };

function logic GCOUNT_TRIGGER(logic [4:0] r);
    case (r)
    1, 4, 7, 10, 13, 16, 19, 22, 25, 28, 30:
        return (GCNT_BY1 & GCNT_MASK[r]) == 12'b0;
    2, 5, 8, 11, 14, 17, 20, 23, 26, 29:
        return (GCNT_BY3 & GCNT_MASK[r]) == 12'b0;
    3, 6, 9, 12, 15, 18, 21, 24, 27:
        return (GCNT_BY5 & GCNT_MASK[r]) == 12'b0;
    31:
        return 1'b1;
    default:
        return 1'b0;
    endcase
endfunction

VoiceStep_r VS;
wire [3:0] RS;
BRRDecodeStep_r BDS;
IntStep_r INS;

//debug
reg [15:0] DBG_ADDR;
reg DBG_DAT_WRr;
reg [7:0] DBG_VMUTE = 8'b0;

wire CE;
`ifdef SNES_SAVESTATE
wire CEGEN_RST_N = RST_N & (ENABLE
`ifdef SNES_SAVESTATE
    | ss_hold
`endif
);
`else
wire CEGEN_RST_N = RST_N & ENABLE;
`endif

CEGen cegen (
`ifdef SNES_SAVESTATE
    .ss_hold(ss_hold), .ss_a(ss_a), .ss_d(ss_d), .ss_we(ss_we), .ss_q(ss_q_ce),
`endif

  .CLK(CLK), .RST_N(CEGEN_RST_N),
  .IN_CLK(2147730),
  .OUT_CLK(ACLK_FREQ),
  .CE(CE)
);

assign SMP_EN = SMP_EN_INT;
assign SMP_CE = CE;

always @(posedge CLK) begin
`ifdef SNES_SAVESTATE
    if (ss_we) begin
      case (ss_a)
        13'h1007: STEP_CNT[4:0] <= ss_d[4:0];
        13'h1008: SUBSTEP_CNT[1:0] <= ss_d[1:0];
        default: ;
      endcase
    end else if (!ss_hold || !RST_N) begin
`endif

    if (~RST_N) begin
        STEP_CNT <= 5'b0;
        SUBSTEP_CNT <= 2'b0;
    end else if (ENABLE && CE) begin
        SUBSTEP_CNT <= SUBSTEP_CNT + 1;
        if (SUBSTEP_CNT == 3)
            STEP_CNT <= STEP_CNT + 1;
    end

`ifdef SNES_SAVESTATE
    end
`endif
end

assign SMP_EN_INT = SUBSTEP == 3 ? ENABLE : 1'b0;

assign STEP = STEP_CNT;
assign SUBSTEP = SUBSTEP_CNT;

assign REGS_ADDR_WR = /* ENABLE == 1'b0 ? DBG_REG[6:0] :*/ REGN_WR;
assign REGS_ADDR_RD = /* ENABLE == 1'b0 ? DBG_REG[6:0] :*/ REGN_RD;
assign REGS_DI = /*ENABLE == 1'b0 ? DBG_DAT_IN :*/ SUBSTEP == 3 ? SMP_DO : 
                REGN_WR[3:0] == 4'h8 ? ENVX_OUT : 
                REGN_WR[3:0] == 4'h9 ? OUTX_OUT : 
                SMP_DO;
assign REGS_WE = /*ENABLE == 1'b0 && DBG_REG[7] == 1'b0 ? DBG_DAT_WR : */
                ~SMP_WE_N && SMP_A == 16'h00F3 && SUBSTEP == 3 && CE ? 1'b1 :
                REGN_WR[3:1] == 3'b100 && SUBSTEP == 0 && CE ? 1'b1 : 
                1'b0;

`ifdef SNES_SAVESTATE
// Borrow the register RAM read port while frozen; preserve its console latch.
wire ss_regram_sel = ss_a >= 13'h10ee && ss_a < 13'h116e;
wire [6:0] ss_regram_addr = ss_a - 13'h10ee;
wire [6:0] regram_addr = ss_hold ? ss_regram_addr : REGS_ADDR_RD;
reg [7:0] REGRAM[0:127] /* synthesis syn_ramstyle = "block_ram" */;
reg [7:0] regram_raw, regram_saved;
reg ss_ram_old = 0, ss_ram_saved = 0;
assign REGS_DO = ss_ram_saved ? regram_saved : regram_raw;
always @(posedge CLK) begin
    if (ss_hold) begin
        if (ss_we && ss_regram_sel) REGRAM[ss_regram_addr] <= ss_d;
    end else if (REGS_WE) REGRAM[REGS_ADDR_WR] <= REGS_DI;
    regram_raw <= REGRAM[regram_addr];
end
always @(posedge CLK) begin
    ss_ram_old <= ss_hold;
    if (ss_hold && !ss_ram_old) begin
        regram_saved <= REGS_DO;
        ss_ram_saved <= 1;
    end
    if (!ss_hold) ss_ram_saved <= 0;
    if (ss_we && ss_a == 13'h1006) regram_saved <= ss_d;
end
`else
// Dual-port BRAM for registers (128 bytes)
reg [7:0] REGRAM[0:127]     /* synthesis syn_ramstyle = "block_ram" */;
always @(posedge CLK) begin
    if (REGS_WE) begin
        REGRAM[REGS_ADDR_WR] <= REGS_DI;
        // $display("DSP register [%x] <= %x", REGS_ADDR_WR, REGS_DI);
    end
end
always @(posedge CLK) begin
    REGS_DO <= REGRAM[REGS_ADDR_RD];
end

`endif
always @(posedge CLK) begin
`ifdef SNES_SAVESTATE
    if (ss_we) begin
      case (ss_a)
        13'h1005: RI[7:0] <= ss_d;
        default: ;
      endcase
    end else if (!ss_hold || !RST_N) begin
`endif

    if (~RST_N) begin
        RI <= 8'b0;
    end else if (ENABLE && CE) begin 
        if (SMP_EN_INT && ~SMP_WE_N && SMP_A == 16'h00F2) 
            RI <= SMP_DO;
    end

`ifdef SNES_SAVESTATE
    end
`endif
end

always @* begin
    if (SMP_A == 16'h00F2)
        SMP_DI = RI;
    else if (SMP_A == 16'h00F3) begin
        if (RI[6:0] == 7'b1111100)    //ENDX
            SMP_DI = ENDX;
        else 
            SMP_DI = REGS_DO;
    end else 
        SMP_DI = RAM_DI;
end

always @* begin : reg_read
    reg [7:0] REG;

    REG = RA_TBL[STEP][SUBSTEP];
    if (SUBSTEP == 3) 
        REGN_RD = RI[6:0];
    else if (REG[3:0] == 4'h6) 
        REGN_RD = {REG[6:1], ~TADSR1[7]};
    else 
        REGN_RD = REG[6:0];

    if (SUBSTEP == 3) 
        REGN_WR = RI[6:0];
    else
        REGN_WR = RA_TBL[STEP][SUBSTEP][6:0];
end

assign VS = VS_TBL[STEP][SUBSTEP];
assign RS = RS_TBL[STEP][SUBSTEP];
assign BRR_VOICE = BRR_VOICE_TBL[STEP];
assign BDS = BDS_TBL[STEP][SUBSTEP];
assign INS = IS_TBL[STEP][SUBSTEP];

reg [7:0] SMP_DO_buf;
reg [15:0] SMP_A_buf;
reg SMP_WE_N_buf;
always @(posedge CLK) begin
`ifdef SNES_SAVESTATE
    if (ss_we) begin
      case (ss_a)
        13'h116e: SMP_DO_buf[7:0] <= ss_d;
        13'h116f: SMP_A_buf[7:0] <= ss_d;
        13'h1170: SMP_A_buf[15:8] <= ss_d;
        13'h1171: SMP_WE_N_buf <= ss_d[0:0];
        default: ;
      endcase
    end else if (!ss_hold || !RST_N) begin
`endif

    SMP_DO_buf <= SMP_DO;
    SMP_A_buf <= SMP_A;
    SMP_WE_N_buf <= SMP_WE_N;

`ifdef SNES_SAVESTATE
    end
`endif
end

always @* begin : ram_addrgen
    reg [1:0] ADDR_INC;
    reg LR;

    RAM_DO = 8'h00;
    ADDR_INC = 2'b0;        // remove latch
    LR = 0;                 // remove latch
    case (RS)
    RS_SRCNL : begin      // 4: read directory entry low 8bit
        if (KON_CNT[BRR_VOICE] == 0) 
            ADDR_INC = 2'b10;
        else 
            ADDR_INC = 2'b00;

        RAM_A = TDIR_ADDR + 16'(ADDR_INC);
        RAM_WE = 1'b0;
        RAM_OE = 1'b1;
        RAM_CE = 1'b1;
    end

    RS_SRCNH : begin      // 5: read directory entry high 8bit
        if (KON_CNT[BRR_VOICE] == 0) 
            ADDR_INC = 2'b10;
        else 
            ADDR_INC = 2'b00;

        RAM_A = TDIR_ADDR + 16'(ADDR_INC) + 16'd1;
        RAM_WE = 1'b0;
        RAM_OE = 1'b1;
        RAM_CE = 1'b1;
    end

    RS_BRRH : begin       // 1: read BRR header
        RAM_A = BRR_ADDR[BRR_VOICE];
        RAM_WE = 1'b0;
        RAM_OE = 1'b1;
        RAM_CE = 1'b1;
    end

    RS_BRR1 : begin       // 2: read BRR higher 2 nibble
        RAM_A = BRR_ADDR[BRR_VOICE] + 16'(BRR_OFFS[BRR_VOICE]) + 16'd1;
        RAM_WE = 1'b0;
        RAM_OE = 1'b1;
        RAM_CE = 1'b1;
    end

    RS_BRR2 : begin       // 3: read BRR block 2
        RAM_A = BRR_ADDR[BRR_VOICE] + 16'(BRR_OFFS[BRR_VOICE]) + 16'd2;
        RAM_WE = 1'b0;
        RAM_OE = 1'b1;
        RAM_CE = 1'b1;
    end

    RS_ECHORDL,RS_ECHORDH : begin // 6, 7
        if (STEP == 22) 
            ADDR_INC = 2'b00;
        else 
            ADDR_INC = 2'b10;

        if (RS == RS_ECHORDL) 
            RAM_A = {TESA,8'h00} + ECHO_POS + 16'(ADDR_INC);
        else 
            RAM_A = {TESA,8'h00} + ECHO_POS + 16'(ADDR_INC) + 16'd1;

        RAM_WE = 1'b0;
        RAM_OE = 1'b1;
        RAM_CE = 1'b1;
    end

    RS_ECHOWRL,RS_ECHOWRH : begin // 8, 9
        if (STEP == 29) begin
            ADDR_INC = 2'b00;
            LR = 0;
        end else begin
            ADDR_INC = 2'b10;
            LR = 1;
        end

        if (RS == RS_ECHOWRL) begin
            RAM_A = {TESA,8'h00} + ECHO_POS + 16'(ADDR_INC);
            RAM_DO = EOUT[LR][7:0];
        end else begin
            RAM_A = {TESA,8'h00} + ECHO_POS + 16'(ADDR_INC) + 16'd1;
            RAM_DO = EOUT[LR][15:8];
        end

        if (ECHO_WR_EN) begin
            RAM_CE = 1'b1;
            RAM_OE = 1'b0;
            RAM_WE = 1'b1;
        end else begin
            RAM_CE = 1'b0;
            RAM_OE = 1'b0;
            RAM_WE = 1'b0;
        end
    end

    // nand2mario: do memory operation in the first phase, so that read data is 
    // available to SMP in second(last) phase earlier (end of first phase), for better timing
    RS_SMP : begin
        RAM_A = SMP_A_buf;
        RAM_WE = ~SMP_WE_N_buf;
        RAM_OE = SMP_WE_N_buf;
        RAM_DO = SMP_DO_buf;            // buffered to satisfy timing checker  
        if (SMP_A_buf[15:4]== 12'h00F)
            RAM_CE = 0;
        else
            RAM_CE = 1;
    end

    default : begin
        RAM_A = 16'b0;
        RAM_WE = 1'b0;
        RAM_OE = 1'b0;
        RAM_CE = 1'b0;
    end
    endcase

end

always @(posedge CLK) begin : ram_process
    reg LR;
`ifdef SNES_SAVESTATE
    if (ss_we) begin
      case (ss_a)
        13'h1045: BRR_NEXT_ADDR[7:0] <= ss_d;
        13'h1046: BRR_NEXT_ADDR[15:8] <= ss_d;
        13'h105f: TBRRDAT[7:0] <= ss_d;
        13'h1060: TBRRDAT[15:8] <= ss_d;
        13'h1061: TBRRHDR[7:0] <= ss_d;
        13'h1088: ECHO_BUF[0][0][7:0] <= ss_d;
        13'h1089: ECHO_BUF[0][0][14:8] <= ss_d[6:0];
        13'h108a: ECHO_BUF[0][1][7:0] <= ss_d;
        13'h108b: ECHO_BUF[0][1][14:8] <= ss_d[6:0];
        13'h108c: ECHO_BUF[0][2][7:0] <= ss_d;
        13'h108d: ECHO_BUF[0][2][14:8] <= ss_d[6:0];
        13'h108e: ECHO_BUF[0][3][7:0] <= ss_d;
        13'h108f: ECHO_BUF[0][3][14:8] <= ss_d[6:0];
        13'h1090: ECHO_BUF[0][4][7:0] <= ss_d;
        13'h1091: ECHO_BUF[0][4][14:8] <= ss_d[6:0];
        13'h1092: ECHO_BUF[0][5][7:0] <= ss_d;
        13'h1093: ECHO_BUF[0][5][14:8] <= ss_d[6:0];
        13'h1094: ECHO_BUF[0][6][7:0] <= ss_d;
        13'h1095: ECHO_BUF[0][6][14:8] <= ss_d[6:0];
        13'h1096: ECHO_BUF[0][7][7:0] <= ss_d;
        13'h1097: ECHO_BUF[0][7][14:8] <= ss_d[6:0];
        13'h1098: ECHO_BUF[1][0][7:0] <= ss_d;
        13'h1099: ECHO_BUF[1][0][14:8] <= ss_d[6:0];
        13'h109a: ECHO_BUF[1][1][7:0] <= ss_d;
        13'h109b: ECHO_BUF[1][1][14:8] <= ss_d[6:0];
        13'h109c: ECHO_BUF[1][2][7:0] <= ss_d;
        13'h109d: ECHO_BUF[1][2][14:8] <= ss_d[6:0];
        13'h109e: ECHO_BUF[1][3][7:0] <= ss_d;
        13'h109f: ECHO_BUF[1][3][14:8] <= ss_d[6:0];
        13'h10a0: ECHO_BUF[1][4][7:0] <= ss_d;
        13'h10a1: ECHO_BUF[1][4][14:8] <= ss_d[6:0];
        13'h10a2: ECHO_BUF[1][5][7:0] <= ss_d;
        13'h10a3: ECHO_BUF[1][5][14:8] <= ss_d[6:0];
        13'h10a4: ECHO_BUF[1][6][7:0] <= ss_d;
        13'h10a5: ECHO_BUF[1][6][14:8] <= ss_d[6:0];
        13'h10a6: ECHO_BUF[1][7][7:0] <= ss_d;
        13'h10a7: ECHO_BUF[1][7][14:8] <= ss_d[6:0];
        13'h10aa: ECHO_DATA_TEMP[6:0] <= ss_d[6:0];
        default: ;
      endcase
    end else if (!ss_hold || !RST_N) begin
`endif


    if (~RST_N) begin
        BRR_NEXT_ADDR <= 16'b0;
        TBRRHDR <= 8'b0;
        TBRRDAT <= 16'b0;
        ECHO_BUF <= '{2{'{8{15'b0}}}};
        ECHO_DATA_TEMP <= 7'b0;
    end else if (ENABLE && CE) begin
        case (RS)
        RS_SRCNL : 
            BRR_NEXT_ADDR[7:0] <= RAM_DI;
        RS_SRCNH : 
            BRR_NEXT_ADDR[15:8] <= RAM_DI;
        RS_BRRH :  begin
            TBRRHDR <= RAM_DI;
            // if (started && BRR_VOICE == 3)
            //     $fdisplay(32'h80000002, "BRR header=%x", RAM_DI);
        end
        RS_BRR1 :  begin
            TBRRDAT[15:8] <= RAM_DI;
            // if (started && BRR_VOICE == 3)
            //     $fdisplay(32'h80000002, "BRR datah=%x", RAM_DI);
        end
        RS_BRR2 : begin
            TBRRDAT[7:0] <= RAM_DI;
            // if (started && BRR_VOICE == 3)
            //     $fdisplay(32'h80000002, "BRR datal=%x", RAM_DI);
        end
        RS_ECHORDL,RS_ECHORDH : begin
            if (STEP == 22) 
                LR = 0;
            else 
                LR = 1;

            if (RS == RS_ECHORDL) 
                ECHO_DATA_TEMP <= RAM_DI[7:1];
            else begin
                ECHO_BUF[LR][0] <= ECHO_BUF[LR][1];
                ECHO_BUF[LR][1] <= ECHO_BUF[LR][2];
                ECHO_BUF[LR][2] <= ECHO_BUF[LR][3];
                ECHO_BUF[LR][3] <= ECHO_BUF[LR][4];
                ECHO_BUF[LR][4] <= ECHO_BUF[LR][5];
                ECHO_BUF[LR][5] <= ECHO_BUF[LR][6];
                ECHO_BUF[LR][6] <= ECHO_BUF[LR][7];
                ECHO_BUF[LR][7] <= {RAM_DI, ECHO_DATA_TEMP};
            end
        end
        default : ;
        endcase
    end

`ifdef SNES_SAVESTATE
    end
`endif
end

assign RAM_D = RAM_DO;
assign RAM_DI = RAM_Q;

assign RAM_WE_N = ~RAM_WE;
assign RAM_OE_N = ~RAM_OE;
assign RAM_CE_N = ~RAM_CE;

`ifdef SNES_SAVESTATE
// Keep both sample-buffer ports synchronous so the buffer remains BSRAM.
wire ss_brr_sel = ss_a >= 13'h1172 && ss_a < 13'h1272;
wire [7:0] ss_brr_offset = ss_a - 13'h1172;
wire [6:0] brr_addr_a = ss_hold ? ss_brr_offset[7:1] : BRR_BUF_ADDR_A;
reg [7:0] ss_brr_low;
reg signed [15:0] BRR_BUF[0:127] /* synthesis syn_ramstyle = "block_ram" */;
reg signed [15:0] brr_raw_a, brr_raw_b, brr_saved_a, brr_saved_b;
assign BRR_BUF_DO = ss_ram_saved ? brr_saved_a : brr_raw_a;
assign BRR_BUF_GAUSS_DO = ss_ram_saved ? brr_saved_b : brr_raw_b;
always @(posedge CLK) begin
    if (ss_hold) begin
        if (ss_we && ss_brr_sel && ss_brr_offset[0])
            BRR_BUF[brr_addr_a] <= {ss_d, ss_brr_low};
        brr_raw_a <= BRR_BUF[brr_addr_a];
    end else if (BRR_BUF_WE) BRR_BUF[BRR_BUF_ADDR_A] <= BRR_BUF_DI;
    else brr_raw_a <= BRR_BUF[BRR_BUF_ADDR_A];
end
always @(posedge CLK) brr_raw_b <= BRR_BUF[BRR_BUF_ADDR_B];
always @(posedge CLK) begin
    if (ss_hold && !ss_ram_old) begin
        brr_saved_a <= BRR_BUF_DO;
        brr_saved_b <= BRR_BUF_GAUSS_DO;
    end
    if (ss_we && ss_brr_sel && !ss_brr_offset[0]) ss_brr_low <= ss_d;
    if (ss_we) case (ss_a)
    13'h106f: brr_saved_a[7:0] <= ss_d;
    13'h1070: brr_saved_a[15:8] <= ss_d;
    13'h1072: brr_saved_b[7:0] <= ss_d;
    13'h1073: brr_saved_b[15:8] <= ss_d;
    default: ;
    endcase
end
`else
reg signed [15:0] BRR_BUF [128];     // [0:7][0:11]

always @(posedge CLK) begin
    if (BRR_BUF_WE)
        BRR_BUF[BRR_BUF_ADDR_A] <= BRR_BUF_DI;
    else
        BRR_BUF_DO <= BRR_BUF[BRR_BUF_ADDR_A];
end
always @(posedge CLK) begin
    BRR_BUF_GAUSS_DO <= BRR_BUF[BRR_BUF_ADDR_B];
end

`endif
always @(posedge CLK) begin : brr_decode
    logic [1:0] FILTER;
    logic [3:0] SCALE;
    logic signed [15:0] SOUT;
    logic signed [16:0] P1;
    logic signed [16:0] SF;
    logic signed [15:0] S;   // original sample -8 ~ 7
    logic [3:0] BRR_BUF_ADDR_PREV;
    logic [3:0] BRR_BUF_ADDR_NEXT;
`ifdef SNES_SAVESTATE
    if (ss_we) begin
      case (ss_a)
        13'h1063: BRR_BUF_ADDR[0][3:0] <= ss_d[3:0];
        13'h1064: BRR_BUF_ADDR[1][3:0] <= ss_d[3:0];
        13'h1065: BRR_BUF_ADDR[2][3:0] <= ss_d[3:0];
        13'h1066: BRR_BUF_ADDR[3][3:0] <= ss_d[3:0];
        13'h1067: BRR_BUF_ADDR[4][3:0] <= ss_d[3:0];
        13'h1068: BRR_BUF_ADDR[5][3:0] <= ss_d[3:0];
        13'h1069: BRR_BUF_ADDR[6][3:0] <= ss_d[3:0];
        13'h106a: BRR_BUF_ADDR[7][3:0] <= ss_d[3:0];
        13'h106b: BRR_BUF_ADDR_A[6:0] <= ss_d[6:0];
        13'h106c: BRR_BUF_WE <= ss_d[0:0];
        13'h106d: BRR_BUF_DI[7:0] <= ss_d;
        13'h106e: BRR_BUF_DI[15:8] <= ss_d;
        13'h107d: BD_STATE[1:0] <= ss_d[1:0];
        13'h107e: SR[7:0] <= ss_d;
        13'h107f: SR[15:8] <= ss_d;
        13'h1080: BD_VOICE[2:0] <= ss_d[2:0];
        13'h1081: P0[7:0] <= ss_d;
        13'h1082: P0[15:8] <= ss_d;
        13'h1083: P0[16:16] <= ss_d[0:0];
        default: ;
      endcase
    end else if (!ss_hold || !RST_N) begin
`endif


    if (~RST_N) begin
        BRR_BUF_ADDR <= '{8{4'b0}};
        BRR_BUF_WE <= 0;
        BD_STATE <= BD_IDLE;
    end else begin
        BRR_BUF_WE <= 0;
        if (ENABLE && CE) begin
            // https://snes.nesdev.org/wiki/BRR_samples
            if (BDS.S != BDS_IDLE && BRR_DECODE_EN) begin
                FILTER = TBRRHDR[3:2];
                SCALE = TBRRHDR[7:4];

                case (BDS.S)
                BDS_SMPL0:      // Each sample nibble is a signed 4-bit value in the range of -8 to +7. 
                    S = {{13{TBRRDAT[15]}}, TBRRDAT[14], TBRRDAT[13], TBRRDAT[12]};
                BDS_SMPL1:
                    S = {{13{TBRRDAT[11]}}, TBRRDAT[10], TBRRDAT[9],  TBRRDAT[8]};
                BDS_SMPL2:
                    S = {{13{TBRRDAT[7]}}, TBRRDAT[6], TBRRDAT[5], TBRRDAT[4]};
                BDS_SMPL3:
                    S = {{13{TBRRDAT[3]}}, TBRRDAT[2], TBRRDAT[1], TBRRDAT[0]};
                default: ;
                endcase

                SR = (S << SCALE) >>> 1;
                // if (SCALE <= 12) 
                //     SR = (S << SCALE) >>> 1;
                // else
                //     SR = S & 16'hF800;
                BD_VOICE <= BDS.V;
                BRR_BUF_ADDR_A[6:4] <= BDS.V;
                BRR_BUF_ADDR_A[3:0] <= BRR_BUF_ADDR[BDS.V];
                BD_STATE <= BD_WAIT;
            end
        end

        case (BD_STATE)
        BD_WAIT: begin
            BD_STATE <= BD_P0;
            BRR_BUF_ADDR_PREV = BRR_BUF_ADDR[BD_VOICE];
            if (BRR_BUF_ADDR_PREV == 0)
                BRR_BUF_ADDR_PREV = 11;
            else
                BRR_BUF_ADDR_PREV = BRR_BUF_ADDR_PREV - 1;
            BRR_BUF_ADDR_A[3:0] <= BRR_BUF_ADDR_PREV;
        end
        BD_P0: begin
            BD_STATE <= BD_P1;
            P0 <= 17'(BRR_BUF_DO);
        end
        BD_P1: begin
            // Filter application. This is Tricky.
            // - Easy to cause overflows
            // - Needs lots of () as shifting is lower-precedence than +/-
            P1 = 17'(BRR_BUF_DO) >>> 1;

            case (FILTER)    
            2'b00 : 
                SF = 17'(SR);
            2'b01 : 
                // SR + P0*15/32
                // output += output[now-1] * 15/16
                SF = 17'(SR) + (P0 >>> 1) - (P0 >>> 5);
            2'b10 : 
                // SR + P0*61/64 - P1*15/16
                // output += output[now-1] * 61/32 - output[now-2] * 15/16;
                SF = 17'(SR)  
                    + P0 - (P0 >>> 6) - (P0 >>> 5) 
                    - P1 + (P1 >>> 4);
            default : 
                // SR + P0*115/128 - P1*13/16
                // output += output[now-1] * 115/64 - output[now-2] * 13/16;
                SF = 17'(SR) 
                    + P0 - (P0 >>> 7) - (P0 >>> 5) - (P0 >>> 4)
                    - P1 + (P1 >>> 4) + (P1 >>> 3);
            endcase

            SOUT = CLAMP16(SF) << 1;
            if (BRR_BUF_ADDR[BD_VOICE] == 4'd11)
                BRR_BUF_ADDR_NEXT = 0;
            else
                BRR_BUF_ADDR_NEXT = BRR_BUF_ADDR[BD_VOICE] + 1;
            BRR_BUF_ADDR_A[3:0] <= BRR_BUF_ADDR_NEXT;
            BRR_BUF_DI <= SOUT;                
            BRR_BUF_WE <= 1;
            BRR_BUF_ADDR[BD_VOICE] <= BRR_BUF_ADDR_NEXT;

            // $fdisplay(32'h80000002, "BRR decoded[%d]=%x", BRR_BUF_ADDR_NEXT, SOUT);

            BD_STATE <= BD_IDLE;
        end
        default: ;
        endcase
    end

`ifdef SNES_SAVESTATE
    end
`endif
end

assign BRR_BUF_ADDR_B_NEXT = BRR_BUF_ADDR_B[3:0] == 4'b1011 ? 4'b0 : 
                            (BRR_BUF_ADDR_B[3:0] + 1);

always @(posedge CLK) begin : main_process
    logic signed [15:0] GSUM, OUT_TEMP;
    logic signed [16:0] SUM3;
    logic signed [16:0] VOL_TEMP;
    logic [3:0] BB_POS;
    logic [4:0] BB_POS0;
    logic [15:0] NEW_INTERP_POS;
    logic signed [12:0] ENV_TEMP;
    logic signed [12:0] ENV_TEMP2;
    logic [4:0] ENV_RATE;
    logic [2:0] GAIN_MODE;
    logic [2:0] NEW_KON_CNT;
    logic [4:0] NOISE_RATE;
    logic [14:0] NEW_NOISE;
`ifdef SNES_SAVESTATE
    if (ss_we) begin
      case (ss_a)
        13'h1009: RST_FLG <= ss_d[0:0];
        13'h100a: MUTE_FLG <= ss_d[0:0];
        13'h100b: ECEN_FLG <= ss_d[0:0];
        13'h100c: WKON[7:0] <= ss_d;
        13'h100d: TKON[7:0] <= ss_d;
        13'h100e: TKOFF[7:0] <= ss_d;
        13'h100f: KON_CNT[0][2:0] <= ss_d[2:0];
        13'h1010: KON_CNT[1][2:0] <= ss_d[2:0];
        13'h1011: KON_CNT[2][2:0] <= ss_d[2:0];
        13'h1012: KON_CNT[3][2:0] <= ss_d[2:0];
        13'h1013: KON_CNT[4][2:0] <= ss_d[2:0];
        13'h1014: KON_CNT[5][2:0] <= ss_d[2:0];
        13'h1015: KON_CNT[6][2:0] <= ss_d[2:0];
        13'h1016: KON_CNT[7][2:0] <= ss_d[2:0];
        13'h1017: TSRCN[7:0] <= ss_d;
        13'h1018: TDIR[7:0] <= ss_d;
        13'h1019: TPITCH[7:0] <= ss_d;
        13'h101a: TPITCH[14:8] <= ss_d[6:0];
        13'h101b: TADSR1[7:0] <= ss_d;
        13'h101c: TADSR2[7:0] <= ss_d;
        13'h101d: TNON[7:0] <= ss_d;
        13'h101e: TESA[7:0] <= ss_d;
        13'h101f: TEON[7:0] <= ss_d;
        13'h1020: TPMON[7:0] <= ss_d;
        13'h1021: ENDX[7:0] <= ss_d;
        13'h1022: ENDX_BUF[7:0] <= ss_d;
        13'h1023: OUTX_OUT[7:0] <= ss_d;
        13'h1024: ENVX_OUT[7:0] <= ss_d;
        13'h1025: TENVX[0][7:0] <= ss_d;
        13'h1026: TENVX[1][7:0] <= ss_d;
        13'h1027: TENVX[2][7:0] <= ss_d;
        13'h1028: TENVX[3][7:0] <= ss_d;
        13'h1029: TENVX[4][7:0] <= ss_d;
        13'h102a: TENVX[5][7:0] <= ss_d;
        13'h102b: TENVX[6][7:0] <= ss_d;
        13'h102c: TENVX[7][7:0] <= ss_d;
        13'h102d: EVEN_SAMPLE <= ss_d[0:0];
        13'h102e: BRR_DECODE_EN <= ss_d[0:0];
        13'h102f: TOUT[7:0] <= ss_d;
        13'h1030: TOUT[15:8] <= ss_d;
        13'h1031: NOISE[7:0] <= ss_d;
        13'h1032: NOISE[14:8] <= ss_d[6:0];
        13'h1033: OUTL[7:0] <= ss_d;
        13'h1034: OUTL[15:8] <= ss_d;
        13'h1035: OUTR[7:0] <= ss_d;
        13'h1036: OUTR[15:8] <= ss_d;
        13'h103b: MOUT[0][7:0] <= ss_d;
        13'h103c: MOUT[0][15:8] <= ss_d;
        13'h103d: MOUT[1][7:0] <= ss_d;
        13'h103e: MOUT[1][15:8] <= ss_d;
        13'h103f: EOUT[0][7:0] <= ss_d;
        13'h1040: EOUT[0][15:8] <= ss_d;
        13'h1041: EOUT[1][7:0] <= ss_d;
        13'h1042: EOUT[1][15:8] <= ss_d;
        13'h1043: TDIR_ADDR[7:0] <= ss_d;
        13'h1044: TDIR_ADDR[15:8] <= ss_d;
        13'h1047: BRR_ADDR[0][7:0] <= ss_d;
        13'h1048: BRR_ADDR[0][15:8] <= ss_d;
        13'h1049: BRR_ADDR[1][7:0] <= ss_d;
        13'h104a: BRR_ADDR[1][15:8] <= ss_d;
        13'h104b: BRR_ADDR[2][7:0] <= ss_d;
        13'h104c: BRR_ADDR[2][15:8] <= ss_d;
        13'h104d: BRR_ADDR[3][7:0] <= ss_d;
        13'h104e: BRR_ADDR[3][15:8] <= ss_d;
        13'h104f: BRR_ADDR[4][7:0] <= ss_d;
        13'h1050: BRR_ADDR[4][15:8] <= ss_d;
        13'h1051: BRR_ADDR[5][7:0] <= ss_d;
        13'h1052: BRR_ADDR[5][15:8] <= ss_d;
        13'h1053: BRR_ADDR[6][7:0] <= ss_d;
        13'h1054: BRR_ADDR[6][15:8] <= ss_d;
        13'h1055: BRR_ADDR[7][7:0] <= ss_d;
        13'h1056: BRR_ADDR[7][15:8] <= ss_d;
        13'h1057: BRR_OFFS[0][2:0] <= ss_d[2:0];
        13'h1058: BRR_OFFS[1][2:0] <= ss_d[2:0];
        13'h1059: BRR_OFFS[2][2:0] <= ss_d[2:0];
        13'h105a: BRR_OFFS[3][2:0] <= ss_d[2:0];
        13'h105b: BRR_OFFS[4][2:0] <= ss_d[2:0];
        13'h105c: BRR_OFFS[5][2:0] <= ss_d[2:0];
        13'h105d: BRR_OFFS[6][2:0] <= ss_d[2:0];
        13'h105e: BRR_OFFS[7][2:0] <= ss_d[2:0];
        13'h1062: BRR_END[7:0] <= ss_d;
        13'h1071: BRR_BUF_ADDR_B[6:0] <= ss_d[6:0];
        13'h1074: GS_STATE[2:0] <= ss_d[2:0];
        13'h1075: GTBL_ADDR[7:0] <= ss_d;
        13'h1076: GTBL_ADDR[8:8] <= ss_d[0:0];
        13'h1077: GTBL_DO[7:0] <= ss_d;
        13'h1078: GTBL_DO[11:8] <= ss_d[3:0];
        13'h1079: G_VOICE[2:0] <= ss_d[2:0];
        13'h107a: SUM012[7:0] <= ss_d;
        13'h107b: SUM012[15:8] <= ss_d;
        13'h107c: SUM012[16:16] <= ss_d[0:0];
        13'h1084: ECHO_POS[7:0] <= ss_d;
        13'h1085: ECHO_POS[14:8] <= ss_d[6:0];
        13'h1086: ECHO_ADDR[7:0] <= ss_d;
        13'h1087: ECHO_ADDR[15:8] <= ss_d;
        13'h10a8: ECHO_LEN[7:0] <= ss_d;
        13'h10a9: ECHO_LEN[14:8] <= ss_d[6:0];
        13'h10ab: ECHO_WR_EN <= ss_d[0:0];
        13'h10ac: ECHO_FIR[0][7:0] <= ss_d;
        13'h10ad: ECHO_FIR[0][15:8] <= ss_d;
        13'h10ae: ECHO_FIR[1][7:0] <= ss_d;
        13'h10af: ECHO_FIR[1][15:8] <= ss_d;
        13'h10b0: ECHO_FFC[0][7:0] <= ss_d;
        13'h10b1: ECHO_FFC[1][7:0] <= ss_d;
        13'h10b2: ECHO_FFC[2][7:0] <= ss_d;
        13'h10b3: ECHO_FFC[3][7:0] <= ss_d;
        13'h10b4: ECHO_FFC[4][7:0] <= ss_d;
        13'h10b5: ECHO_FFC[5][7:0] <= ss_d;
        13'h10b6: ECHO_FFC[6][7:0] <= ss_d;
        13'h10b7: ECHO_FFC[7][7:0] <= ss_d;
        13'h10b8: FFC_CNT[2:0] <= ss_d[2:0];
        13'h10b9: ECHO_FIR_TEMP[0][7:0] <= ss_d;
        13'h10ba: ECHO_FIR_TEMP[0][15:8] <= ss_d;
        13'h10bb: ECHO_FIR_TEMP[1][7:0] <= ss_d;
        13'h10bc: ECHO_FIR_TEMP[1][15:8] <= ss_d;
        13'h10bd: ENV_MODE[0][1:0] <= ss_d[1:0];
        13'h10be: ENV_MODE[1][1:0] <= ss_d[1:0];
        13'h10bf: ENV_MODE[2][1:0] <= ss_d[1:0];
        13'h10c0: ENV_MODE[3][1:0] <= ss_d[1:0];
        13'h10c1: ENV_MODE[4][1:0] <= ss_d[1:0];
        13'h10c2: ENV_MODE[5][1:0] <= ss_d[1:0];
        13'h10c3: ENV_MODE[6][1:0] <= ss_d[1:0];
        13'h10c4: ENV_MODE[7][1:0] <= ss_d[1:0];
        13'h10c5: ENV[0][7:0] <= ss_d;
        13'h10c6: ENV[0][11:8] <= ss_d[3:0];
        13'h10c7: ENV[1][7:0] <= ss_d;
        13'h10c8: ENV[1][11:8] <= ss_d[3:0];
        13'h10c9: ENV[2][7:0] <= ss_d;
        13'h10ca: ENV[2][11:8] <= ss_d[3:0];
        13'h10cb: ENV[3][7:0] <= ss_d;
        13'h10cc: ENV[3][11:8] <= ss_d[3:0];
        13'h10cd: ENV[4][7:0] <= ss_d;
        13'h10ce: ENV[4][11:8] <= ss_d[3:0];
        13'h10cf: ENV[5][7:0] <= ss_d;
        13'h10d0: ENV[5][11:8] <= ss_d[3:0];
        13'h10d1: ENV[6][7:0] <= ss_d;
        13'h10d2: ENV[6][11:8] <= ss_d[3:0];
        13'h10d3: ENV[7][7:0] <= ss_d;
        13'h10d4: ENV[7][11:8] <= ss_d[3:0];
        13'h10d5: BENT_INC_MODE[7:0] <= ss_d;
        13'h10d6: INTERP_POS[0][7:0] <= ss_d;
        13'h10d7: INTERP_POS[0][15:8] <= ss_d;
        13'h10d8: INTERP_POS[1][7:0] <= ss_d;
        13'h10d9: INTERP_POS[1][15:8] <= ss_d;
        13'h10da: INTERP_POS[2][7:0] <= ss_d;
        13'h10db: INTERP_POS[2][15:8] <= ss_d;
        13'h10dc: INTERP_POS[3][7:0] <= ss_d;
        13'h10dd: INTERP_POS[3][15:8] <= ss_d;
        13'h10de: INTERP_POS[4][7:0] <= ss_d;
        13'h10df: INTERP_POS[4][15:8] <= ss_d;
        13'h10e0: INTERP_POS[5][7:0] <= ss_d;
        13'h10e1: INTERP_POS[5][15:8] <= ss_d;
        13'h10e2: INTERP_POS[6][7:0] <= ss_d;
        13'h10e3: INTERP_POS[6][15:8] <= ss_d;
        13'h10e4: INTERP_POS[7][7:0] <= ss_d;
        13'h10e5: INTERP_POS[7][15:8] <= ss_d;
        13'h10e6: LAST_ENV[7:0] <= ss_d;
        13'h10e7: LAST_ENV[11:8] <= ss_d[3:0];
        default: ;
      endcase
    end else if (!ss_hold || !RST_N) begin
`endif


    if (~RST_N) begin
        GTBL_ADDR <= 0;
        BRR_ADDR <= '{8{16'b0}};
        BRR_OFFS <= '{8{3'b0}};
        INTERP_POS <= '{8{16'b0}};
        TDIR <= 8'b0;
        TDIR_ADDR <= 16'b0;
        TADSR1 <= 8'b0;
        TADSR2 <= 8'b0;
        TSRCN <= 8'b0;
        TPITCH <= 0;
        ENV <= '{8{12'b0}};
        ENV_MODE <= '{8{EM_RELEASE}};
        BENT_INC_MODE <= 8'b0;
        TOUT <= 16'b0;
        TKON <= 8'b0;
        TKOFF <= 8'b0;
        KON_CNT <= '{8{3'b0}};
        WKON <= 8'b0;
        RST_FLG <= 1'b1;
        MUTE_FLG <= 1'b1;
        ECEN_FLG <= 1'b1;
        EVEN_SAMPLE <= 1'b1;
        OUTL <= 16'b0;
        OUTR <= 16'b0;
        MOUT <= '{2{16'b0}};
        EOUT <= '{2{16'b0}};
        TESA <= 8'b0;
        TNON <= 8'b0;
        NOISE <= {1'b1, 14'b0};
        TEON <= 8'b0;
        ECHO_POS <= 15'b0;
        ECHO_LEN <= 15'b0;
        ECHO_FFC <= '{8{8'b0}};
        ECHO_FIR <= '{2{16'b0}};
        FFC_CNT <= 3'b0;
        ECHO_WR_EN <= 1'b0;
        ENDX <= 8'b0;
        ENDX_BUF <= 8'b0;
        OUTX_OUT <= 8'b0;
        TENVX <= '{8{8'b0}};
        ENVX_OUT <= 0;
        BRR_DECODE_EN <= 1'b0;
        BRR_END <= 0;
        GS_STATE <= GS_IDLE;
    end else begin
        GTBL_DO <= GTBL[GTBL_ADDR];

        if (DBG_DAT_WR && DBG_REG[7] == 1'b0) begin
            if (DBG_REG[6:0] == 7'b1101100) begin          // 6C: FLG
                RST_FLG <= DBG_DAT_IN[7];
                MUTE_FLG <= DBG_DAT_IN[6];
                ECEN_FLG <= DBG_DAT_IN[5];
            end else if (DBG_REG[6:0] == 7'b1001100) begin // 4C: KON
                WKON <= DBG_DAT_IN & ~MUTE_MASK;
            end else if (DBG_REG[6:0] == 7'b1011101) begin // 5D: DIR
                TDIR <= DBG_DAT_IN;
            end else if (DBG_REG[6:0] == 7'b1101101) begin // 6D: ESA
                TESA <= DBG_DAT_IN;
            end
        end else if (CE) begin 
            if (SMP_EN_INT && SMP_A == 16'h00F3 && ~SMP_WE_N) begin
                // $fdisplay(32'h80000002, "SMP reg[%08x] <= %08x", RI, SMP_DO);
                if (RI[6:0] == 7'b1001100) begin            // $4C: KON
                    WKON <= SMP_DO & ~MUTE_MASK;
                    $fdisplay(32'h80000002, "KON = %x", SMP_DO);
                    // if (SMP_DO != 0)
                    //     started <= 1;
                end else if (RI[6:0] == 7'b1101100) begin   // $6C: FLG
                    RST_FLG <= SMP_DO[7];
                    MUTE_FLG <= SMP_DO[6];
                    ECEN_FLG <= SMP_DO[5];
                end else if (RI[6:0] == 7'b1111100) begin   // $7C: ENDX
                    ENDX_BUF <= 8'b0;
                    ENDX <= 0;
                end else if (RI[3:0] == 4'b1000)            // ENVX
                    ENVX_OUT <= 0;
                else if (RI[3:0] == 4'b1001)                // OUTX
                    OUTX_OUT <= 0;
            end

            NEW_KON_CNT = KON_CNT[INS.V] - 1;
            case (INS.S)
            IS_ENV : begin      // STEP 1.2, 4.2, 7.2, 10.2, 13.2, 16.2, 19.2, 30.2
                LAST_ENV <= ENV[INS.V];

                if (KON_CNT[INS.V] != 0) begin
                    if (KON_CNT[INS.V] == 5) begin
                        BRR_ADDR[INS.V] <= BRR_NEXT_ADDR;     // Set new BRR_ADDR
                        BRR_OFFS[INS.V] <= 3'b0;
                    end

                    INTERP_POS[INS.V] <= 16'b0;
                    if (NEW_KON_CNT[1:0] != 2'b0)               // KON_CNT = 4 3 2
                        INTERP_POS[INS.V] <= 16'h4000;

                    ENV[INS.V] <= 0;
                    LAST_ENV <= 0;
                    TPITCH <= 0;
                end else 
                    if (TPMON[INS.V])                       // Set pitch modulation, uses 27x18 multiplier
                        TPITCH <= signed'(TPITCH) + 15'(32'(16'(TOUT >>> 5) * signed'(TPITCH)) >>> 10);

                if (RST_FLG || (TBRRHDR[1:0] == 2'b01 && KON_CNT[INS.V] != 5)) begin
                    ENV_MODE[INS.V] <= EM_RELEASE;
                    ENV[INS.V] <= 0;
                end

                if (EVEN_SAMPLE && TKON[INS.V]) 
                    KON_CNT[INS.V] <= 3'b101;               // Start KON process on even sample
                else if (KON_CNT[INS.V] != 0) 
                    KON_CNT[INS.V] <= NEW_KON_CNT;          // KON_CNT --

                if (EVEN_SAMPLE) begin
                    if (TKON[INS.V]) 
                        ENV_MODE[INS.V] <= EM_ATTACK;       // Start with ATTACK
                    else if (TKOFF[INS.V]) 
                        ENV_MODE[INS.V] <= EM_RELEASE;      // End with RELEASE
                end

                TENVX[INS.V] <= {1'b0, ENV[INS.V][10:4]};
            end

            IS_ENV2 : begin     // STEP 1.3, 4.3, 7.3, 10.3, 13.3, 16.3, 19.3, 30.3
                BB_POS = {1'b0, INTERP_POS[INS.V][14:12]};
                BB_POS0 = {1'b0, BB_POS + BRR_BUF_ADDR[INS.V] + 4'd1};
                if (BB_POS0 > 11)
                    BB_POS0 = BB_POS0 - 12;
                GTBL_ADDR <= {1'b0, ~INTERP_POS[INS.V][11:4]};
                G_VOICE <= INS.V;
                BRR_BUF_ADDR_B[6:4] <= INS.V;
                BRR_BUF_ADDR_B[3:0] <= BB_POS0[3:0];
                GS_STATE <= GS_WAIT;
            end

            default: ;
            endcase

            case (VS.S)        // pipeline to compute output from samples
            VS_ADSR1 : begin
                TADSR1 <= REGS_DO;

                if (VS.V == 0)
                    ECHO_ADDR <= {TESA, 8'h00} + ECHO_POS; 
            end

            VS_PITCHL : 
                TPITCH[7:0] <= REGS_DO;

            VS_PITCHH :  begin
                TPITCH[14:8] <= {1'b0, REGS_DO[5:0]};
                OUTX_OUT <= TOUT[15:8];
            end

            VS_ADSR2 : 
                TADSR2 <= REGS_DO;

            VS_SRCN : begin
                TSRCN <= REGS_DO;
                TDIR_ADDR <= {TDIR, 8'b0} + 16'({TSRCN, 2'b0});
            end

            VS_VOLL : begin
                VOL_TEMP = 17'(24'(TOUT * signed'(REGS_DO)) >>> 7);
                //   VOL_TEMP = 17'(24'(TOUT * REGS_DO) >>> 7);
                MOUT[0] <= CLAMP16(17'(MOUT[0]) + VOL_TEMP);
                if (TEON[VS.V])
                    EOUT[0] <= CLAMP16(17'(EOUT[0]) + VOL_TEMP);

                BRR_END <= 0;
                BRR_DECODE_EN <= 1'b0;
                if (INTERP_POS[VS.V][15:14] != 2'b00) begin     // >= 4000
                    BRR_DECODE_EN <= 1'b1;
                    BRR_OFFS[VS.V] <= BRR_OFFS[VS.V] + 2;
                    if (BRR_OFFS[VS.V] == 6) begin
                        if (TBRRHDR[0]) begin      // end bit ON
                            BRR_ADDR[VS.V] <= BRR_NEXT_ADDR;
                            BRR_END[VS.V] <= 1'b1;
                        end else 
                            BRR_ADDR[VS.V] <= BRR_ADDR[VS.V] + 9;
                    end
                end

                NEW_INTERP_POS = {2'b0, INTERP_POS[VS.V][13:0]} + {1'b0, TPITCH};
                if (~NEW_INTERP_POS[15]) 
                    INTERP_POS[VS.V] <= NEW_INTERP_POS;
                else 
                    INTERP_POS[VS.V] <= 16'h7FFF;
            end

            VS_VOLR : begin
                VOL_TEMP = 17'(24'(TOUT * signed'(REGS_DO)) >>> 7);
                MOUT[1] <= CLAMP16(17'(MOUT[1]) + VOL_TEMP);
                if (TEON[VS.V]) 
                    EOUT[1] <= CLAMP16(17'(EOUT[1]) + VOL_TEMP);

                ENDX_BUF <= ENDX | BRR_END;
                if (KON_CNT[VS.V] == 5) 
                    ENDX_BUF[VS.V] <= 1'b0;
            end

            VS_MVOLL : 
                MOUT[0] <= shortint'(24'(MOUT[0] * signed'(REGS_DO)) >>> 7);

            VS_MVOLR : 
                MOUT[1] <= shortint'(24'(MOUT[1] * signed'(REGS_DO)) >>> 7);

            VS_EVOLL : begin
                if (MUTE_FLG) 
                    OUTL <= 16'b0;
                else    // VOL_OUT
                    OUTL <= CLAMP16(17'(MOUT[0]) + 
                                17'(24'(ECHO_FIR[0] * signed'(REGS_DO)) >>> 7) );
                MOUT[0] <= 16'b0;
            end

            VS_EVOLR : begin
                if (MUTE_FLG) 
                    OUTR <= 16'b0;
                else    // VOL_OUT
                    OUTR <= CLAMP16( 17'(MOUT[1]) + 
                                17'(24'(ECHO_FIR[1] * signed'(REGS_DO)) >>> 7) );
                MOUT[1] <= 16'b0;
                ECHO_FIR[0] <= 16'b0;
                ECHO_FIR_TEMP[0] <= 0;
                ECHO_FIR[1] <= 16'b0;
                ECHO_FIR_TEMP[1] <= 0;
            end

            VS_DIR : 
                TDIR <= REGS_DO;

            VS_KON : 
                if (EVEN_SAMPLE) 
                    WKON <= WKON & ~TKON;

            VS_KOFF : 
                if (EVEN_SAMPLE) begin
                    TKON <= WKON;
                    TKOFF <= REGS_DO | DBG_VMUTE;
                end

            VS_PMON : 
                TPMON <= {REGS_DO[7:1], 1'b0};

            VS_NON : 
                TNON <= REGS_DO;

            VS_FLG : begin
                NOISE_RATE = REGS_DO[4:0];
                NEW_NOISE = {NOISE[0] ^ NOISE[1], 14'b0} | {1'b0, NOISE[14:1]};
                if (GCOUNT_TRIGGER(NOISE_RATE)) 
                    NOISE <= NEW_NOISE;

                EOUT[0] <= 16'b0;
                EOUT[1] <= 16'b0;
            end

            VS_EON : begin
                TEON <= REGS_DO;
                ECHO_WR_EN <= ~ECEN_FLG;
            end

            VS_EDL : 
                if (ECHO_POS == 0) begin
                    ECHO_LEN <= {REGS_DO[3:0], 11'b0};
                end

            VS_ESA : begin
                TESA <= REGS_DO;
                EVEN_SAMPLE <=  ~EVEN_SAMPLE;

                if (ECHO_POS + 4 >= ECHO_LEN)
                    ECHO_POS <= 0;
                else
                    ECHO_POS <= ECHO_POS + 4;
                ECHO_WR_EN <= ~ECEN_FLG;
            end

            VS_FIR0, VS_FIR1, VS_FIR2, VS_FIR3,
            VS_FIR4, VS_FIR5, VS_FIR6, VS_FIR7 : 
                ECHO_FFC[VS.V] <= REGS_DO;  

            VS_EFB : begin
                EOUT[0] <= CLAMP16(17'(EOUT[0]) + 17'(24'(ECHO_FIR[0] * signed'(REGS_DO)) >>> 7)) & 16'hFFFE;
                EOUT[1] <= CLAMP16(17'(EOUT[1]) + 17'(24'(ECHO_FIR[1] * signed'(REGS_DO)) >>> 7)) & 16'hFFFE;
            end

            VS_ENVX : ;

            VS_OUTX : begin
                ENDX <= ENDX_BUF;
                ENVX_OUT <= TENVX[VS.V];
            end

            VS_ECHO : ;

            default : ;
            endcase

            if (STEP == 24 || STEP == 25) begin
                ECHO_FIR_TEMP[0] <= ECHO_FIR_TEMP[0] + 
                        16'(23'(signed'(ECHO_BUF[0][FFC_CNT]) * ECHO_FFC[FFC_CNT]) >>> 6); // and x"FFFE"
                ECHO_FIR_TEMP[1] <= ECHO_FIR_TEMP[1] + 
                        16'(23'(signed'(ECHO_BUF[1][FFC_CNT]) * ECHO_FFC[FFC_CNT]) >>> 6); // and x"FFFE"
                if (FFC_CNT == 7) begin
                    ECHO_FIR[0] <= CLAMP16(17'(ECHO_FIR_TEMP[0]) + 17'(23'(signed'(ECHO_BUF[0][FFC_CNT]) * ECHO_FFC[FFC_CNT]) >>> 6)) & 16'hFFFE;
                    ECHO_FIR[1] <= CLAMP16(17'(ECHO_FIR_TEMP[1]) + 17'(23'(signed'(ECHO_BUF[1][FFC_CNT]) * ECHO_FFC[FFC_CNT]) >>> 6)) & 16'hFFFE;
                end
                FFC_CNT <= FFC_CNT + 1;
            end
        end // if (CE)

        case (GS_STATE)
        GS_WAIT: begin
            GS_STATE <= GS_BRR0;
            BRR_BUF_ADDR_B[3:0] <= BRR_BUF_ADDR_B_NEXT;
            GTBL_ADDR[8] <= 1;
        end

        GS_BRR0: begin
            SUM012 <= 17'(28'(GTBL_DO * BRR_BUF_GAUSS_DO) >> 11);
            BRR_BUF_ADDR_B[3:0] <= BRR_BUF_ADDR_B_NEXT;
            GTBL_ADDR[7:0] <= ~GTBL_ADDR[7:0];
            GS_STATE <= GS_BRR1;
        end

        GS_BRR1: begin
            SUM012 <= SUM012 + 17'(28'(GTBL_DO * BRR_BUF_GAUSS_DO) >> 11);
            BRR_BUF_ADDR_B[3:0] <= BRR_BUF_ADDR_B_NEXT;
            GTBL_ADDR[8] <= 0;
            GS_STATE <= GS_BRR2;
        end 

        GS_BRR2: begin
            SUM012 <= SUM012 + 17'(28'(GTBL_DO * BRR_BUF_GAUSS_DO) >> 11);
            GS_STATE <= GS_BRR3;
        end

        GS_BRR3: begin
            SUM3 = 17'(28'(GTBL_DO * BRR_BUF_GAUSS_DO) >> 11);

            GSUM = CLAMP16(SUM012 + SUM3);          
            // nand2mario: the upstream code is probably wrong...  SUM012 is 17 bits
            // GSUM := CLAMP16( resize(SUM012(15)&SUM012(15 downto 0) + SUM3, 17) );
            // GSUM = CLAMP16(17'({SUM012[15],SUM012[15:0]} + SUM3));

            if (~TNON[G_VOICE]) 
                OUT_TEMP = GSUM & 16'hFFFE;
            else 
                OUT_TEMP = {NOISE, 1'b0};

            // env apply
            TOUT <= 16'(28'(OUT_TEMP * LAST_ENV) >>> 11) & 16'hFFFE;

            // envelope
            if (KON_CNT[G_VOICE] == 0) begin
                if (ENV_MODE[G_VOICE] == EM_RELEASE) begin
                    ENV_TEMP2 = 13'(ENV[G_VOICE]) - 8;
                    if (ENV_TEMP2 < 0) begin
                        ENV_TEMP2 = 0;
                    end
                    ENV[G_VOICE] <= 12'(ENV_TEMP2);
                    ENV_RATE = 5'b11111;
                end else begin
                    if (TADSR1[7]) begin
                        if (ENV_MODE[G_VOICE] == EM_DECAY || ENV_MODE[G_VOICE] == EM_SUSTAIN) begin
                            ENV_TEMP = 13'(ENV[G_VOICE]) - ((ENV[G_VOICE] - 1) >>> 8) - 1;
                            if (ENV_MODE[G_VOICE] == EM_DECAY) 
                                ENV_RATE = {1'b1, TADSR1[6:4], 1'b0};
                            else 
                                ENV_RATE = TADSR2[4:0];
                        end else begin
                            ENV_RATE = {TADSR1[3:0], 1'b1};
                            if (ENV_RATE != 31) 
                                ENV_TEMP = 13'(ENV[G_VOICE]) + 13'h020;
                            else 
                                ENV_TEMP = 13'(ENV[G_VOICE]) + 13'h400;
                        end
                    end else begin
                        GAIN_MODE = TADSR2[7:5];
                        if (~GAIN_MODE[2]) begin
                            ENV_TEMP = 13'({TADSR2[6:0], 4'b0000});
                            ENV_RATE = 5'b11111;
                        end else begin
                            ENV_RATE = TADSR2[4:0];
                            if (GAIN_MODE[1:0] == 2'b00) 
                                ENV_TEMP = 13'(ENV[G_VOICE]) - 13'h020;
                            else if (GAIN_MODE[1:0] == 2'b01) 
                                ENV_TEMP = 13'(ENV[G_VOICE]) - ((ENV[G_VOICE] - 1) >>> 8) - 1;
                            else if (GAIN_MODE[1:0] == 2'b10) 
                                ENV_TEMP = 13'(ENV[G_VOICE]) + 13'h020;
                            else begin
                                if (BENT_INC_MODE[G_VOICE] == 1'b0) 
                                    ENV_TEMP = 13'(ENV[G_VOICE]) + 13'h020;
                                else 
                                    ENV_TEMP = 13'(ENV[G_VOICE]) + 13'h008;
                            end
                        end
                    end
                    
                    if (unsigned'(ENV_TEMP[10:0]) >= 11'h600 || ENV_TEMP[12:11] != 2'b00)  
                        BENT_INC_MODE[G_VOICE] <= 1;
                    else 
                        BENT_INC_MODE[G_VOICE] <= 0;
                    
                    if (ENV_TEMP[10:8] == TADSR2[7:5] && ENV_MODE[G_VOICE] == EM_DECAY) 
                        ENV_MODE[G_VOICE] <= EM_SUSTAIN;

                    if (ENV_TEMP[12:11] != 2'b00) begin
                        if (ENV_TEMP < 0) 
                            ENV_TEMP2 = 13'b0;
                        else 
                            ENV_TEMP2 = 13'b0_0111_1111_1111;
                        if (ENV_MODE[G_VOICE] == EM_ATTACK) 
                            ENV_MODE[G_VOICE] <= EM_DECAY;
                    end else 
                        ENV_TEMP2 = ENV_TEMP;

                    if (GCOUNT_TRIGGER(ENV_RATE)) 
                        ENV[G_VOICE] <= 12'(ENV_TEMP2);
                end
            end else begin
                ENV[G_VOICE] <= 12'b0;            
                BENT_INC_MODE[G_VOICE] <= 0;
            end // if (KON...)
            GS_STATE <= GS_IDLE;
        end 

        default: ;
        endcase
    end

`ifdef SNES_SAVESTATE
    end
`endif
end

always @(posedge CLK) begin : gcount
`ifdef SNES_SAVESTATE
    if (ss_we) begin
      case (ss_a)
        13'h10e8: GCNT_BY1[7:0] <= ss_d;
        13'h10e9: GCNT_BY1[11:8] <= ss_d[3:0];
        13'h10ea: GCNT_BY3[7:0] <= ss_d;
        13'h10eb: GCNT_BY3[11:8] <= ss_d[3:0];
        13'h10ec: GCNT_BY5[7:0] <= ss_d;
        13'h10ed: GCNT_BY5[11:8] <= ss_d[3:0];
        default: ;
      endcase
    end else if (!ss_hold || !RST_N) begin
`endif

    if (~RST_N) begin
        GCNT_BY1 <= 12'b0;
        GCNT_BY3 <= 12'h410;
        GCNT_BY5 <= 12'h218;
    end else if (ENABLE && CE) begin
        if (STEP == 30 && SUBSTEP == 1) begin
            if (GCNT_BY3[1:0] == 2'b00) 
                GCNT_BY3[1:0] <= 2'b10;
            else 
                GCNT_BY3 <= GCNT_BY3 + 1;

            if (GCNT_BY5[2:0] == 3'b000) 
                GCNT_BY5[2:0] <= 3'b100;
            else 
                GCNT_BY5 <= GCNT_BY5 + 1;

            GCNT_BY1 <= GCNT_BY1 + 1;
        end
    end

`ifdef SNES_SAVESTATE
    end
`endif
end

always @(posedge CLK) begin : output2audio
`ifdef SNES_SAVESTATE
    if (ss_we) begin
      case (ss_a)
        13'h1000: AUDIO_L[7:0] <= ss_d;
        13'h1001: AUDIO_L[15:8] <= ss_d;
        13'h1002: AUDIO_R[7:0] <= ss_d;
        13'h1003: AUDIO_R[15:8] <= ss_d;
        13'h1004: SND_RDY <= ss_d[0:0];
        13'h1037: OUTPUT[7:0] <= ss_d;
        13'h1038: OUTPUT[15:8] <= ss_d;
        13'h1039: OUTPUT[23:16] <= ss_d;
        13'h103a: OUTPUT[31:24] <= ss_d;
        default: ;
      endcase
    end else if (!ss_hold || !RST_N) begin
`endif

    if (~RST_N) begin
        OUTPUT <= 32'b0;
        SND_RDY <= 1'b0;
        AUDIO_L <= 16'b0;
        AUDIO_R <= 16'b0;
    end else begin
        SND_RDY <= 1'b0;        // ensure pulse
        if (ENABLE && CE) begin
            if (SUBSTEP == 3) begin
                OUTPUT <= {OUTPUT[30:0], 1'b0};
                if (STEP == 31) begin
                    OUTPUT <= {OUTL, OUTR};
                    AUDIO_L <= OUTL;
                    AUDIO_R <= OUTR;
                    SND_RDY <= 1'b1;
                end
            end
        end        
    end

`ifdef SNES_SAVESTATE
    end
`endif
end

/*
assign LRCK =  ~STEP_CNT[4];
assign BCK = SUBSTEP_CNT[1];
assign SDAT = OUTPUT[31];
*/


`ifdef SNES_SAVESTATE

`ifdef SNES_SAVESTATE
`endif
// Register image; RAM and pipeline state are read only while frozen.
always @* begin
    ss_q = 8'b0;
    case (ss_a)
    13'h1000: ss_q = AUDIO_L[7:0];
    13'h1001: ss_q = AUDIO_L[15:8];
    13'h1002: ss_q = AUDIO_R[7:0];
    13'h1003: ss_q = AUDIO_R[15:8];
    13'h1004: ss_q = {7'b0, SND_RDY};
    13'h1005: ss_q = RI[7:0];
    13'h1006: ss_q = REGS_DO[7:0];
    13'h1007: ss_q = {3'b0, STEP_CNT[4:0]};
    13'h1008: ss_q = {6'b0, SUBSTEP_CNT[1:0]};
    13'h1009: ss_q = {7'b0, RST_FLG};
    13'h100a: ss_q = {7'b0, MUTE_FLG};
    13'h100b: ss_q = {7'b0, ECEN_FLG};
    13'h100c: ss_q = WKON[7:0];
    13'h100d: ss_q = TKON[7:0];
    13'h100e: ss_q = TKOFF[7:0];
    13'h100f: ss_q = {5'b0, KON_CNT[0][2:0]};
    13'h1010: ss_q = {5'b0, KON_CNT[1][2:0]};
    13'h1011: ss_q = {5'b0, KON_CNT[2][2:0]};
    13'h1012: ss_q = {5'b0, KON_CNT[3][2:0]};
    13'h1013: ss_q = {5'b0, KON_CNT[4][2:0]};
    13'h1014: ss_q = {5'b0, KON_CNT[5][2:0]};
    13'h1015: ss_q = {5'b0, KON_CNT[6][2:0]};
    13'h1016: ss_q = {5'b0, KON_CNT[7][2:0]};
    13'h1017: ss_q = TSRCN[7:0];
    13'h1018: ss_q = TDIR[7:0];
    13'h1019: ss_q = TPITCH[7:0];
    13'h101a: ss_q = {1'b0, TPITCH[14:8]};
    13'h101b: ss_q = TADSR1[7:0];
    13'h101c: ss_q = TADSR2[7:0];
    13'h101d: ss_q = TNON[7:0];
    13'h101e: ss_q = TESA[7:0];
    13'h101f: ss_q = TEON[7:0];
    13'h1020: ss_q = TPMON[7:0];
    13'h1021: ss_q = ENDX[7:0];
    13'h1022: ss_q = ENDX_BUF[7:0];
    13'h1023: ss_q = OUTX_OUT[7:0];
    13'h1024: ss_q = ENVX_OUT[7:0];
    13'h1025: ss_q = TENVX[0][7:0];
    13'h1026: ss_q = TENVX[1][7:0];
    13'h1027: ss_q = TENVX[2][7:0];
    13'h1028: ss_q = TENVX[3][7:0];
    13'h1029: ss_q = TENVX[4][7:0];
    13'h102a: ss_q = TENVX[5][7:0];
    13'h102b: ss_q = TENVX[6][7:0];
    13'h102c: ss_q = TENVX[7][7:0];
    13'h102d: ss_q = {7'b0, EVEN_SAMPLE};
    13'h102e: ss_q = {7'b0, BRR_DECODE_EN};
    13'h102f: ss_q = TOUT[7:0];
    13'h1030: ss_q = TOUT[15:8];
    13'h1031: ss_q = NOISE[7:0];
    13'h1032: ss_q = {1'b0, NOISE[14:8]};
    13'h1033: ss_q = OUTL[7:0];
    13'h1034: ss_q = OUTL[15:8];
    13'h1035: ss_q = OUTR[7:0];
    13'h1036: ss_q = OUTR[15:8];
    13'h1037: ss_q = OUTPUT[7:0];
    13'h1038: ss_q = OUTPUT[15:8];
    13'h1039: ss_q = OUTPUT[23:16];
    13'h103a: ss_q = OUTPUT[31:24];
    13'h103b: ss_q = MOUT[0][7:0];
    13'h103c: ss_q = MOUT[0][15:8];
    13'h103d: ss_q = MOUT[1][7:0];
    13'h103e: ss_q = MOUT[1][15:8];
    13'h103f: ss_q = EOUT[0][7:0];
    13'h1040: ss_q = EOUT[0][15:8];
    13'h1041: ss_q = EOUT[1][7:0];
    13'h1042: ss_q = EOUT[1][15:8];
    13'h1043: ss_q = TDIR_ADDR[7:0];
    13'h1044: ss_q = TDIR_ADDR[15:8];
    13'h1045: ss_q = BRR_NEXT_ADDR[7:0];
    13'h1046: ss_q = BRR_NEXT_ADDR[15:8];
    13'h1047: ss_q = BRR_ADDR[0][7:0];
    13'h1048: ss_q = BRR_ADDR[0][15:8];
    13'h1049: ss_q = BRR_ADDR[1][7:0];
    13'h104a: ss_q = BRR_ADDR[1][15:8];
    13'h104b: ss_q = BRR_ADDR[2][7:0];
    13'h104c: ss_q = BRR_ADDR[2][15:8];
    13'h104d: ss_q = BRR_ADDR[3][7:0];
    13'h104e: ss_q = BRR_ADDR[3][15:8];
    13'h104f: ss_q = BRR_ADDR[4][7:0];
    13'h1050: ss_q = BRR_ADDR[4][15:8];
    13'h1051: ss_q = BRR_ADDR[5][7:0];
    13'h1052: ss_q = BRR_ADDR[5][15:8];
    13'h1053: ss_q = BRR_ADDR[6][7:0];
    13'h1054: ss_q = BRR_ADDR[6][15:8];
    13'h1055: ss_q = BRR_ADDR[7][7:0];
    13'h1056: ss_q = BRR_ADDR[7][15:8];
    13'h1057: ss_q = {5'b0, BRR_OFFS[0][2:0]};
    13'h1058: ss_q = {5'b0, BRR_OFFS[1][2:0]};
    13'h1059: ss_q = {5'b0, BRR_OFFS[2][2:0]};
    13'h105a: ss_q = {5'b0, BRR_OFFS[3][2:0]};
    13'h105b: ss_q = {5'b0, BRR_OFFS[4][2:0]};
    13'h105c: ss_q = {5'b0, BRR_OFFS[5][2:0]};
    13'h105d: ss_q = {5'b0, BRR_OFFS[6][2:0]};
    13'h105e: ss_q = {5'b0, BRR_OFFS[7][2:0]};
    13'h105f: ss_q = TBRRDAT[7:0];
    13'h1060: ss_q = TBRRDAT[15:8];
    13'h1061: ss_q = TBRRHDR[7:0];
    13'h1062: ss_q = BRR_END[7:0];
    13'h1063: ss_q = {4'b0, BRR_BUF_ADDR[0][3:0]};
    13'h1064: ss_q = {4'b0, BRR_BUF_ADDR[1][3:0]};
    13'h1065: ss_q = {4'b0, BRR_BUF_ADDR[2][3:0]};
    13'h1066: ss_q = {4'b0, BRR_BUF_ADDR[3][3:0]};
    13'h1067: ss_q = {4'b0, BRR_BUF_ADDR[4][3:0]};
    13'h1068: ss_q = {4'b0, BRR_BUF_ADDR[5][3:0]};
    13'h1069: ss_q = {4'b0, BRR_BUF_ADDR[6][3:0]};
    13'h106a: ss_q = {4'b0, BRR_BUF_ADDR[7][3:0]};
    13'h106b: ss_q = {1'b0, BRR_BUF_ADDR_A[6:0]};
    13'h106c: ss_q = {7'b0, BRR_BUF_WE};
    13'h106d: ss_q = BRR_BUF_DI[7:0];
    13'h106e: ss_q = BRR_BUF_DI[15:8];
    13'h106f: ss_q = BRR_BUF_DO[7:0];
    13'h1070: ss_q = BRR_BUF_DO[15:8];
    13'h1071: ss_q = {1'b0, BRR_BUF_ADDR_B[6:0]};
    13'h1072: ss_q = BRR_BUF_GAUSS_DO[7:0];
    13'h1073: ss_q = BRR_BUF_GAUSS_DO[15:8];
    13'h1074: ss_q = {5'b0, GS_STATE[2:0]};
    13'h1075: ss_q = GTBL_ADDR[7:0];
    13'h1076: ss_q = {7'b0, GTBL_ADDR[8:8]};
    13'h1077: ss_q = GTBL_DO[7:0];
    13'h1078: ss_q = {4'b0, GTBL_DO[11:8]};
    13'h1079: ss_q = {5'b0, G_VOICE[2:0]};
    13'h107a: ss_q = SUM012[7:0];
    13'h107b: ss_q = SUM012[15:8];
    13'h107c: ss_q = {7'b0, SUM012[16:16]};
    13'h107d: ss_q = {6'b0, BD_STATE[1:0]};
    13'h107e: ss_q = SR[7:0];
    13'h107f: ss_q = SR[15:8];
    13'h1080: ss_q = {5'b0, BD_VOICE[2:0]};
    13'h1081: ss_q = P0[7:0];
    13'h1082: ss_q = P0[15:8];
    13'h1083: ss_q = {7'b0, P0[16:16]};
    13'h1084: ss_q = ECHO_POS[7:0];
    13'h1085: ss_q = {1'b0, ECHO_POS[14:8]};
    13'h1086: ss_q = ECHO_ADDR[7:0];
    13'h1087: ss_q = ECHO_ADDR[15:8];
    13'h1088: ss_q = ECHO_BUF[0][0][7:0];
    13'h1089: ss_q = {1'b0, ECHO_BUF[0][0][14:8]};
    13'h108a: ss_q = ECHO_BUF[0][1][7:0];
    13'h108b: ss_q = {1'b0, ECHO_BUF[0][1][14:8]};
    13'h108c: ss_q = ECHO_BUF[0][2][7:0];
    13'h108d: ss_q = {1'b0, ECHO_BUF[0][2][14:8]};
    13'h108e: ss_q = ECHO_BUF[0][3][7:0];
    13'h108f: ss_q = {1'b0, ECHO_BUF[0][3][14:8]};
    13'h1090: ss_q = ECHO_BUF[0][4][7:0];
    13'h1091: ss_q = {1'b0, ECHO_BUF[0][4][14:8]};
    13'h1092: ss_q = ECHO_BUF[0][5][7:0];
    13'h1093: ss_q = {1'b0, ECHO_BUF[0][5][14:8]};
    13'h1094: ss_q = ECHO_BUF[0][6][7:0];
    13'h1095: ss_q = {1'b0, ECHO_BUF[0][6][14:8]};
    13'h1096: ss_q = ECHO_BUF[0][7][7:0];
    13'h1097: ss_q = {1'b0, ECHO_BUF[0][7][14:8]};
    13'h1098: ss_q = ECHO_BUF[1][0][7:0];
    13'h1099: ss_q = {1'b0, ECHO_BUF[1][0][14:8]};
    13'h109a: ss_q = ECHO_BUF[1][1][7:0];
    13'h109b: ss_q = {1'b0, ECHO_BUF[1][1][14:8]};
    13'h109c: ss_q = ECHO_BUF[1][2][7:0];
    13'h109d: ss_q = {1'b0, ECHO_BUF[1][2][14:8]};
    13'h109e: ss_q = ECHO_BUF[1][3][7:0];
    13'h109f: ss_q = {1'b0, ECHO_BUF[1][3][14:8]};
    13'h10a0: ss_q = ECHO_BUF[1][4][7:0];
    13'h10a1: ss_q = {1'b0, ECHO_BUF[1][4][14:8]};
    13'h10a2: ss_q = ECHO_BUF[1][5][7:0];
    13'h10a3: ss_q = {1'b0, ECHO_BUF[1][5][14:8]};
    13'h10a4: ss_q = ECHO_BUF[1][6][7:0];
    13'h10a5: ss_q = {1'b0, ECHO_BUF[1][6][14:8]};
    13'h10a6: ss_q = ECHO_BUF[1][7][7:0];
    13'h10a7: ss_q = {1'b0, ECHO_BUF[1][7][14:8]};
    13'h10a8: ss_q = ECHO_LEN[7:0];
    13'h10a9: ss_q = {1'b0, ECHO_LEN[14:8]};
    13'h10aa: ss_q = {1'b0, ECHO_DATA_TEMP[6:0]};
    13'h10ab: ss_q = {7'b0, ECHO_WR_EN};
    13'h10ac: ss_q = ECHO_FIR[0][7:0];
    13'h10ad: ss_q = ECHO_FIR[0][15:8];
    13'h10ae: ss_q = ECHO_FIR[1][7:0];
    13'h10af: ss_q = ECHO_FIR[1][15:8];
    13'h10b0: ss_q = ECHO_FFC[0][7:0];
    13'h10b1: ss_q = ECHO_FFC[1][7:0];
    13'h10b2: ss_q = ECHO_FFC[2][7:0];
    13'h10b3: ss_q = ECHO_FFC[3][7:0];
    13'h10b4: ss_q = ECHO_FFC[4][7:0];
    13'h10b5: ss_q = ECHO_FFC[5][7:0];
    13'h10b6: ss_q = ECHO_FFC[6][7:0];
    13'h10b7: ss_q = ECHO_FFC[7][7:0];
    13'h10b8: ss_q = {5'b0, FFC_CNT[2:0]};
    13'h10b9: ss_q = ECHO_FIR_TEMP[0][7:0];
    13'h10ba: ss_q = ECHO_FIR_TEMP[0][15:8];
    13'h10bb: ss_q = ECHO_FIR_TEMP[1][7:0];
    13'h10bc: ss_q = ECHO_FIR_TEMP[1][15:8];
    13'h10bd: ss_q = {6'b0, ENV_MODE[0][1:0]};
    13'h10be: ss_q = {6'b0, ENV_MODE[1][1:0]};
    13'h10bf: ss_q = {6'b0, ENV_MODE[2][1:0]};
    13'h10c0: ss_q = {6'b0, ENV_MODE[3][1:0]};
    13'h10c1: ss_q = {6'b0, ENV_MODE[4][1:0]};
    13'h10c2: ss_q = {6'b0, ENV_MODE[5][1:0]};
    13'h10c3: ss_q = {6'b0, ENV_MODE[6][1:0]};
    13'h10c4: ss_q = {6'b0, ENV_MODE[7][1:0]};
    13'h10c5: ss_q = ENV[0][7:0];
    13'h10c6: ss_q = {4'b0, ENV[0][11:8]};
    13'h10c7: ss_q = ENV[1][7:0];
    13'h10c8: ss_q = {4'b0, ENV[1][11:8]};
    13'h10c9: ss_q = ENV[2][7:0];
    13'h10ca: ss_q = {4'b0, ENV[2][11:8]};
    13'h10cb: ss_q = ENV[3][7:0];
    13'h10cc: ss_q = {4'b0, ENV[3][11:8]};
    13'h10cd: ss_q = ENV[4][7:0];
    13'h10ce: ss_q = {4'b0, ENV[4][11:8]};
    13'h10cf: ss_q = ENV[5][7:0];
    13'h10d0: ss_q = {4'b0, ENV[5][11:8]};
    13'h10d1: ss_q = ENV[6][7:0];
    13'h10d2: ss_q = {4'b0, ENV[6][11:8]};
    13'h10d3: ss_q = ENV[7][7:0];
    13'h10d4: ss_q = {4'b0, ENV[7][11:8]};
    13'h10d5: ss_q = BENT_INC_MODE[7:0];
    13'h10d6: ss_q = INTERP_POS[0][7:0];
    13'h10d7: ss_q = INTERP_POS[0][15:8];
    13'h10d8: ss_q = INTERP_POS[1][7:0];
    13'h10d9: ss_q = INTERP_POS[1][15:8];
    13'h10da: ss_q = INTERP_POS[2][7:0];
    13'h10db: ss_q = INTERP_POS[2][15:8];
    13'h10dc: ss_q = INTERP_POS[3][7:0];
    13'h10dd: ss_q = INTERP_POS[3][15:8];
    13'h10de: ss_q = INTERP_POS[4][7:0];
    13'h10df: ss_q = INTERP_POS[4][15:8];
    13'h10e0: ss_q = INTERP_POS[5][7:0];
    13'h10e1: ss_q = INTERP_POS[5][15:8];
    13'h10e2: ss_q = INTERP_POS[6][7:0];
    13'h10e3: ss_q = INTERP_POS[6][15:8];
    13'h10e4: ss_q = INTERP_POS[7][7:0];
    13'h10e5: ss_q = INTERP_POS[7][15:8];
    13'h10e6: ss_q = LAST_ENV[7:0];
    13'h10e7: ss_q = {4'b0, LAST_ENV[11:8]};
    13'h10e8: ss_q = GCNT_BY1[7:0];
    13'h10e9: ss_q = {4'b0, GCNT_BY1[11:8]};
    13'h10ea: ss_q = GCNT_BY3[7:0];
    13'h10eb: ss_q = {4'b0, GCNT_BY3[11:8]};
    13'h10ec: ss_q = GCNT_BY5[7:0];
    13'h10ed: ss_q = {4'b0, GCNT_BY5[11:8]};
    13'h116e: ss_q = SMP_DO_buf[7:0];
    13'h116f: ss_q = SMP_A_buf[7:0];
    13'h1170: ss_q = SMP_A_buf[15:8];
    13'h1171: ss_q = {7'b0, SMP_WE_N_buf};
    default: ;
    endcase
    ss_q = ss_q | ss_q_ce;
    if (ss_regram_sel) ss_q = regram_raw;
    if (ss_brr_sel) ss_q = ss_brr_offset[0] ? brr_raw_a[15:8] : brr_raw_a[7:0];
end
`endif
endmodule
