# sim/framelock: frame-sync halt-lock timing

`tb_snes_framelock.v` runs the real `snes2hdmi` halt-lock at the
480p120 native line (855 pixel clocks, 525 rows, 54 MHz) against a
behavioral SNES with the real 1364-master-clock scanline (1360 on line
240 of odd frames). The lock shows each game frame on two HDMI frames
and halts once per game frame.

console138k's master clock (~21.505 MHz, free-run ~60.177 Hz) locks
60.1504 Hz. console60k (~21.484 MHz) free-runs slower than that, so
it cannot lock this line length: the SNES must keep running, and no
halt may stretch to a whole frame. Interlaced 263/262-line mode and a
slow crystal are the same free-run case.

Run (from this directory, inside the container):

```
docker run --rm --name snesline_framelock --user $(id -u):$(id -g) -v <repo>:/w -w /w/sim/framelock tangcore-iv:1 sh run.sh
```

Exit code 0 with `PASS` lines for all five configurations means the
lock held where it can and never stalled where it cannot.
