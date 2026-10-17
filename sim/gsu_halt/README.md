# gsu_halt

Checks that the GSU freezes while `ENABLE` is low. `main`'s ENABLE drops
for the frame-sync halt (once per frame) and the menu pause; the S-CPU,
PPU, APU, SA-1 and CX4 all stop on it, so the GSU (and the cartridge
DSPn/OBC1 in `DSP_LHRomMap`, same wiring) must too, or it gains cycles
against the S-CPU every frame.

The bench runs the GSU on a NOP sled from ROM, drops ENABLE for 3000
clocks mid-run (SYSCLKF/R_CE keep pulsing, as `cpu.v` drives them at the
DMA rate under ~ENABLE), and requires the PC, ROM address and RAM write
strobe to be still and execution to resume after. `+FREE` holds ENABLE
high through the window as a control. Run with `./run.sh`.
