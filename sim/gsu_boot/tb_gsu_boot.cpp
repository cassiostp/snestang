// Headless full-system GSU boot bench.
//
// Runs snestang_top (VERILATOR branch, sdram_sim timing model) with
// PeterLemon's freely distributable GSU2BPP256x192FillPoly test ROM
// streamed through the real loader/smc_parser path, then dumps the GSU
// work RAM (the SDRAM model's BSRAM image) for check.py. The demo's GSU
// program fills the screen, copies its scan tables ROM->RAM (getb/stw),
// plots a filled diamond from them (ldw/plot/pixel-cache flush) and
// STOPs, so one run exercises the GSU ROM fetch (CPU2 word cache +
// ROM_WAIT), the BSRAM bridge under back-to-back byte writes, GSU RAM
// reads, and the 192-line char-offset math. Before the fix/coproc-boot
// changes the GSU sampled 0x00 (STOP) as its first opcode: the fetch on
// the shared fire-and-forget CPU lane was lost to a WRAM toggle.
// Usage: Vsnestang_gsu -m <max_mclk_cycles>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>

#include "Vsnestang_gsu.h"
#include "Vsnestang_gsu_snestang_top.h"
#include "Vsnestang_gsu_main__UF1_UD1.h"
#include "verilated.h"

#define GSU_(f) main__->__PVT__genblk5__DOT__GSUMap__DOT__GSU__DOT__##f

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    uint64_t max_mclk = 0;
    for (int i = 1; i < argc; i++)
        if (strcmp(argv[i], "-m") == 0 && i + 1 < argc)
            max_mclk = strtoull(argv[++i], nullptr, 10);
    if (!max_mclk) { printf("Usage: %s -m cycles\n", argv[0]); return 1; }

    Vsnestang_gsu *top = new Vsnestang_gsu;
    Vsnestang_gsu_snestang_top *snes = top->snestang_top;
    Vsnestang_gsu_main__UF1_UD1 *main__ = snes->main;
    top->sys_clk = 0; top->s0 = 0; top->UART_RXD = 1;
    top->eval();

    uint64_t mclk = 0, nframes = 0, go_edges = 0, go_cycles = 0;
    int prev_mclk = 0, prev_go = 0;
    uint16_t prev_y = 0;

    while (mclk < max_mclk) {
        top->sys_clk = 1; top->eval();
        int mc = snes->__PVT__mclk_buf;
        if (mc && !prev_mclk) {
            mclk++;
            uint16_t y = snes->y_out;
            if (y < prev_y && prev_y > 200) nframes++;
            prev_y = y;
            int go = GSU_(FLAG_GO);
            if (go) go_cycles++;
            if (go && !prev_go) go_edges++;
            prev_go = go;
        }
        prev_mclk = mc;
        top->sys_clk = 0; top->eval();
    }

    FILE *bf = fopen("bsram.bin", "wb");
    for (int i = 0; i < 65536; i++) {
        uint16_t w = snes->__PVT__sdram__DOT__mem_bsram[i];
        fputc(w & 0xFF, bf); fputc(w >> 8, bf);
    }
    fclose(bf);
    printf("done: mclk=%lu frames=%lu rom_type=%02x go_edges=%lu go_cycles=%lu\n",
           (unsigned long)mclk, (unsigned long)nframes,
           (unsigned)snes->__PVT__rom_type,
           (unsigned long)go_edges, (unsigned long)go_cycles);
    int ok = nframes >= 10 && snes->__PVT__rom_type == 0x70 &&
             go_edges >= 1 && go_cycles > 100000;
    printf("tb_gsu_boot: %s\n", ok ? "PASS" : "FAIL");
    delete top;
    return ok ? 0 : 1;
}
