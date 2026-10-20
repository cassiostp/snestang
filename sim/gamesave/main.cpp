// Headless SNES game-pattern sim: the real snestang core (snestang_top built
// for Verilator: 65816, the cartridge decode in DSP_LHRomMap, smc_parser, the
// SNES-bus edge detectors and the save/BSRAM bridge) runs a small battery game
// (mkrom.py) and this driver watches its save RAM:
//   - sv_core_we, the strobe snestang_top hands to iosys (-> the 0x0B notice);
//   - the BSRAM bytes in the SDRAM model, where the save channel reads them;
//   - the save channel itself, driven through the bridge's sv_req/sv_rreq
//     toggles exactly as iosys does: the restore (0x11) BEFORE the core is
//     released from its loading state, the dump (0x12) while the game runs.
//
//   boot 1: blank BSRAM (0xFF, the firmware's blank restore): the game finds
//           no signature and writes its save at the real cartridge addresses.
//           Then the dump runs while the game keeps reading its SRAM.
//   boot 2: the dump from boot 1 restored through the bridge while the core is
//           held: the game finds the signature (reads it back) and writes only
//           its $77 marker.
//
// usage: gamesave +rom=<hex> +size=<n> +kind=<lorom|hirom>_<kb>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "Vgamesave_top.h"
#include "Vgamesave_top_gamesave_top.h"
#include "Vgamesave_top_snestang_top.h"
#include "Vgamesave_top_sdram_chip.h"
#include "verilated.h"

struct Run {
    uint64_t writes = 0;                    // sv_core_we rising edges
    std::vector<uint8_t> sram;              // BSRAM after the run
    std::vector<uint8_t> dump;              // what the save channel read back
    bool dump_ok = true;
    bool err_flag = false;                  // the game saw its signature change
};

struct Sim {
    Vgamesave_top *top;
    Vgamesave_top_snestang_top *s;       // the core
    Vgamesave_top_sdram_chip *chip;      // the SDRAM chip model
    uint64_t writes = 0;
    bool prev_we = false;
    uint64_t cycles = 0;
    bool err_seen = false;                  // first $EE write to the error flag
    uint64_t err_at = 0, err_write = 0;

    Sim() {
        top = new Vgamesave_top;
        s = top->gamesave_top->u;
        chip = top->gamesave_top->chip;
    }
    ~Sim() {
        top->final();
        delete top;
    }
    void tick() {
        top->sys_clk = 0;
        top->eval();
        top->sys_clk = 1;
        top->eval();
        bool we = s->sv_core_we;
        if (we && !prev_we) {
            writes++;
            if (s->BSRAM_D == 0xEE && s->BSRAM_ADDR == 0x3F0 && !err_seen) {
                err_seen = true;
                err_at = cycles;
                err_write = writes;
            }
        }
        prev_we = we;
        cycles++;
    }
    void ticks(uint64_t n) {
        while (n--)
            tick();
    }
    // BSRAM sits at word 0x780000 of the SDRAM chip ({5'b01_111, bsram_addr})
    static const uint32_t BSRAM_WORD = 0x780000;
    uint8_t bsram(uint32_t a) {
        uint16_t w = chip->mem[BSRAM_WORD + (a >> 1)];
        return (a & 1) ? (w >> 8) : (w & 0xFF);
    }
    void set_bsram(uint32_t a, uint8_t b) {
        uint16_t &w = chip->mem[BSRAM_WORD + (a >> 1)];
        w = (a & 1) ? ((w & 0x00FF) | (b << 8)) : ((w & 0xFF00) | b);
    }
    // iosys's save channel through the real bridge: toggle a request, wait for
    // the toggle back.
    bool bridge_write(uint32_t a, uint8_t b) {
        bool ack0 = s->sv_ack_r;
        s->sv_addr = a;
        s->sv_din = b;
        s->sv_req = !s->sv_req;
        for (int i = 0; i < 4000; i++) {
            tick();
            if (s->sv_ack_r != ack0)
                return true;
        }
        return false;
    }
    bool bridge_read(uint32_t a, uint8_t *b) {
        bool ack0 = s->sv_rack_r;
        s->sv_addr = a;
        s->sv_rreq = !s->sv_rreq;
        for (int i = 0; i < 4000; i++) {
            tick();
            if (s->sv_rack_r != ack0) {
                *b = s->sv_q_r;
                return true;
            }
        }
        return false;
    }
    // wait for the ack of an already-toggled read (no new toggle: the
    // bridge consumes one toggle at a time, so a deferred request must be
    // completed before the next one starts).
    bool bridge_wait_rack(uint8_t *b) {
        bool ack0 = s->sv_rack_r;
        for (int i = 0; i < 4000; i++) {
            tick();
            if (s->sv_rack_r != ack0) {
                *b = s->sv_q_r;
                return true;
            }
        }
        return false;
    }
};

static int fails = 0;
static void check(bool ok, const char *what) {
    printf("  %s %s\n", ok ? "ok  " : "FAIL", what);
    if (!ok)
        fails++;
}

// One boot of the cartridge. `image` is the save to restore through the
// bridge before the core runs (empty = leave the BSRAM blank, 0xFF).
// With prove_defer the dump first runs unpaused (it must defer: no byte
// acked, game undisturbed) and then completes after the pause.
static Run boot(int argc, char **argv, uint32_t size, const std::vector<uint8_t> &image,
                uint64_t run_cycles, bool do_dump, bool pause_dump = false,
                bool prove_defer = false) {
    Verilated::commandArgs(argc, argv);
    Sim sim;
    Run run;
    for (uint32_t i = 0; i < 0x20000; i++)
        sim.set_bsram(i, 0xFF);
    // the ROM streams in, with the core held (loading); the hold stays until
    // the restore is done, like the firmware's restore-before-release
    sim.s->test_loader__DOT__hold = 1;
    for (uint64_t t = 0; t < 8000000; t++) {
        sim.tick();
        if (sim.s->test_loader__DOT__addr == sim.s->test_loader__DOT__size && sim.s->resetn)
            break;
    }
    sim.ticks(2000);
    if (!image.empty()) {
        bool ok = true;
        for (uint32_t i = 0; i < size && ok; i++)
            ok = sim.bridge_write(i, image[i]);
        check(ok, "the save restored through the bridge while the core is held");
    }
    sim.writes = 0;
    uint64_t run_start = sim.cycles;
    sim.s->test_loader__DOT__hold = 0;      // the core starts
    sim.ticks(run_cycles);
    run.writes = sim.writes;

    uint64_t dump_start = sim.cycles;
    if (do_dump) {
        printf("    dump begins at cycle %llu%s\n", (unsigned long long)dump_start,
               pause_dump ? " (game paused, core_config bit 17, as the firmware does)" : " (game running)");
        if (pause_dump)
            sim.s->core_config |= 1u << 17;
        // the game keeps reading SRAM+0 in its idle loop while we dump
        run.dump.resize(size);
        for (uint32_t i = 0; i < size && run.dump_ok; i++)
            run.dump_ok = sim.bridge_read(i, &run.dump[i]);
        if (prove_defer) {
            // The bridge defers save-channel bytes while the core runs, so
            // no byte can be in flight when the game presents its own read.
            check(!run.dump_ok, "the unpaused dump is deferred (no byte acked while the core runs)");
            // The pending byte-0 request still completes once paused, and
            // the rest of the dump then reads clean: deferral loses nothing.
            sim.s->core_config |= 1u << 17;
            run.dump_ok = sim.bridge_wait_rack(&run.dump[0]);
            for (uint32_t i = 1; i < size && run.dump_ok; i++)
                run.dump_ok = sim.bridge_read(i, &run.dump[i]);
            sim.s->core_config &= ~(1u << 17);
            check(run.dump_ok, "the deferred dump completes after the pause");
            bool same = run.dump_ok;
            for (uint32_t i = 0; i < size && same; i++)
                same = sim.bsram(i) == run.dump[i];
            check(same, "the completed dump equals the SRAM");
        }
        if (pause_dump)
            sim.s->core_config &= ~(1u << 17);
        sim.ticks(20000);
    }
    run.sram.resize(size);
    for (uint32_t i = 0; i < size; i++)
        run.sram[i] = sim.bsram(i);
    if (sim.err_seen)
        printf("    error flag first written at cycle %llu (write #%llu of %llu, run began at %llu)\n",
               (unsigned long long)sim.err_at, (unsigned long long)sim.err_write,
               (unsigned long long)sim.writes, (unsigned long long)run_start);
    return run;
}

int main(int argc, char **argv) {
    uint32_t size = 0;
    long rom_size = 0;
    std::string kind;
    for (int i = 1; i < argc; i++) {
        if (!strncmp(argv[i], "+kind=", 6))
            kind = argv[i] + 6;
        if (!strncmp(argv[i], "+size=", 6))
            rom_size = atol(argv[i] + 6);
    }
    size = kind.size() > 1 ? (uint32_t)atoi(kind.c_str() + kind.find('_') + 1) * 1024 : 0;
    if (!size || !rom_size) {
        printf("usage: gamesave +rom=<hex> +size=<n> +kind=<lorom|hirom>_<kb>\n");
        return 2;
    }
    const uint64_t RUN = size == 2048 ? 4000000 : 10000000;
    printf("%s: %u bytes of SRAM\n", kind.c_str(), size);

    printf("boot 0: dump while the game keeps running (the firmware never does this for the SNES)\n");
    Run u = boot(argc, argv, size, {}, RUN, true, false, true);
    printf("  the game's own reads %s during the unpaused dump\n",
           u.sram[0x3F0] == 0xEE ? "were disturbed" : "were not disturbed");

    printf("boot 1: blank save RAM, dump with the game paused as the firmware does\n");
    Run a = boot(argc, argv, size, {}, RUN, true, true);
    printf("  sv_core_we: %llu writes\n", (unsigned long long)a.writes);
    std::vector<uint8_t> exp(size, 0xFF);
    exp[0] = 0x5A;
    exp[1] = 0xA5;
    for (uint32_t p = 0; p < size / 256; p++)
        for (uint32_t x = (p == 0 ? 2 : 0); x < 256; x++)
            exp[p * 256 + x] = (uint8_t)(x ^ (0x3C ^ p));
    exp[0x400] = 0x11;
    exp[0x10] = 0x99;                       // the mirror write one SRAM size past the start
    check(a.sram[0] == 0x5A && a.sram[1] == 0xA5, "signature written at the cartridge's SRAM start");
    bool same = true;
    uint32_t first_bad = 0;
    for (uint32_t i = 0; i < size && same; i++)
        if (a.sram[i] != exp[i]) {
            same = false;
            first_bad = i;
        }
    if (!same)
        printf("    first mismatch at 0x%x: got %02x want %02x\n", first_bad, a.sram[first_bad], exp[first_bad]);
    check(same, "pattern, marker and mirrored write all in BSRAM (SDRAM) at the right offsets");
    check(a.writes == size + 2, "sv_core_we pulsed once per SRAM write (size + 2)");
    check(a.dump_ok && a.dump == a.sram, "the dump read through the bridge while the game ran equals the SRAM");
    check(a.sram[0x3F0] != 0xEE, "the dump did not disturb the game's own SRAM reads");

    printf("boot 2: save restored through the bridge\n");
    Run b = boot(argc, argv, size, a.sram, RUN / 2, false);
    printf("  sv_core_we: %llu writes\n", (unsigned long long)b.writes);
    check(b.sram[0x400] == 0x77, "the game read its save back (found the signature: $77 marker)");
    bool rest = true;
    for (uint32_t i = 0; i < size; i++)
        if (i != 0x400 && b.sram[i] != a.sram[i])
            rest = false;
    check(rest, "the restored save is otherwise untouched");
    check(b.writes == 1, "only the marker write was announced");

    printf(fails ? "FAILED (%d)\n" : "all passed\n", fails);
    return fails ? 1 : 0;
}
