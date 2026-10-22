// CX4 boot tracer (Verilator, headless).
//
// Runs snestang_top (VERILATOR branch, sdram_sim timing model) with a ROM
// streamed through the real loader/smc_parser path and prints a periodic
// S-CPU/CX4 trace plus a CX4 PC histogram at the end. Frame dumps (-d)
// write PPMs like the smoke suite (even frames).
//
// Usage: Vsnestang_cx4boot -m <max_mclk> [-t <trace_every>] [-d f0,f1,..]
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <vector>

#include "Vsnestang_cx4boot.h"
#include "Vsnestang_cx4boot_snestang_top.h"
#include "Vsnestang_cx4boot__Syms.h"
#include "Vsnestang_cx4boot_SNES.h"
#include "verilated.h"

#ifndef TANGCORE_SIM_THREADS
#define TANGCORE_SIM_THREADS 1
#endif

#define CX4(f) main__->__PVT__genblk3__DOT__CX4Map__DOT__cx4__DOT__##f
#define PX_W 256
#define PX_H 224

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    Verilated::threadContextp()->threads(TANGCORE_SIM_THREADS);
    fprintf(stderr, "model threads: %u\n", Verilated::threadContextp()->threads());
    uint64_t max_mclk = 0, trace_every = 10000000;
    std::vector<unsigned long long> dumps;
    const char *scriptpath = nullptr;
    std::vector<std::pair<uint64_t, uint16_t>> script;
    size_t script_idx = 0;
    for (int i = 1; i < argc; i++)
        if (strcmp(argv[i], "-m") == 0 && i + 1 < argc)
            max_mclk = strtoull(argv[++i], nullptr, 10);
        else if (strcmp(argv[i], "-t") == 0 && i + 1 < argc)
            trace_every = strtoull(argv[++i], nullptr, 10);
        else if (strcmp(argv[i], "-i") == 0 && i + 1 < argc)
            scriptpath = argv[++i];
        else if (strcmp(argv[i], "-d") == 0 && i + 1 < argc) {
            char *list = argv[++i], *tok = strtok(list, ",");
            while (tok) { dumps.push_back(strtoull(tok, nullptr, 10)); tok = strtok(nullptr, ","); }
        }
    if (!max_mclk) { printf("Usage: %s -m cycles [-t every] [-d f0,f1,..]\n", argv[0]); return 1; }

    if (scriptpath) {
        FILE *sf = fopen(scriptpath, "r");
        if (!sf) { perror(scriptpath); return 1; }
        unsigned long long fr; unsigned btn;
        while (fscanf(sf, "%llu %x", &fr, &btn) == 2)
            script.push_back({fr, (uint16_t)btn});
        fclose(sf);
    }

    Vsnestang_cx4boot *top = new Vsnestang_cx4boot;
    Vsnestang_cx4boot_snestang_top *snes = top->snestang_top;
    auto main__ = snes->main;
    top->sys_clk = 0; top->s0 = 0; top->UART_RXD = 1;
    top->eval();

    static uint16_t fb[PX_W * PX_H];
    memset(fb, 0, sizeof fb);

    uint64_t mclk = 0, nframes = 0, next_trace = 0;
    int prev_mclk = 0;
    uint16_t prev_y = 0;
    int prev_mmio = 0, last_x = -1, last_y = -1;
    uint64_t mmio_count = 0;
    uint64_t pc_hist[512] = {0};
    size_t dump_idx = 0;

    while (mclk < max_mclk) {
        top->sys_clk = 1; top->eval();
        int mc = snes->__PVT__mclk_buf;
        if (mc && !prev_mclk) {
            mclk++;
            uint16_t y = snes->y_out;
            if (y < prev_y && prev_y > 200) {
                // y_out includes FIELD in bit 8; it wraps every two frames.
                nframes += 2;
                unsigned nonzero = 0;
                for (auto px : fb) if (px) nonzero++;
                printf("frame=%lu nonzero=%u\n", (unsigned long)nframes, nonzero);
                while (script_idx < script.size() && nframes >= script[script_idx].first) {
                    snes->tb_joy1 = script[script_idx].second;
                    printf("input frame=%lu buttons=%03x\n", (unsigned long)nframes, script[script_idx].second);
                    script_idx++;
                }
                // dumps snap to even SNES frames (ff*2), like the smoke suite
                uint64_t frame = (nframes / 2) * 2;
                if (dump_idx < dumps.size() && frame >= dumps[dump_idx]) {
                    char path[256];
                    snprintf(path, sizeof path, "cx4boot_f%llu.ppm", (unsigned long long)frame);
                    FILE *pf = fopen(path, "wb");
                    if (pf) {
                        fprintf(pf, "P6\n256 224\n255\n");
                        for (int i = 0; i < PX_W * PX_H; i++) {
                            uint16_t px = fb[i];
                            uint8_t rgb[3] = {
                                (uint8_t)((px & 0x1F) * 255 / 31),
                                (uint8_t)(((px >> 5) & 0x1F) * 255 / 31),
                                (uint8_t)(((px >> 10) & 0x1F) * 255 / 31)};
                            fwrite(rgb, 1, 3, pf);
                        }
                        fclose(pf);
                        printf("dumped %s\n", path);
                    }
                    dump_idx++;
                }
            }
            prev_y = y;
            // X_OUT = {OUT_X, DOT_CLK}; sample one phase per low-res pixel.
            int x = snes->x_out >> 1;
            if ((x != last_x || (int)y != last_y) && x < PX_W && (y & 0xFF) < PX_H) {
                fb[(y & 0xFF) * PX_W + x] = snes->rgb_out & 0x7FFF;
                last_x = x; last_y = (int)y;
            }
            int mmio = CX4(mmio_wr);
            if (mmio && !prev_mmio) {
                mmio_count++;
                if (mmio_count <= 300)
                    printf("mmio mclk=%lu ca=%06x\n", (unsigned long)mclk,
                           (unsigned)main__->__PVT__CA);
            }
            prev_mmio = mmio;
            if (mclk >= 9000000)
                pc_hist[CX4(cache_addr_rd) & 511]++;
            if (mclk >= next_trace) {
                printf("tr mclk=%lu fr=%lu load=%d type=%02x ca=%06x "
                       "busy=%d cpuen=%d int=%06x rdpc=%03x\n",
                       (unsigned long)mclk, (unsigned long)nframes,
                       (int)snes->__PVT__loading,
                       (unsigned)snes->__PVT__rom_type,
                       (unsigned)main__->__PVT__CA,
                       (int)CX4(busy), (int)CX4(cpu_en),
                       (unsigned)CX4(int_addr),
                       (unsigned)CX4(cache_addr_rd));
                fflush(stdout);
                next_trace += trace_every;
            }
        }
        prev_mclk = mc;
        top->sys_clk = 0; top->eval();
    }
    printf("pc histogram (pc:count):\n");
    for (int i = 0; i < 512; i++)
        if (pc_hist[i]) printf("  %03x:%lu\n", i, (unsigned long)pc_hist[i]);
    printf("done: mclk=%lu frames=%lu mmio_writes=%lu\n",
           (unsigned long)mclk, (unsigned long)nframes, (unsigned long)mmio_count);
    delete top;
    return 0;
}
