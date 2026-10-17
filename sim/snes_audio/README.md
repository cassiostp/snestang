# sim/snes_audio: SNES audio transport bench

`tb_snes_audio_fifo.v` checks the 32 kHz audio path in `src/snes2hdmi.v`
against the defect in `tangcore#26` (slight crackle on high-frequency
content): the DSP overproduced relative to the HDMI audio rate, so the
16-deep FIFO sat full and ~2 samples were dropped every HDMI frame. The fix
(`ACLK_FREQ` in `src/dsp.vh` matched to the net consumption, 64-deep FIFO,
FIFO-level servo on the audio period, reset for the audio block) keeps every
sample: the bench plays 16 HDMI frames of NTSC with a counter stream and
fails unless no sample is dropped or repeated after the two-frame warmup.

Run (from this directory, inside the container):

```
docker run --rm --name snesaudio_x --user $(id -u):$(id -g) -v <repo>:/w -w /w/sim/snes_audio tangcore-iv:1 sh run.sh
```

Exit code 0 means no dropped or repeated samples (`PASS` line at the end).
The bench runs at both boards' master clocks. The per-frame table shows
produced/consumed/dropped/repeated samples, FIFO occupancy min/max and
the frame-sync halt in mclk (about 405 on console138k, 56 on console60k,
for the 357366-clock average frame; at SNES line 257 in this bench's
counting: `ys[7:0]` also matches there, after `sync_done` re-arms at
line 200).
