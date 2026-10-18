// SA-1 boot tracer (Verilator, headless).
//
// Runs snestang_top (VERILATOR branch, sdram_sim timing model) with a ROM
// streamed through the real loader/smc_parser path and prints a periodic
// S-CPU/SA-1 trace. Frame dumps (-d) write PPMs like the smoke suite
// (even frames).
//
// Usage: Vsnestang_sa1boot -m <max_mclk> [-t <trace_every>] [-d f0,f1,..]
//        [-s <frame>] [-pxtrace <vcnt>]
//   -d: dump PPM frames (even SNES frames, like the smoke suite).
//   -s: dump VRAM (both banks), CGRAM, SA-1 IRAM and BW-RAM, OAM+HOAM,
//       and print the PPU background/Mode-7 registers at that frame.
//   -pxtrace: log the Mode-7 fetch pipeline per mclk for one V_CNT line.
//   S-CPU DMA starts and SA-1 ROM-request edges are always logged.
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <vector>

#include "Vsnestang_sa1boot.h"
#include "Vsnestang_sa1boot_snestang_top.h"
#include "Vsnestang_sa1boot__Syms.h"
#include "Vsnestang_sa1boot_SNES.h"
#include "verilated.h"

#define PX_W 256
#define PX_H 224

static void dump_state(Vsnestang_sa1boot_snestang_top *snes, unsigned long long frame) {
    char path[256];
    FILE *pf;
    // VRAM low/high bytes
    snprintf(path, sizeof path, "statedump_f%llu_vram_a.bin", frame);
    pf = fopen(path, "wb");
    if (pf) { for (int i = 0; i < 32768; i++) fputc(snes->__PVT__vram__DOT__mema[i], pf); fclose(pf); }
    snprintf(path, sizeof path, "statedump_f%llu_vram_b.bin", frame);
    pf = fopen(path, "wb");
    if (pf) { for (int i = 0; i < 32768; i++) fputc(snes->__PVT__vram__DOT__memb[i], pf); fclose(pf); }
    // CGRAM 256x15bit as LE 16-bit
    auto sn = snes->main->SNES;
    snprintf(path, sizeof path, "statedump_f%llu_cgram.bin", frame);
    pf = fopen(path, "wb");
    if (pf) { for (int i = 0; i < 256; i++) { uint16_t v = sn->__PVT__PPU__DOT__cgram__DOT__mem[i]; fputc(v & 0xFF, pf); fputc(v >> 8, pf); } fclose(pf); }
    // SA-1 IRAM 2KB
    snprintf(path, sizeof path, "statedump_f%llu_iram.bin", frame);
    pf = fopen(path, "wb");
    if (pf) { for (int i = 0; i < 2048; i++) fputc(snes->main->__PVT__genblk6__DOT__SA1Map__DOT__sa1__DOT__iram__DOT__ram[i], pf); fclose(pf); }
    // SA-1 BW-RAM 256KB
    snprintf(path, sizeof path, "statedump_f%llu_bwram.bin", frame);
    pf = fopen(path, "wb");
    if (pf) { for (int i = 0; i < 262144; i++) fputc(snes->__PVT__bwram__DOT__mem[i], pf); fclose(pf); }
    // OAM low table 512B + high table (ppuoam second mem? try 32B from OAMHIGH if present)
    snprintf(path, sizeof path, "statedump_f%llu_oam.bin", frame);
    pf = fopen(path, "wb");
    if (pf) { for (int i = 0; i < 512; i++) fputc(sn->__PVT__PPU__DOT__OAM__DOT__mem[i], pf); fclose(pf); }
    snprintf(path, sizeof path, "statedump_f%llu_hoam.bin", frame);
    pf = fopen(path, "wb");
    if (pf) { for (int i = 0; i < 32; i++) fputc(sn->__PVT__PPU__DOT__HOAM[i], pf); fclose(pf); }
    // PPU regs
    printf("ppu f=%llu mode=%d tm=%02x bg_sc_addr=%x,%x,%x,%x bg_sc_size=%x,%x,%x,%x nba=%x,%x,%x,%x size=%x\n",
        frame, (int)sn->__PVT__PPU__DOT__BG_MODE, (int)sn->__PVT__PPU__DOT__TM,
        (int)sn->__PVT__PPU__DOT__BG_SC_ADDR[0], (int)sn->__PVT__PPU__DOT__BG_SC_ADDR[1],
        (int)sn->__PVT__PPU__DOT__BG_SC_ADDR[2], (int)sn->__PVT__PPU__DOT__BG_SC_ADDR[3],
        (int)sn->__PVT__PPU__DOT__BG_SC_SIZE[0], (int)sn->__PVT__PPU__DOT__BG_SC_SIZE[1],
        (int)sn->__PVT__PPU__DOT__BG_SC_SIZE[2], (int)sn->__PVT__PPU__DOT__BG_SC_SIZE[3],
        (int)sn->__PVT__PPU__DOT__BG_NBA[0], (int)sn->__PVT__PPU__DOT__BG_NBA[1],
        (int)sn->__PVT__PPU__DOT__BG_NBA[2], (int)sn->__PVT__PPU__DOT__BG_NBA[3],
        (int)sn->__PVT__PPU__DOT__BG_SIZE);
    printf("ppu hofs=%d,%d,%d,%d vofs=%d,%d,%d,%d cgw=%02x cga=%02x inidisp=",
        (int)sn->__PVT__PPU__DOT__BG_HOFS[0], (int)sn->__PVT__PPU__DOT__BG_HOFS[1],
        (int)sn->__PVT__PPU__DOT__BG_HOFS[2], (int)sn->__PVT__PPU__DOT__BG_HOFS[3],
        (int)sn->__PVT__PPU__DOT__BG_VOFS[0], (int)sn->__PVT__PPU__DOT__BG_VOFS[1],
        (int)sn->__PVT__PPU__DOT__BG_VOFS[2], (int)sn->__PVT__PPU__DOT__BG_VOFS[3],
        (int)sn->__PVT__PPU__DOT__CGWSEL, (int)sn->__PVT__PPU__DOT__CGADSUB);
    // mosaic and brightness-adjacent regs
    printf("mosaic_en=%x size=%x\n",
        (int)sn->__PVT__PPU__DOT__BG_MOSAIC_EN, (int)sn->__PVT__PPU__DOT__MOSAIC_SIZE);
    printf("m7 sel=%02x a=%04x b=%04x c=%04x d=%04x x=%04x y=%04x hofs=%04x vofs=%04x\n",
        (int)sn->__PVT__PPU__DOT__M7SEL, (int)sn->__PVT__PPU__DOT__M7A,
        (int)sn->__PVT__PPU__DOT__M7B, (int)sn->__PVT__PPU__DOT__M7C,
        (int)sn->__PVT__PPU__DOT__M7D, (int)sn->__PVT__PPU__DOT__M7X,
        (int)sn->__PVT__PPU__DOT__M7Y, (int)sn->__PVT__PPU__DOT__M7HOFS,
        (int)sn->__PVT__PPU__DOT__M7VOFS);
    fflush(stdout);
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    uint64_t max_mclk = 0, trace_every = 10000000;
    long long statedump_frame = -1;
    long long pxtrace_vcnt = -1;
    std::vector<unsigned long long> dumps;
    for (int i = 1; i < argc; i++)
        if (strcmp(argv[i], "-m") == 0 && i + 1 < argc)
            max_mclk = strtoull(argv[++i], nullptr, 10);
        else if (strcmp(argv[i], "-t") == 0 && i + 1 < argc)
            trace_every = strtoull(argv[++i], nullptr, 10);
        else if (strcmp(argv[i], "-d") == 0 && i + 1 < argc) {
            char *list = argv[++i], *tok = strtok(list, ",");
            while (tok) { dumps.push_back(strtoull(tok, nullptr, 10)); tok = strtok(nullptr, ","); }
        }
        else if (strcmp(argv[i], "-s") == 0 && i + 1 < argc)
            statedump_frame = strtoll(argv[++i], nullptr, 10);
        else if (strcmp(argv[i], "-pxtrace") == 0 && i + 1 < argc)
            pxtrace_vcnt = strtoll(argv[++i], nullptr, 10);
    if (!max_mclk) { printf("Usage: %s -m cycles [-t every] [-d f0,f1,..]\n", argv[0]); return 1; }

    Vsnestang_sa1boot *top = new Vsnestang_sa1boot;
    Vsnestang_sa1boot_snestang_top *snes = top->snestang_top;
    auto main__ = snes->main;
    top->sys_clk = 0; top->s0 = 0; top->UART_RXD = 1;
    top->eval();

    static uint16_t fb[PX_W * PX_H];
    memset(fb, 0, sizeof fb);

    uint64_t mclk = 0, nframes = 0, next_trace = 0;
    int prev_mclk = 0;
    uint16_t prev_y = 0;
    int last_x = -1, last_y = -1;
    size_t dump_idx = 0;

    auto sn = snes->main->SNES;
    uint64_t px_lines = 0;
    uint64_t sa1rr_lines = 0;
    int last_line = -1;
    int prev_dma_active = 0;
    int prev_sa1_rom_req = 0;
    while (mclk < max_mclk) {
        top->sys_clk = 1; top->eval();
        int mc = snes->__PVT__mclk_buf;
        if (mc && !prev_mclk) {
            mclk++;
            int dma_a = (int)sn->__PVT__CPU__DOT__DMA_ACTIVE;
            if (dma_a && !prev_dma_active) {
                int ch = (int)sn->__PVT__CPU__DOT__DCH;
                printf("scpu_dma mclk=%lu ch=%d src=%02x%04x dst=%02x cnt=%04x mode=%02x\n",
                    (unsigned long)mclk, ch,
                    (int)sn->__PVT__CPU__DOT__A1B[ch], (int)sn->__PVT__CPU__DOT__A1T[ch],
                    (int)sn->__PVT__CPU__DOT__BBAD[ch], (int)sn->__PVT__CPU__DOT__DAS[ch],
                    (int)sn->__PVT__CPU__DOT__DMAP[ch]);
            }
            prev_dma_active = dma_a;
            int sa1_rr = (int)snes->__PVT__sa1_rom_req;
            if (sa1_rr != prev_sa1_rom_req && sa1rr_lines < 200) {
                printf("sa1_rom_req mclk=%lu req=%d cpu2req=%d\n",
                    (unsigned long)mclk, sa1_rr, (int)snes->__PVT__sa1_cpu2_req);
                sa1rr_lines++;
                prev_sa1_rom_req = sa1_rr;
            } else if (sa1_rr != prev_sa1_rom_req) {
                prev_sa1_rom_req = sa1_rr;
            }
            // per-line M7 reg capture for frames 104-105 (reference renderer)
            int vcnt = (int)sn->__PVT__PPU__DOT__V_CNT;
            int hcnt = (int)sn->__PVT__PPU__DOT__H_CNT;
            if (nframes >= 80 && nframes < 100 && vcnt >= 1 && vcnt <= 224 && hcnt == 274 && vcnt != last_line) {
                last_line = vcnt;
                printf("m7line f=%lu v=%d sel=%02x a=%04x b=%04x c=%04x d=%04x x=%04x y=%04x hofs=%04x vofs=%04x mb=%x fb=%d\n",
                    (unsigned long)nframes, vcnt,
                    (int)sn->__PVT__PPU__DOT__M7SEL, (int)sn->__PVT__PPU__DOT__M7A,
                    (int)sn->__PVT__PPU__DOT__M7B, (int)sn->__PVT__PPU__DOT__M7C,
                    (int)sn->__PVT__PPU__DOT__M7D, (int)sn->__PVT__PPU__DOT__M7X,
                    (int)sn->__PVT__PPU__DOT__M7Y, (int)sn->__PVT__PPU__DOT__M7HOFS,
                    (int)sn->__PVT__PPU__DOT__M7VOFS, (int)sn->__PVT__PPU__DOT__MB,
                    (int)sn->__PVT__PPU__DOT__FORCE_BLANK);
            }
            if (pxtrace_vcnt >= 0 && nframes >= 106 && nframes < 108 && (long long)sn->__PVT__PPU__DOT__V_CNT == pxtrace_vcnt &&
                sn->__PVT__PPU__DOT__H_CNT >= 60 && sn->__PVT__PPU__DOT__H_CNT <= 140 && px_lines < 4000) {
                px_lines++;
                printf("px nf=%lu h=%d x=%d scx=%d vramx=%06x addra=%04x dai=%02x vramq=%02x maindi=%02x oen=%d tilen=%02x row=%d col=%d addrb=%04x dbi=%02x pix=%02x bg1=%03x spr=%03x out=%d tout=%d sg=%d bgg=%d\n",
                    (unsigned long)nframes,
                    (int)sn->__PVT__PPU__DOT__H_CNT, (int)snes->x_out,
                    (int)sn->__PVT__PPU__DOT__M7_SCREEN_X, (unsigned)sn->__PVT__PPU__DOT__M7_VRAM_X & 0xFFFFFF,
                    (unsigned)sn->__PVT__PPU__DOT__BG_VRAM_ADDRA, (unsigned)sn->__PVT__VRAM_DAI,
                    (unsigned)snes->__PVT__VRAM1_Q, (unsigned)snes->main->__PVT__VRAM1_DI,
                    (int)snes->__PVT__VRAM_OE_N,
                    (unsigned)sn->__PVT__PPU__DOT__M7_TILE_N, (int)sn->__PVT__PPU__DOT__M7_TILE_ROW,
                    (int)sn->__PVT__PPU__DOT__M7_TILE_COL, (unsigned)sn->__PVT__PPU__DOT__BG_VRAM_ADDRB,
                    (unsigned)sn->__PVT__VRAM_DBI, (unsigned)sn->__PVT__PPU__DOT__M7_PIX_DATA,
                    (unsigned)sn->__PVT__PPU__DOT__BG1_PIX_DATA,
                    (unsigned)sn->__PVT__PPU__DOT__SPR_PIX_DATA,
                    (int)sn->__PVT__PPU__DOT__M7_IS_OUTSIDE, (int)sn->__PVT__PPU__DOT__M7_TILE_OUTSIDE,
                    (int)sn->__PVT__PPU__DOT__SPR_GET_PIXEL, (int)sn->__PVT__PPU__DOT__BG_GET_PIXEL);
            }
            uint16_t y = snes->y_out;
            if (y < prev_y && prev_y > 200) {
                nframes++;
                if (nframes >= 58 && nframes <= 70)
                    printf("wrap nframes=%lu vcnt=%d field=%d outy=%d m7a=%04x\n",
                        (unsigned long)nframes, (int)sn->__PVT__PPU__DOT__V_CNT,
                        (int)sn->__PVT__PPU__DOT__FIELD, (int)sn->__PVT__PPU__DOT__OUT_Y,
                        (int)sn->__PVT__PPU__DOT__M7A);
                // dumps snap to even SNES frames (ff*2), like the smoke suite
                uint64_t frame = (nframes / 2) * 2;
                if ((long long)frame == statedump_frame) { dump_state(snes, frame); statedump_frame = -2; }
                if (dump_idx < dumps.size() && frame >= dumps[dump_idx]) {
                    char path[256];
                    snprintf(path, sizeof path, "sa1boot_f%llu.ppm", (unsigned long long)frame);
                    FILE *pf = fopen(path, "wb");
                    if (pf) {
                        fprintf(pf, "P6\n256 224\n255\n");
                        for (int i = 0; i < PX_W * PX_H; i++) {
                            uint16_t px = fb[i];
                            uint8_t rgb[3] = {
                                (uint8_t)(((px >> 10) & 0x1F) * 255 / 31),
                                (uint8_t)(((px >> 5) & 0x1F) * 255 / 31),
                                (uint8_t)((px & 0x1F) * 255 / 31)};
                            fwrite(rgb, 1, 3, pf);
                        }
                        fclose(pf);
                        printf("dumped %s\n", path);
                    }
                    dump_idx++;
                }
            }
            prev_y = y;
            int x = snes->x_out;
            if ((x != last_x || (int)y != last_y) && x < PX_W && (y & 0xFF) < PX_H) {
                fb[(y & 0xFF) * PX_W + x] = snes->rgb_out & 0x7FFF;
                last_x = x; last_y = (int)y;
            }
            if (mclk >= next_trace) {
                printf("tr mclk=%lu fr=%lu load=%d type=%02x ca=%06x\n",
                       (unsigned long)mclk, (unsigned long)nframes,
                       (int)snes->__PVT__loading,
                       (unsigned)snes->__PVT__rom_type,
                       (unsigned)main__->__PVT__CA);
                fflush(stdout);
                next_trace += trace_every;
            }
        }
        prev_mclk = mc;
        top->sys_clk = 0; top->eval();
    }
    printf("done: mclk=%lu frames=%lu\n",
           (unsigned long)mclk, (unsigned long)nframes);
    delete top;
    return 0;
}
