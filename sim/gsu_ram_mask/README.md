# Super FX physical RAM size

Run `CONTAINER_PREFIX=<task> sh run.sh` on the host (Python 3 and Docker).
The test extracts the ROM metadata logic from the actual top, and drives the
actual GSU mapper with a stub GSU address generator. Synthetic header bytes
cover legacy 32 KiB, extended 32/64/128 KiB, ordinary SRAM size, reloads and
retention after loading. Upper-bank addresses stay distinct for 128 KiB carts.
No game data is used.
