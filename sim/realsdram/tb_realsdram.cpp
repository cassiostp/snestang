// Full-system capture with the real sdram_snes controller and sdram_chip.
// Same CLI and log format as tools/smoke/snes/tb_smoke_snes.cpp, so a run
// compares frame-for-frame with a behavioural-model run. BSRAM and ARAM
// are read back from the chip array (see sim/cosim/sdram_chip.sv):
//   BSRAM words at 0x780000 (bank 1, {5'b01111, byte_addr[19:1]})
//   ARAM  words at 0xBC0000 (bank 2, {2'b10, 7'b1111000, byte_addr[15:1]})
//
// Usage:
//   Vsnestang_smoke -m <max_mclk> -o <outprefix> [-i script] [-d f0,f1,..]
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <vector>
#include <utility>

#include "Vsnestang_smoke.h"
#include "Vsnestang_smoke_snes_realsdram_top.h"
#include "Vsnestang_smoke_snestang_top.h"
#include "Vsnestang_smoke_sdram_chip.h"
#include "verilated.h"

#define PX_W 256
#define PX_H 224
#define BSRAM_WORD 0x780000
#define ARAM_WORD  0xBC0000

static uint16_t chip_at(Vsnestang_smoke_sdram_chip *chip, int i) {
    return chip->mem[i];
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    uint64_t max_mclk = 0;
    const char *outprefix = "smoke";
    const char *scriptpath = nullptr;
    std::vector<unsigned long long> dumps;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-m") == 0 && i + 1 < argc)
            max_mclk = strtoull(argv[++i], nullptr, 10);
        else if (strcmp(argv[i], "-o") == 0 && i + 1 < argc)
            outprefix = argv[++i];
        else if (strcmp(argv[i], "-i") == 0 && i + 1 < argc)
            scriptpath = argv[++i];
        else if (strcmp(argv[i], "-d") == 0 && i + 1 < argc) {
            char *list = argv[++i], *tok = strtok(list, ",");
            while (tok) { dumps.push_back(strtoull(tok, nullptr, 10)); tok = strtok(nullptr, ","); }
        }
    }
    if (max_mclk == 0) {
        printf("Usage: %s -m <max_mclk> [-o prefix] [-i script] [-d f0,f1,..]\n", argv[0]);
        return 1;
    }
    std::vector<std::pair<uint64_t, uint16_t>> script;
    if (scriptpath) {
        FILE *sf = fopen(scriptpath, "r");
        if (!sf) { printf("cannot open script %s\n", scriptpath); return 1; }
        unsigned long long fr; unsigned int btn;
        while (fscanf(sf, "%llu %x", &fr, &btn) == 2)
            script.push_back({fr, (uint16_t)btn});
        fclose(sf);
        printf("script: %zu entries\n", script.size());
    }

    Vsnestang_smoke *top = new Vsnestang_smoke;
    Vsnestang_smoke_snestang_top *snes = top->snes_realsdram_top->snestang_top;
    Vsnestang_smoke_sdram_chip *chip = top->snes_realsdram_top->chip;
    char path[1024];
    snprintf(path, sizeof path, "%s.log", outprefix);
    FILE *f = fopen(path, "w");
    snprintf(path, sizeof path, "%s.aud", outprefix);
    FILE *fa = fopen(path, "wb");
    if (!f || !fa) { printf("cannot open outputs\n"); return 1; }
    setvbuf(f, NULL, _IOFBF, 1 << 20);
    setvbuf(fa, NULL, _IOFBF, 1 << 20);

    top->sys_clk = 0;
    top->s0 = 0;
    top->UART_RXD = 1;
    top->eval();

    static uint16_t fb[PX_W * PX_H];
    memset(fb, 0, sizeof fb);

    uint64_t mclk = 0, nsamp = 0, ff = 0;
    int prev_mclk = 0, prev_ready = 0;
    int prev_y = -1, last_x = -1, last_y = -1;
    uint64_t vhash = 1469598103934665603ULL;
    uint64_t frame_nonzero = 0;
    size_t script_idx = 0;

    while (mclk < max_mclk) {
        top->sys_clk = 1;
        top->eval();
        int mc = snes->__PVT__mclk_buf;
        if (mc && !prev_mclk) {
            mclk++;
            int x = snes->x_out, y = snes->y_out;
            if ((x != last_x || y != last_y) && x < PX_W && (y & 0xFF) < PX_H) {
                uint16_t px = snes->rgb_out & 0x7FFF;
                vhash ^= (uint64_t)px;
                vhash *= 1099511628211ULL;
                fb[(y & 0xFF) * PX_W + x] = px;
                if (px) frame_nonzero++;
                last_x = x; last_y = y;
            }
            int rdy = snes->audio_ready;
            if (rdy && !prev_ready) {
                int16_t lr[2] = {(int16_t)snes->audio_l, (int16_t)snes->audio_r};
                fwrite(lr, 2, 2, fa);
                nsamp++;
            }
            prev_ready = rdy;
            if (prev_y >= 0 && y < prev_y && prev_y > 200) {
                unsigned long frame = (unsigned long)(ff * 2);
                fprintf(f, "F %lu ff=%lu mclk=%lu samp=%lu vhash=%016lx nz=%lu joy=%03x romtype=%02x\n",
                        frame, (unsigned long)ff, (unsigned long)mclk, (unsigned long)nsamp,
                        (unsigned long)vhash, (unsigned long)frame_nonzero,
                        (unsigned)snes->tb_joy1,
                        (unsigned)snes->__PVT__rom_type);
                for (auto df : dumps) {
                    if (df == frame) {
                        snprintf(path, sizeof path, "%s_f%lu.ppm", outprefix, frame);
                        FILE *pf = fopen(path, "wb");
                        if (pf) {
                            fprintf(pf, "P6\n%d %d\n255\n", PX_W, PX_H);
                            for (int i = 0; i < PX_W * PX_H; i++) {
                                uint16_t px = fb[i];
                                uint8_t rgb[3] = {
                                    (uint8_t)(((px >> 10) & 0x1F) * 255 / 31),
                                    (uint8_t)(((px >> 5) & 0x1F) * 255 / 31),
                                    (uint8_t)((px & 0x1F) * 255 / 31)};
                                fwrite(rgb, 1, 3, pf);
                            }
                            fclose(pf);
                        }
                    }
                }
                vhash = 1469598103934665603ULL;
                frame_nonzero = 0;
                ff++;
                while (script_idx < script.size() && script[script_idx].first <= ff * 2) {
                    snes->tb_joy1 = script[script_idx].second;
                    script_idx++;
                }
                if (ff % 300 == 0)
                    printf("mclk=%lu ff=%lu samples=%lu\n",
                           (unsigned long)mclk, (unsigned long)ff, (unsigned long)nsamp);
            }
            prev_y = y;
        }
        prev_mclk = mc;
        top->sys_clk = 0;
        top->eval();
    }

    snprintf(path, sizeof path, "%s_bsram.bin", outprefix);
    FILE *fbw = fopen(path, "wb");
    uint64_t bh = 1469598103934665603ULL;
    for (int i = 0; i < 65536; i++) {
        uint16_t w = chip_at(chip, BSRAM_WORD + i);
        uint8_t b[2] = {(uint8_t)(w & 0xFF), (uint8_t)(w >> 8)};
        if (fbw) fwrite(b, 1, 2, fbw);
        bh ^= b[0]; bh *= 1099511628211ULL; bh ^= b[1]; bh *= 1099511628211ULL;
    }
    if (fbw) fclose(fbw);
    snprintf(path, sizeof path, "%s_aram.bin", outprefix);
    FILE *faw = fopen(path, "wb");
    uint64_t ah = 1469598103934665603ULL;
    for (int i = 0; i < 32768; i++) {
        uint16_t w = chip_at(chip, ARAM_WORD + i);
        uint8_t b[2] = {(uint8_t)(w & 0xFF), (uint8_t)(w >> 8)};
        if (faw) fwrite(b, 1, 2, faw);
        ah ^= b[0]; ah *= 1099511628211ULL; ah ^= b[1]; ah *= 1099511628211ULL;
    }
    if (faw) fclose(faw);
    fprintf(f, "END mclk=%lu ff=%lu frames=%lu samples=%lu bsram=%016lx aram=%016lx\n",
            (unsigned long)mclk, (unsigned long)ff, (unsigned long)(ff * 2),
            (unsigned long)nsamp, (unsigned long)bh, (unsigned long)ah);
    printf("done: mclk=%lu ff=%lu frames=%lu samples=%lu bsram=%016lx aram=%016lx\n",
           (unsigned long)mclk, (unsigned long)ff, (unsigned long)(ff * 2),
           (unsigned long)nsamp, (unsigned long)bh, (unsigned long)ah);
    fclose(f); fclose(fa);
    delete top;
    return 0;
}
