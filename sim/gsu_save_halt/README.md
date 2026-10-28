# gsu_save_halt: save-channel bytes in enable-low windows vs the GSU

`tb.v` drives the real save-RAM bridge (extracted from
`src/snestang_top.v` by `../bsram_bridge/extract.py`, with
`bs_save_allow` driven by the top's gate `~enable & (pause | ~loaded)`, with both window kinds modelled: the per-frame halt (enable low, pause clear) and the firmware pause (held until the pending byte acks)
against two behavioural cartridge masters while save-channel dump
reads or restore writes stream one toggle at a time, the way iosys
sends them:

- A GSU master implementing the RAM-bus output equations of
  `src/chip/GSU/GSU.v`: `RAM_ACCESS_CNT` (3 at CLS=1, 1 at CLS=0),
  the negedge-sampled `EN`, `RAM_WAIT` holding every completion,
  and the combinational `RAM_CE_N`/`RAM_WE_N` with their `~ENABLE`
  forcing (CE asserted, WE deasserted). It runs byte/word LOAD and
  SAVE and the PCF read-modify-write in both RAM banks (mirrored
  low bank, SDRAM high bank).
- An S-CPU master with the console's fixed sample point (BSRAM_Q
  sampled 6 enabled mclk after presentation (the bsram_bridge #65 sample point for this controller model), no wait input), for
  plain cartridges and for a GSU cartridge with the GSU idle.

Each access crosses an enable-low window (the per-frame HDMI halt
or a long firmware pause) at every phase offset in the sweep, and a
golden memory checks every sampled byte, every landed write in the
SDRAM image, and every streamed save byte. The SDRAM controller is
the bsram_bridge fixed-delay model; `run.sh` takes delay values.

Run on the host:

```sh
SIM_PREFIX=<task> sh run.sh [DELAY ...]
```

Exit code 0 with a `PASS` line per delay means no access was
corrupted at any swept phase. TangCore issue #71.
