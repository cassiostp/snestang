// tb_spc700_shift.cpp -- SPC700 shift/rotate regression bench (Verilator).
//
// Runs src/spc700's SPC700 core alone against a C++ async RAM and checks
// every ASL/ROL/LSR/ROR form (dp, !abs, dp+X, A): result byte, A and the
// C/Z/N flags. Each case poisons the core's T scratch register with
// `mov $20,#$3C` first, so a shift whose microcode feeds the ALU from T
// instead of the addressed memory byte cannot pass by accident.
//
// Regression history: LSR !a (0x4C) -- and ROL !a (0x2C) / ROR !a (0x6C)
// -- carried busCtrl=5'b10000 in their ALU microinstruction, which routes
// DB (the ALU's shift operand R) to T instead of D_IN, so e.g.
// `lsr $03c1` shifted stale T (typically 0x00) and wrote that back. In
// Zelda 3's SPC driver that killed the SFX channel-search bitmask in
// Port2/Port3_AllocateChan after its first shift, so SFX needing any
// channel other than voice 7 at bit 0x80 silently never played.
//
// Exit code 0 on success, 1 on any failure.
#include "VSPC700.h"
#include "VSPC700___024root.h"

#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>

static VSPC700* dut;
static uint8_t ram[65536];

// Internal probes via the Verilator root struct (same convention as
// sim/dsp_rain; a rename fails loudly at compile time).
#define REG_PSW (dut->rootp->SPC700__DOT__PSW)
#define REG_A (dut->rootp->SPC700__DOT__A)

// One SPC bus cycle: present D_IN for the settled A_OUT, capture a write
// from the pre-edge A_OUT/D_OUT/WE_N, then take the clock edge.
static void cycle() {
    dut->CLK = 0;
    dut->D_IN = ram[dut->A_OUT & 0xffff];
    dut->eval();
    uint16_t a = dut->A_OUT;
    uint8_t d = dut->D_OUT;
    bool we = !dut->WE_N;
    dut->CLK = 1;
    dut->eval();
    if (we)
        ram[a] = d;
}

static void reset() {
    dut->RST_N = 0;
    dut->RDY = 1;
    dut->IRQ_N = 1;
    dut->DBG_REG = 0;
    dut->DBG_DAT_IN = 0;
    dut->DBG_DAT_WR = 0;
    for (int i = 0; i < 8; i++) cycle();
    dut->RST_N = 1;
}

struct Asm {
    std::vector<uint8_t> b;
    Asm& op(uint8_t v) { b.push_back(v); return *this; }
    Asm& w16(uint16_t v) { b.push_back(v & 0xff); b.push_back(v >> 8); return *this; }
};

enum Form { F_DP, F_ABS, F_DPX, F_A };
static const char* form_name[] = {"dp", "!abs", "dp+X", "A"};
static const char* op_name[] = {"ASL", "ROL", "LSR", "ROR"};

// Shift opcode by [op][form]: op 0=ASL 1=ROL 2=LSR 3=ROR.
static const uint8_t shift_op[4][4] = {
    {0x0B, 0x0C, 0x1B, 0x1C},
    {0x2B, 0x2C, 0x3B, 0x3C},
    {0x4B, 0x4C, 0x5B, 0x5C},
    {0x6B, 0x6C, 0x7B, 0x7C},
};

static const uint16_t PROG = 0x0400;
static const uint16_t ABS_TGT = 0x1234;
static const uint8_t DP_TGT = 0x10;   // dp+X uses X=4 -> $0014

static int shift_expect(int op, uint8_t v, int cin, uint8_t& res) {
    int cout = 0;
    switch (op) {
    case 0: res = (uint8_t)(v << 1);               cout = (v >> 7) & 1; break;
    case 1: res = (uint8_t)((v << 1) | cin);       cout = (v >> 7) & 1; break;
    case 2: res = (uint8_t)(v >> 1);               cout = v & 1;        break;
    default: res = (uint8_t)((cin << 7) | (v >> 1)); cout = v & 1;      break;
    }
    return cout;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    dut = new VSPC700;
    int fails = 0, cases = 0;

    struct Case { uint8_t val; int cin; };
    const Case inputs[] = {{0x81, 0}, {0x81, 1}, {0x01, 1}, {0x00, 1}, {0xFF, 0}};

    for (int op = 0; op < 4; op++)
    for (int form = 0; form < 4; form++)
    for (Case in : inputs) {
        cases++;
        memset(ram, 0, sizeof ram);
        Asm a;
        a.op(0x20);                                // clrp
        a.op(0x8F).op(0x3C).op(0x20);              // mov $20,#$3C (poison T)
        a.op(0xE8).op(in.val);                     // mov a,#val
        uint16_t tgt = (form == F_DP) ? DP_TGT : (form == F_DPX) ? DP_TGT + 4 : ABS_TGT;
        if (form == F_DP) a.op(0xC4).op(DP_TGT);                 // mov $10,a
        if (form == F_ABS) a.op(0xC5).w16(ABS_TGT);              // mov $1234,a
        if (form == F_DPX) { a.op(0xCD).op(0x04);                // mov x,#4
                             a.op(0xD4).op(DP_TGT); }            // mov $10+x,a
        if (form != F_A) a.op(0xE8).op(0xEE);                    // mov a,#$EE (poison A)
        a.op(in.cin ? 0x80 : 0x60);                              // setc / clrc
        uint16_t shift_pc = PROG + a.b.size();
        a.op(shift_op[op][form]);
        if (form == F_DP || form == F_DPX) a.op(DP_TGT);
        if (form == F_ABS) a.w16(ABS_TGT);
        uint16_t halt_pc = PROG + a.b.size();
        a.op(0x2F).op(0xFE);                       // bra $
        memcpy(ram + PROG, a.b.data(), a.b.size());
        ram[0xFFFE] = PROG & 0xff; ram[0xFFFF] = PROG >> 8;      // reset vector
        ram[0xFFDE] = PROG & 0xff; ram[0xFFDF] = PROG >> 8;      // BRK vector

        reset();
        int halt_seen = 0;
        for (int i = 0; i < 2000 && halt_seen < 4; i++) {
            if (dut->A_OUT == halt_pc) halt_seen++;
            cycle();
        }
        uint8_t want;
        int wantc = shift_expect(op, in.val, in.cin, want);
        uint8_t got = (form == F_A) ? REG_A : ram[tgt];
        uint8_t psw = REG_PSW;
        bool ok = halt_seen >= 4 && got == want &&
                  ((psw & 0x01) != 0) == (bool)wantc &&
                  ((psw & 0x02) != 0) == (want == 0) &&
                  ((psw & 0x80) != 0) == ((want & 0x80) != 0);
        if (form != F_A && REG_A != 0xEE) ok = false;
        if (form == F_DPX && ram[DP_TGT] != 0) ok = false;       // neighbour untouched
        if (!ok) {
            fails++;
            printf("FAIL %s %s val=%02x cin=%d (pc=%04x): got=%02x want=%02x psw=%02x"
                   " (want C=%d Z=%d N=%d) A=%02x halt=%d\n",
                   op_name[op], form_name[form], in.val, in.cin, shift_pc,
                   got, want, psw, wantc, want == 0, (want & 0x80) != 0,
                   REG_A, halt_seen);
        }
    }

    printf("spc700_shift: %d cases, %d failures\n", cases, fails);
    printf(fails ? "RESULT: FAIL\n" : "RESULT: PASS\n");
    delete dut;
    return fails ? 1 : 0;
}
