# gsu_boot

Full-system Super FX (GSU) boot check. PeterLemon's
`GSU2BPP256x192FillPoly` demo (freely distributable homebrew, fetched by
`run.sh` into `build/`, never committed) runs on the whole `snestang_top`
Verilator model: ROM streamed through the real loader/`smc_parser`, GSU
selected as `rom_type` 0x70, SDRAM behind `src/verilator/sdram_sim.v`.

The demo's GSU program fills the 256x192 2bpp screen in GSU RAM, copies
its scan tables from ROM to RAM, plots a filled diamond from those
tables, flushes the pixel cache and STOPs. `check.py` requires the
copied tables to be byte-identical to the ROM and the decoded picture
to match the span tables pixel-for-pixel, so the run covers the GSU ROM
fetch through the CPU2 word cache (`ROM_WAIT` stall), back-to-back GSU
RAM byte writes through the save-RAM bridge FIFO (`RAM_WAIT` stall),
GSU RAM reads, pixel-cache read-modify-write flushes, and the 192-line
`GetCharOffset` char-row term. Run with `./run.sh` (see its header;
`PETERLEMON_DIR` points at an existing PeterLemon/SNES clone to run
offline).
