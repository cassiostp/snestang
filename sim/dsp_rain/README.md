# sim/dsp_rain: S-DSP rain-scene testbench

Drives `src/dsp.v` the way Zelda: A Link to the Past's opening does and
checks the voices still produce output:

* rain: looped noise on voice 1 (`NON` + `FLG` noise rate);
* music: looped BRR on voice 0;
* sfx: one-shot BRR keyed on while the noise runs;
* pmon: a pitch-modulated voice driven by a silent negative-DC voice.

What it checks (`tb_dsp.cpp`, Verilator `--exe` main, ARAM modelled in C++,
DSP registers poked through the SMP `$F2`/`$F3` protocol):

* music voice audible alone; rain noise audible; music mean preserved once
  the noise runs (noise does not mute other voices);
* one-shot SFX keyed on during rain shows up in the mix (mean shift);
* `ENDX` sticky bit sets on BRR block end (looped voice 0, one-shot
  voice 4) — regression test for the `BRR_END` pending-bit fix;
* `TPITCH` of the PMON voice settles at 32 with a -32512 modulator and
  0x1000 base pitch — regression test for the signed-shift (`>>>`) fix;
* `FLG` mute silences / unmute recovers; echo (`EON`, `ESA`, `EDL`, FIR)
  spot check stays audible.

Run (from this directory, inside the container):

```
docker run --rm --entrypoint sh --name qa2rain_dsp \
  --user $(id -u):$(id -g) -v <repo>:/w -w /w/sim/dsp_rain \
  verilator/verilator:latest run.sh
```

Exit code 0 means all checks passed.

With `TB_DUMP=1` the run also prints an S0 trace of the DSP's ARAM
reads (addresses, data, DIR state) plus per-sample internals for the
start of the rain capture — useful when triaging a failure.
