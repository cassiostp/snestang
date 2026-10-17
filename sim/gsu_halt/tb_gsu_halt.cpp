// Does the GSU freeze while ENABLE is low (the frame-sync halt and the
// menu pause both drop main's ENABLE)? The GSU runs a NOP sled from ROM;
// activity is R15 (its PC, read back over the MMIO register window)
// advancing and ROM_A changing. SYSCLKF/R_CE keep pulsing during the
// halt, as cpu.v keeps them at the DMA rate while ~ENABLE, so this is
// the worst case the real top presents.
//
//   default: ENABLE follows the halt (post-fix main.v) -> state still
//   +FREE:   ENABLE held high through the window (the old 1'b1 tie) ->
//            the PC must advance, proving the bench can see movement
#include "VGSU.h"
#include "verilated.h"
#include <cstdio>
#include <cstring>

static VGSU* g;
static long cyc = 0;
static int roma_changes = 0, we_pulses = 0;
static uint32_t roma_prev = 0;

static void tick() {
    g->SYSCLKR_CE = (cyc % 8 == 2);
    g->SYSCLKF_CE = (cyc % 8 == 6);
    g->CLK = 0; g->eval();
    g->CLK = 1; g->eval();
    cyc++;
    if (g->ROM_A != roma_prev) { roma_changes++; roma_prev = g->ROM_A; }
    if (!g->RAM_WE_N) we_pulses++;
}
static void ticks(int n) { while (n-- > 0) tick(); }

static void cpu_write(uint32_t a, uint8_t d) {
    g->ADDR = a; g->DI = d; g->WR_N = 0;
    // hold until a SYSCLKF_CE has been sampled with the write up
    do tick(); while (!g->SYSCLKF_CE);
    tick();
    g->WR_N = 1; g->ADDR = 0; g->DI = 0;
    ticks(4);
}
static uint8_t cpu_read(uint32_t a) {
    g->ADDR = a; g->RD_N = 0; g->eval();
    uint8_t v = g->DO;
    g->RD_N = 1; g->ADDR = 0;
    return v;
}
static uint16_t read_r15() {
    return cpu_read(0x301E) | (cpu_read(0x301F) << 8);
}
static int read_flag_go() { return (cpu_read(0x3030) >> 5) & 1; }

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    bool free_run = false;
    for (int i = 1; i < argc; i++) if (!strcmp(argv[i], "+FREE")) free_run = true;
    g = new VGSU;
    int errors = 0;

    g->ROM_DI = 0x01;           // NOP sled
    g->RAM_DI = 0;
    g->RD_N = 1; g->WR_N = 1; g->TURBO = 0;
    g->RST_N = 0; g->ENABLE = 0;
    ticks(10);
    g->RST_N = 1; g->ENABLE = 1;
    ticks(20);
    cpu_write(0x3034, 0x00);    // PBR = 0
    cpu_write(0x303A, 0x18);    // SCMR: RON|RAN
    cpu_write(0x301E, 0x00);    // R15 low
    cpu_write(0x301F, 0x00);    // R15 high -> GO
    ticks(3000);
    uint16_t pc_run = read_r15();
    if (!read_flag_go()) { errors++; printf("FAIL: GSU not running (FLAG_GO=0)\n"); }
    if (pc_run == 0) { errors++; printf("FAIL: PC never advanced\n"); }
    printf("run: pc=%u flag_go=%d\n", pc_run, read_flag_go());

    if (!free_run) g->ENABLE = 0;
    ticks(4);                   // let EN (negedge) drop
    uint16_t pc0 = read_r15();
    roma_changes = 0; we_pulses = 0;
    ticks(3000);
    uint16_t pc1 = read_r15();
    printf("halt(%s): pc %u -> %u, rom_a changes=%d, ram_we pulses=%d\n",
           free_run ? "free" : "held", pc0, pc1, roma_changes, we_pulses);
    if (free_run) {
        if (pc1 == pc0) { errors++; printf("FAIL: free-run control did not advance\n"); }
    } else {
        if (pc1 != pc0) { errors++; printf("FAIL: PC moved during halt\n"); }
        if (roma_changes != 0) { errors++; printf("FAIL: ROM_A moved during halt\n"); }
        if (we_pulses != 0) { errors++; printf("FAIL: RAM write during halt\n"); }
    }

    g->ENABLE = 1;
    ticks(3000);
    if (!read_flag_go()) { errors++; printf("FAIL: GSU stopped across halt\n"); }
    if (read_r15() == pc0) { errors++; printf("FAIL: PC did not resume\n"); }
    printf("resumed: pc=%u\n", read_r15());

    printf(errors ? "tb_gsu_halt: FAIL (%d)\n" : "tb_gsu_halt: PASS\n", errors);
    return errors ? 1 : 0;
}
