# BSRAM bridge regression

Extracts the actual detector, FIFO, arbiter and mirror from `snestang_top.v`.
Pass an integration baseline's top file to compare every non-GSU output clock
for plain and OBC-1 cartridges, across reads, writes, upper addresses and saves.
Then check GSU low-bank read bypass, distinct upper-bank SDRAM data, save restore,
coeval/queued save priority, and the SA-1 data mux. The synthetic controller
returns after four clocks; physical timing is covered by FPGA builds.

Run on the host (Python 3 and Docker required):

```sh
CONTAINER_PREFIX=<task> sh run.sh <baseline>/src/snestang_top.v
```

The runner uses the local `tangcore-iv:1` Icarus image with a unique container
name and the host user's UID/GID. No game data is used or generated.
