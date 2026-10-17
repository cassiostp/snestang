# sim/framelock: frame-sync halt-lock timing

`tb_snes_framelock.v` runs the real `snes2hdmi` halt-lock at the
native 1647-clock HDMI line against a behavioral SNES with the real
1364-master-clock scanline (1360 on line 240 of odd frames). It runs
both boards' master clocks in 262-line mode (the lock must hold: one
SNES frame and one halt per HDMI frame) and in interlaced 263/262-line
mode plus a slow-crystal case (the SNES free-runs slower than HDMI, so
the lock cannot hold: the SNES must keep running freely, and no halt
may stretch to a whole frame).

`./run.sh [standard|hz120|both]` runs both build variants (default: both).
The hz120 variant locks the 855-clock 480p120 line at twice the game rate:
11 SNES frames and 11 halts over 22 HDMI frames where it locks; console60k
free-runs slower than 60.1504 Hz and cannot lock this rate, so its 262-line
case runs unlocked.

Run (from this directory, inside the container):

```
docker run --rm --name snesline_framelock --user $(id -u):$(id -g) -v <repo>:/w -w /w/sim/framelock tangcore-iv:1 sh run.sh
```

Exit code 0 with `PASS` lines for all five configurations means the
lock held where it can and never stalled where it cannot.
