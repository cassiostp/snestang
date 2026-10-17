# sim/spc700_shift: SPC700 shift/rotate regression bench

Runs `src/spc700/spc700.v` alone against a C++ async RAM and checks every
ASL/ROL/LSR/ROR form (`dp`, `!abs`, `dp+X`, `A`): the result byte, A, and
the C/Z/N flags, over several input/carry combinations. Each case first
poisons the core's T scratch register (`mov $20,#$3C`), so a shift whose
microcode feeds the ALU from T instead of the addressed memory byte fails
instead of passing by accident.

Regression covered: ROL `!a` (0x2C), LSR `!a` (0x4C) and ROR `!a` (0x6C)
carried `busCtrl=5'b10000` in their ALU microinstruction
(`src/spc700/mcode.txt`), which routes DB — the ALU's shift operand —
to T instead of `D_IN`; the three shifted stale T (typically 0x00) and
wrote that back to memory. In Zelda 3's SPC driver the allocator's
channel-search bitmask (`lsr $03c1`) died on its first shift, so Port3
(and shifted-bit Port2) sound effects silently never played.

Run (from this directory, inside the container):

```
docker run --rm --entrypoint sh --name snesrain_spcshift \
  --user $(id -u):$(id -g) -v <repo>:/w -w /w/sim/spc700_shift \
  verilator/verilator:latest run.sh
```

Exit code 0 means all checks passed.
