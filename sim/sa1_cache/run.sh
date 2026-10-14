#!/bin/sh
# sa1_rom_cache + bwram_256k sim (iverilog). From this directory:  ./run.sh
set -e
cd "$(dirname "$0")"
iverilog -g2012 -o tb_sa1_cache.out tb_sa1_cache.v ../../src/sa1_rom_cache.v ../../src/bwram_256k.v
echo "-- interleaved streams with jumps (stress)"
vvp tb_sa1_cache.out > tb_sa1_cache.log && grep -E '^cache:|^bwram:|PASS|FAIL' tb_sa1_cache.log
grep -q "tb_sa1_cache: PASS" tb_sa1_cache.log
echo "-- pure sequential (SA-1 code fetch rate)"
vvp tb_sa1_cache.out +SEQ > tb_sa1_cache_seq.log && grep -E '^cache:|PASS|FAIL' tb_sa1_cache_seq.log
grep -q "tb_sa1_cache: PASS" tb_sa1_cache_seq.log
