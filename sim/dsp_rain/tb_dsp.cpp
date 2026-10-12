// tb_dsp.cpp -- S-DSP rain-scene testbench (Verilator, --exe main).
//
// Drives src/dsp.v the way Zelda:ALttP's opening does:
//   * rain  = looped noise on voice 1 (NON + FLG noise rate),
//   * music = looped BRR on voice 0,
//   * sfx   = one-shot BRR keyed on while the noise runs,
//   * pmon  = a PMON-modulated voice driven by a (silent) negative-DC voice.
//
// Checks:
//   1. Other voices still produce output while noise is on (rain coexistence).
//   2. A one-shot SFX keyed on during rain shows up in the mix (mean shift).
//   3. ENDX sticky bit is set when a BRR block ends (looped and one-shot).
//      (pre-fix RTL: ENDX stuck at 0 -- VOLL set ENDX_BUF directly and the
//      VOLR merge `ENDX_BUF <= ENDX | BRR_END` with BRR_END==0 clobbered it.)
//   4. Pitch modulation uses the SIGNED previous-voice output: with a
//      constant negative modulator and base pitch 0x1000, TPITCH must settle
//      at 32, not 8224 (pre-fix RTL used logical `>>` instead of `>>>`).
//   5. FLG mute/reset bits and an EON/echo spot check.
//
// Exit code 0 on success, 1 on any failure. Prints measured numbers.
#include "VDSP.h"
#include "VDSP___024root.h"

#include "verilated.h"

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>

static VDSP* dut;
static uint64_t ticks = 0;
static uint8_t aram[65536];

// Internal probes via the Verilator root struct (names are
// Verilator-version sensitive; a rename fails loudly at compile time).
#define SUBSTEP_CNT (dut->rootp->DSP__DOT__SUBSTEP_CNT)
#define STEP_CNT (dut->rootp->DSP__DOT__STEP_CNT)
#define TPITCH (dut->rootp->DSP__DOT__TPITCH)
#define ENDX (dut->rootp->DSP__DOT__ENDX)

static void tick() {
    // Async ARAM: present data for the settled (pre-edge) address, so the
    // design captures (RS, data) from the SAME state, like real SRAM. (A
    // previous version sampled RAM_A after the posedge, skewing every read
    // by one state.)
    dut->RAM_Q = aram[dut->RAM_A & 0xffff];
    dut->CLK = 1;
    dut->eval();
    if (!dut->RAM_WE_N && !dut->RAM_CE_N) aram[dut->RAM_A & 0xffff] = dut->RAM_D & 0xff;
    dut->CLK = 0;
    dut->eval();
    ++ticks;
}

// Hold SMP_A/SMP_DO/WE_N across one full SUBSTEP==3 window so the DSP
// captures the access on its CE edge.
static void smp_window() {
    while (SUBSTEP_CNT == 3) tick();
    while (SUBSTEP_CNT != 3) tick();
    while (SUBSTEP_CNT == 3) tick();
}

static void dsp_write(uint8_t reg_, uint8_t val) {
    dut->SMP_A = 0x00f2;
    dut->SMP_DO = reg_;
    dut->SMP_WE_N = 0;
    smp_window();
    dut->SMP_A = 0x00f3;
    dut->SMP_DO = val;
    smp_window();
    dut->SMP_WE_N = 1;
    tick();
}

static int failures = 0;
static void check(bool ok, const char* name, const char* detail) {
    if (ok) {
        printf("PASS %-28s %s\n", name, detail);
    } else {
        printf("FAIL %-28s %s\n", name, detail);
        ++failures;
    }
}

static void wait_samples(int n) {
    int prev = 0;
    while (n > 0) {
        tick();
        int rdy = dut->SND_RDY ? 1 : 0;
        if (rdy && !prev) --n;
        prev = rdy;
    }
}

struct Caps {
    std::vector<int> l, r;
};

static Caps capture(int n, int dump = 0) {
    Caps c;
    c.l.reserve(n);
    c.r.reserve(n);
    int prev = 0;
    int last_noise = -1, last_change = 0;
    while ((int)c.l.size() < n) {
        tick();
        int rdy = dut->SND_RDY ? 1 : 0;
        if (rdy && !prev) {
            int16_t l = (int16_t)(dut->AUDIO_L & 0xffff);
            c.l.push_back(l);
            c.r.push_back((int16_t)(dut->AUDIO_R & 0xffff));
            int noise = dut->rootp->DSP__DOT__NOISE & 0x7fff;
            if ((dump & 1) && (int)c.l.size() <= 128) {
                int16_t ns = noise;
                if (ns & 0x4000) ns |= (int16_t)0x8000;
                printf("DBG s[%d]=%d NOISE=%d ENV0=%d ENV1=%d TOUT=%d\n",
                       (int)c.l.size() - 1, (int)l, (int)ns,
                       (int)(dut->rootp->DSP__DOT__ENV[0] & 0xfff),
                       (int)(dut->rootp->DSP__DOT__ENV[1] & 0xfff),
                       (int)(int16_t)(dut->rootp->DSP__DOT__TOUT & 0xffff));
            }
            if (dump & 2) {
                if (noise != last_noise) {
                    if (last_noise >= 0)
                        printf("DBG noise %d -> %d at s[%d] (hold %d)\n", last_noise,
                               noise, (int)c.l.size() - 1, (int)c.l.size() - 1 - last_change);
                    last_noise = noise;
                    last_change = (int)c.l.size() - 1;
                }
            }
        }
        prev = rdy;
    }
    return c;
}

static double mean(const std::vector<int>& v) {
    double s = 0;
    for (int x : v) s += x;
    return s / (double)v.size();
}

static double rms(const std::vector<int>& v) {
    double s = 0;
    for (int x : v) s += (double)x * x;
    return sqrt(s / (double)v.size());
}

static char buf[256];

// voice register helpers: VOLL 0x0, VOLR 0x1, PITCHL 0x2, PITCHH 0x3,
// SRCN 0x4, ADSR1 0x5, GAIN 0x7
static void voice_cfg(int v, uint8_t vol, uint16_t pitch, uint8_t srcn) {
    dsp_write(0x00 | (v << 4), vol);
    dsp_write(0x01 | (v << 4), vol);
    dsp_write(0x02 | (v << 4), pitch & 0xff);
    dsp_write(0x03 | (v << 4), (pitch >> 8) & 0x3f);
    dsp_write(0x04 | (v << 4), srcn);
    dsp_write(0x05 | (v << 4), 0x00); // GAIN mode (direct)
    dsp_write(0x07 | (v << 4), 0x7f); // direct envelope, near max
}

static void globals(uint8_t non, uint8_t flg) {
    dsp_write(0x0c, 0x40); // MVOLL
    dsp_write(0x1c, 0x40); // MVOLR
    dsp_write(0x2c, 0x00); // EVOLL
    dsp_write(0x3c, 0x00); // EVOLR
    dsp_write(0x0d, 0x00); // EFB
    dsp_write(0x2d, 0x00); // PMON
    dsp_write(0x4d, 0x00); // EON
    dsp_write(0x5d, 0x02); // DIR -> 0x0200
    dsp_write(0x6d, 0x00); // ESA
    dsp_write(0x7d, 0x00); // EDL
    for (int k = 0; k < 8; ++k) dsp_write(0x0f + k * 0x10, 0x00); // FIR
    dsp_write(0x5c, 0x00); // KOFF
    dsp_write(0x3d, non);  // NON
    dsp_write(0x6c, flg);  // FLG
}

// Fresh DUT + ARAM contents. DIR at 0x0200.
//   srcn1 -> 0x0300 looped AC BRR (music)
//   srcn2 -> 0x0320 looped DC-negative BRR (silent PM modulator)
//   srcn3 -> 0x0340 looped AC BRR (PMON sfx voice sample)
//   srcn4 -> 0x0360 one-shot DC BRR, 8 blocks (sfx under rain)
static void fresh() {
    dut->RST_N = 0;
    dut->ENABLE = 1;
    dut->PAL = 0;
    dut->SMP_A = 0x00f2;
    dut->SMP_DO = 0;
    dut->SMP_WE_N = 1;
    dut->DBG_REG = 0;
    dut->DBG_DAT_IN = 0;
    dut->DBG_DAT_WR = 0;
    for (int i = 0; i < 60; ++i) tick();
    dut->RST_N = 1;
    for (int i = 0; i < 20; ++i) tick();

    for (int i = 0; i < 65536; ++i) aram[i] = 0;
    // DIR entries are 4 bytes: START_LO/HI then LOOP_LO/HI. The DSP reads
    // START (+0) while a voice KON-countdowns and LOOP (+2) while it plays,
    // so both must point at the sample (loop to start here).
    aram[0x200 + 1 * 4 + 0] = 0x00;
    aram[0x200 + 1 * 4 + 1] = 0x03;
    aram[0x200 + 1 * 4 + 2] = 0x00;
    aram[0x200 + 1 * 4 + 3] = 0x03;
    aram[0x200 + 2 * 4 + 0] = 0x20;
    aram[0x200 + 2 * 4 + 1] = 0x03;
    aram[0x200 + 2 * 4 + 2] = 0x20;
    aram[0x200 + 2 * 4 + 3] = 0x03;
    aram[0x200 + 3 * 4 + 0] = 0x40;
    aram[0x200 + 3 * 4 + 1] = 0x03;
    aram[0x200 + 3 * 4 + 2] = 0x40;
    aram[0x200 + 3 * 4 + 3] = 0x03;
    aram[0x200 + 4 * 4 + 0] = 0x60;
    aram[0x200 + 4 * 4 + 1] = 0x03;
    aram[0x200 + 4 * 4 + 2] = 0x60;
    aram[0x200 + 4 * 4 + 3] = 0x03;
    // srcn1: looped AC (nibbles +1/-2)
    aram[0x300] = 0xc3;
    for (int i = 0; i < 8; i += 2) {
        aram[0x301 + i] = 0x11;
        aram[0x302 + i] = 0xee;
    }
    // srcn2: looped DC negative (nibbles -8)
    aram[0x320] = 0xc3;
    for (int i = 0; i < 8; ++i) aram[0x321 + i] = 0x88;
    // srcn3: looped AC (nibbles +2/-3)
    aram[0x340] = 0xc3;
    for (int i = 0; i < 8; i += 2) {
        aram[0x341 + i] = 0x22;
        aram[0x342 + i] = 0xdd;
    }
    // srcn4: one-shot DC (+2), 8 blocks, end bit on last only
    for (int b = 0; b < 8; ++b) {
        aram[0x360 + b * 9] = (b == 7) ? 0xc1 : 0xc0;
        for (int i = 1; i < 9; ++i) aram[0x360 + b * 9 + i] = 0x22;
    }

    for (int r = 0; r < 128; ++r) dsp_write(r, 0x00);
}

// Sample TPITCH just after voice v's IS_ENV update.
// IS_ENV for voices 1..7 fires at STEP==3*v-2? No: voice1@STEP1,
// voice2@STEP4, voice3@STEP7, ... (every 3 steps), SUBSTEP==2.
// Read once SUBSTEP has advanced to 3.
static int sample_tpitch(int v) {
    int step = (v == 0) ? 30 : 3 * v - 2;
    while (!((int)STEP_CNT == step && (int)SUBSTEP_CNT == 3)) tick();
    return TPITCH & 0x7fff;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    dut = new VDSP;

    // ---- S0: watch DIR/BRR reads for a few periods (TB_DUMP trace) ----
    if (getenv("TB_DUMP")) {
        fresh();
        globals(0x00, 0x30);
        voice_cfg(0, 0x20, 0x1000, 1);
        dsp_write(0x4c, 0x01);
        int seen = 0;
        int last_key = -1;
        while (seen < 30) {
            tick();
            int st = (int)STEP_CNT, su = (int)SUBSTEP_CNT;
            int key = -1;
            if ((st == 0 || st == 21) && su <= 1) key = st * 4 + su;
            else if (st == 1 && su == 1) key = 100;
            if (key >= 0 && key != last_key) {
                last_key = key;
                printf("DBG watch STEP=%d SUB=%d RS=%d RAM_A=0x%04x RAM_Q=0x%02x TDIRA=0x%04x NXTA=0x%04x HDR=%02x REGS_DO=%02x\n",
                       st, su, (int)(dut->rootp->DSP__DOT__RS & 0xf), dut->RAM_A & 0xffff,
                       dut->RAM_Q & 0xff, (int)(dut->rootp->DSP__DOT__TDIR_ADDR & 0xffff),
                       (int)(dut->rootp->DSP__DOT__BRR_NEXT_ADDR & 0xffff),
                       (int)(dut->rootp->DSP__DOT__TBRRHDR & 0xff),
                       (int)(dut->rootp->DSP__DOT__REGS_DO & 0xff));
                ++seen;
            }
        }
    }

    // ---- S1: music voice alone (looped BRR, voice 0) ----
    fresh();
    globals(0x00, 0x30); // no noise, FLG = ECEN + rate 16
    voice_cfg(0, 0x20, 0x1000, 1);
    dsp_write(0x4c, 0x01); // KON voice 0
    wait_samples(300);
    Caps r0 = capture(3000);
    double m0 = mean(r0.l), q0 = rms(r0.l);
    snprintf(buf, sizeof buf, "mean=%+.1f rms=%.1f", m0, q0);
    check(q0 > 150.0, "music-voice-audible", buf);

    // ---- S3: rain (looped noise, voice 1) + music ----
    fresh();
    globals(0x02, 0x30); // NON bit1, FLG = ECEN + rate 16
    voice_cfg(0, 0x20, 0x1000, 1);
    voice_cfg(1, 0x20, 0x1000, 1); // noise voice sample data irrelevant
    dsp_write(0x4c, 0x03);         // KON voices 0+1
    wait_samples(300);
    Caps r01 = capture(4000, getenv("TB_DUMP") ? 3 : 0);
    double m01 = mean(r01.l), q01 = rms(r01.l);
    snprintf(buf, sizeof buf, "mean=%+.1f rms=%.1f (music mean=%+.1f)", m01, q01, m0);
    check(q01 > 1500.0, "rain-noise-audible", buf);
    snprintf(buf, sizeof buf, "dmean=%+.1f (tol 400)", m01 - m0);
    check(fabs(m01 - m0) < 400.0, "music-survives-rain", buf);
    int endx_rain = ENDX & 0xff;
    snprintf(buf, sizeof buf, "ENDX=0x%02x (want bit0 set)", endx_rain);
    check((endx_rain & 0x01) != 0, "endx-looped-voice", buf);

    // ---- S3b: noise voice alone (isolate the noise path gain) ----
    fresh();
    globals(0x02, 0x30);
    voice_cfg(0, 0x00, 0x1000, 1); // silent
    voice_cfg(1, 0x20, 0x1000, 1);
    dsp_write(0x4c, 0x02);
    wait_samples(300);
    Caps r1 = capture(2000, 0);
    snprintf(buf, sizeof buf, "mean=%+.1f rms=%.1f", mean(r1.l), rms(r1.l));
    check(rms(r1.l) > 500.0, "noise-alone-audible", buf);

    // ---- S3c: rain must SUSTAIN (regression: voices dying mid-play) ----
    fresh();
    globals(0x02, 0x30);
    voice_cfg(0, 0x20, 0x1000, 1);
    voice_cfg(1, 0x20, 0x1000, 1);
    dsp_write(0x4c, 0x03);
    double qmin = 1e9;
    for (int w = 0; w < 8; ++w) {
        wait_samples(100);
        Caps cw = capture(400);
        double qw = rms(cw.l);
        if (qw < qmin) qmin = qw;
        printf("INFO w%d rms=%.1f ENV0=%d ENV1=%d EM0=%d EM1=%d KONCNT=%d%d TKON=0x%02x WKON=0x%02x TDIR=%02x TSRCN=%02x TDIRA=0x%04x BRR_AD1=0x%04x NXTA=0x%04x HDR=%02x ENDX=0x%02x\n",
               w, rms(cw.l), (int)(dut->rootp->DSP__DOT__ENV[0] & 0xfff),
               (int)(dut->rootp->DSP__DOT__ENV[1] & 0xfff),
               (int)(dut->rootp->DSP__DOT__ENV_MODE[0] & 3),
               (int)(dut->rootp->DSP__DOT__ENV_MODE[1] & 3),
               (int)(dut->rootp->DSP__DOT__KON_CNT[0] & 7),
               (int)(dut->rootp->DSP__DOT__KON_CNT[1] & 7),
               (int)(dut->rootp->DSP__DOT__TKON & 0xff),
               (int)(dut->rootp->DSP__DOT__WKON & 0xff),
               (int)(dut->rootp->DSP__DOT__TDIR & 0xff),
               (int)(dut->rootp->DSP__DOT__TSRCN & 0xff),
               (int)(dut->rootp->DSP__DOT__TDIR_ADDR & 0xffff),
               (int)(dut->rootp->DSP__DOT__BRR_ADDR[1] & 0xffff),
               (int)(dut->rootp->DSP__DOT__BRR_NEXT_ADDR & 0xffff),
               (int)(dut->rootp->DSP__DOT__TBRRHDR & 0xff), (int)(ENDX & 0xff));
    }
    snprintf(buf, sizeof buf, "min window rms=%.1f (want >400)", qmin);
    check(qmin > 400.0, "rain-sustained", buf);

    // ---- S4: one-shot SFX keyed on during rain ----
    // voice 4: one-shot DC, 8 blocks, pitch 0x0200 (~1024 samples long)
    voice_cfg(4, 0x20, 0x0200, 4);
    dsp_write(0x4c, 0x10); // KON voice 4 (additive: WKON latches bit4)
    wait_samples(100);
    Caps r014 = capture(800);
    double m014 = mean(r014.l);
    snprintf(buf, sizeof buf, "dmean=%+.1f (want +400..+1600)", m014 - m01);
    check(m014 - m01 > 400.0 && m014 - m01 < 1600.0, "sfx-during-rain", buf);
    wait_samples(1500); // let the one-shot finish (release)
    int endx_sfx = ENDX & 0xff;
    snprintf(buf, sizeof buf, "ENDX=0x%02x (want bit4 set)", endx_sfx);
    check((endx_sfx & 0x10) != 0, "endx-oneshot-voice", buf);

    // ---- S2: PMON voice with negative-DC modulator ----
    fresh();
    globals(0x00, 0x30);
    voice_cfg(2, 0x00, 0x1000, 2); // silent (-DC) modulator
    voice_cfg(3, 0x20, 0x1000, 3); // PMON sfx voice, looped AC
    dsp_write(0x2d, 0x08);         // PMON bit3: voice 3 by voice 2
    dsp_write(0x4c, 0x0c);         // KON voices 2+3
    wait_samples(15);
    int tp0 = sample_tpitch(3), tp1 = sample_tpitch(3), tp2 = sample_tpitch(3);
    // modulator TOUT = -32512: arith (-32512>>>5)=-1016,
    // delta = (-1016*0x1000)>>>10 = -4064 -> TPITCH = 4096-4064 = 32.
    // (logical `>>` gave (1032*0x1000)>>10 = +4128 -> 8224.)
    snprintf(buf, sizeof buf, "TPITCH=%d,%d,%d (want 32,32,32)", tp0, tp1, tp2);
    check(tp0 == 32 && tp1 == 32 && tp2 == 32, "pmon-signed-modulator", buf);
    Caps r23 = capture(2000);
    double q23 = rms(r23.l);
    snprintf(buf, sizeof buf, "rms=%.1f", q23);
    check(q23 > 150.0, "pmon-voice-audible", buf);

    // ---- S5: FLG mute/reset sanity ----
    fresh();
    globals(0x00, 0x30);
    voice_cfg(0, 0x20, 0x1000, 1);
    dsp_write(0x4c, 0x01);
    wait_samples(300);
    dsp_write(0x6c, 0x70); // MUTE=1 + ECEN + rate 16
    wait_samples(10);
    Caps rm = capture(500);
    snprintf(buf, sizeof buf, "rms=%.1f (want <50)", rms(rm.l));
    check(rms(rm.l) < 50.0, "flg-mute-silences", buf);
    dsp_write(0x6c, 0x30); // unmute
    dsp_write(0x4c, 0x01); // re-KON after mute
    wait_samples(300);
    Caps ru = capture(500);
    if (getenv("TB_DUMP"))
        printf("DBG post-unmute MUTE=%d ENV0=%d ENDX=0x%02x BRR_AD0=0x%04x OFFS0=%d INTP0=0x%04x HDR=%02x\n",
               (int)(dut->rootp->DSP__DOT__MUTE_FLG & 1),
               (int)(dut->rootp->DSP__DOT__ENV[0] & 0xfff), (int)(ENDX & 0xff),
               (int)(dut->rootp->DSP__DOT__BRR_ADDR[0] & 0xffff),
               (int)(dut->rootp->DSP__DOT__BRR_OFFS[0] & 7),
               (int)(dut->rootp->DSP__DOT__INTERP_POS[0] & 0xffff),
               (int)(dut->rootp->DSP__DOT__TBRRHDR & 0xff));
    snprintf(buf, sizeof buf, "rms=%.1f (want >150)", rms(ru.l));
    check(rms(ru.l) > 150.0, "flg-unmute-recovers", buf);

    // FLG reset bit forces release while set; voice recovers after clear.
    dsp_write(0x6c, 0xb0); // RST=1 + ECEN + rate 16
    wait_samples(300);
    Caps rr = capture(500);
    snprintf(buf, sizeof buf, "rms=%.1f (want <50)", rms(rr.l));
    check(rms(rr.l) < 50.0, "flg-reset-silences", buf);
    dsp_write(0x6c, 0x30); // clear reset
    dsp_write(0x4c, 0x01); // re-KON after reset
    wait_samples(300);
    Caps rc = capture(500);
    snprintf(buf, sizeof buf, "rms=%.1f (want >150)", rms(rc.l));
    check(rms(rc.l) > 150.0, "flg-reset-recovers", buf);

    // ---- S6: echo spot check (EON + ECEN=0) ----
    fresh();
    globals(0x00, 0x10); // ECEN=0 (echo on), rate 16
    voice_cfg(0, 0x20, 0x1000, 1);
    dsp_write(0x4d, 0x01); // EON voice 0
    dsp_write(0x7d, 0x04); // EDL -> len 0x2000
    dsp_write(0x6d, 0x60); // ESA -> echo buf at 0x6000
    for (int k = 0; k < 8; ++k) dsp_write(0x0f + k * 0x10, 0x40); // FIR
    dsp_write(0x2c, 0x40);                                       // EVOLL
    dsp_write(0x3c, 0x40);                                       // EVOLR
    dsp_write(0x4c, 0x01);
    wait_samples(600);
    Caps re = capture(2000);
    double qe = rms(re.l);
    snprintf(buf, sizeof buf, "rms=%.1f (want >150)", qe);
    check(qe > 150.0, "echo-voice-audible", buf);

    printf("%s: %d failure(s), %llu ticks\n", failures ? "RESULT FAIL" : "RESULT PASS",
           failures, (unsigned long long)ticks);
    dut->final();
    delete dut;
    return failures ? 1 : 0;
}
