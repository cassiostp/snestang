# SNES game-pattern sim (`sim/gamesave`)

The real core, running battery games at the real cartridge addresses.
`snestang_top` built for Verilator (65816, the cartridge decode in
`DSP_LHRomMap`, `smc_parser`, the SNES-bus edge detectors and the save/BSRAM
bridge) with the REAL `sdram_snes` controller and the co-sim's behavioral SDRAM
chip on its pins, fed a ROM image the way the firmware streams one. The save
channel is driven through the bridge's `sv_req`/`sv_rreq` toggles exactly as
iosys drives it.

```bash
./run.sh       # needs docker (Verilator) and python3; ~2 min for three games
```

`mkrom.py <lorom|hirom> <kb>` builds the cartridge: a LoROM 2 KB game (Super
Mario World's shape), a LoROM 8 KB game (A Link to the Past's) and a HiROM 8 KB
game. The 65816 code looks for a signature at the SRAM start (`$70:0000`, or
`$30:6000` for HiROM), writes a pattern over the whole SRAM, a marker at +$400
and a mirrored write one SRAM size past the start, then loops reading the
signature. With a signature present it writes only a `$77` marker.

`main.cpp` runs, per game:

- boot 0, a dump while the game keeps running, without the pause. The
  bridge defers save-channel bytes while the core runs (they only start
  while the core is held for the firmware: the pause bit, or the
  not-yet-loaded hold; the per-frame HDMI halt does not admit them), so
  the unpaused dump acks nothing and the game's own SRAM reads stay
  intact; pausing then lets the pending dump complete, and it equals the
  SRAM. (Before the deferral, the game's own SRAM read came back wrong
  within a few hundred clocks of the dump starting, because the save
  channel and the game share the controller's one BSRAM port.)
  Save-channel senders must keep the existing discipline the firmware
  already follows: `0x11` blocks only while the core is held, `0x12`
  block fetches one at a time waiting for each reply — toggles are
  consumed one at a time and must not be pipelined.
- boot 1, blank BSRAM: the writes land at the right BSRAM offsets (signature,
  pattern, marker, mirror), `sv_core_we` pulses once per SRAM write (size + 2),
  and a dump read through the bridge with the game paused equals the SRAM and
  leaves the game's reads intact.
- boot 2, the dump restored through the bridge while the core is still held in
  its loading state (the firmware's order): the game finds the signature, reads
  its save back and writes only its marker.
- boot 3 (issue #71), a churn against the restored game's signature-poll
  loop: whole dumps under firmware-style pauses, single bytes through
  pauses, and dump bytes pending across forced per-frame halts, all at
  swept phases. No save byte may be served while the game runs (halts
  included) and no poll may come back disturbed across any
  pause/resume. `+churnmode` (see `main.cpp`) isolates the shapes for
  debugging, including fine sweeps of single enable drops.

`test_loader_sim.v` replaces `src/verilator/test_loader.v`: the ROM and size
come from the command line, `loading` is held until the driver releases it, and
streaming starts after the SDRAM controller's power-up sequence (bytes sent
earlier are dropped, as on any controller still initialising).
`gamesave_top.sv` wraps `snestang_top` with the chip; the stock Verilator
SDRAM model drops a BSRAM request that lands in the same cycle as a ROM fetch,
the real controller queues it.
