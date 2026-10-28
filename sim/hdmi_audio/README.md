# HDMI audio packets

From the repository root:

```sh
SIM_PREFIX=snesaudio sh sim/hdmi_audio/run.sh both
# Test a diagnostic's committed RTL with this checkout's current bench/decoder:
git fetch origin
SIM_PREFIX=snesaudio_diag sh sim/hdmi_audio/run.sh standard <commit>
# Historical source, explicitly normalized as described below:
SIM_PREFIX=snesaudio_r4 sh sim/hdmi_audio/run.sh standard 9800f11
```

The host wrapper starts Verilator through `simrun` when available, otherwise
`docker run --rm`, and decodes the result with host Python 3. Set `SIM_PREFIX`
to give the container a task-specific name. `build/` stays local and ignored.
The regression catalog includes this bench in `full`, for both variants.
The optional ref exports only `src/` from that commit; modern sources retain
their current timing/continuity checks. The historical normalization below is
applied only to the older interface without `std_timing`.

A synthetic DSP counter/complement pair runs at the real ACLK ratio and pauses
with a behavioral 262-line SNES frame. Unlike `sim/snes_audio`, this bench uses
the actual HDMI encoder, packet picker, ECC and TMDS channels. It records eight
frames of parallel TMDS symbols before the vendor serializer; no ROM is used.

`decode.py` finds islands from the emitted preambles and guard bands. It does
not use the encoder's internal mode or packet signals. It decodes TERC4,
reconstructs all five BCH blocks, checks InfoFrame checksums, the Audio
InfoFrame, N, sample-present/layout/flat bits, IEC parity and complete channel
status blocks, stereo sample payloads and continuity after acquisition. It
reports CTS values and sample counts. Initial partial CTS and acquisition-time
sample repeats are reported separately from steady operation. Expected IEC
status is consumer LPCM, stereo channel numbers 1/2, 16 bits, 32 kHz (48 kHz
for a diagnostic tree that changes `AUDIO_OUT_RATE`).
For direct-tone diagnostics it also requires both polarities and the transition
count of a 1 kHz square wave, within two transitions at the capture boundaries.

The layout follows HDMI 1.4b sections 5.2.3, 5.3.3–5.3.5, 7.2–7.3 and 8.2.2.
The library's [original source](https://github.com/hdl-util/hdmi) and AMD's
[ACR interface documentation](https://docs.amd.com/r/en-US/pg235-v-hdmi-tx-ss/Audio-Clock-Regeneration-Interface)
provide additional references. This is a functional regression, not HDMI
compliance certification or proof of a sink's physical behavior.

Two simulator accommodations are explicit:

- Verilator 5.052 rejects the ACR module's nested constant real/int casts.
  Only the generated simulation copy replaces their evaluated constants:
  74250/17 for 720p and 54000/16 for 480p120. N/CTS generation is unchanged.
- Round 4 uses a blocking `clk_audio` assignment that races its pixel-domain
  edge detectors in event simulation. The historical-source option normalizes
  that toggle and the sample latch to nonblocking/falling-edge intent, matching
  the already accepted `f234c65` transport fix. It also initializes the old
  divider/clock as power-up state. It is not an unmodified historical RTL run.
  The historical transport uses today's behavioral PPU frame, so its sample
  repeats are reported rather than asserted; current-tree continuity remains
  required after acquisition.

The scaler's frame-sync registers receive the same initial deposits as the
existing FIFO bench. The source/DSP and external SDRAM are behavioral/excluded;
this test proves transport of known samples through packetization and parallel
TMDS, not that hardware DSP samples are nonzero. Serialization, pins, PLL lock,
actual board timing and audible reception still require hardware.
