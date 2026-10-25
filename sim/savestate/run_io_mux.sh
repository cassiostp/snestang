#!/bin/sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
python3 sim/savestate/check_io_mux.py
${DOCKER_RUN:-simrun} --name "${SIM_PREFIX:-r6i66}_io_mux" --user "$(id -u):$(id -g)" \
 -v "$root:/w" -w /w --entrypoint sh tangcore-iv:1 -c '
 set -e
 iverilog -g2012 -s tb_io_mux -o sim/savestate/build/io.out sim/savestate/build/tb_io_mux.v
 vvp sim/savestate/build/io.out
 iverilog -g2012 -s tb_io_mux -o sim/savestate/build/io-mutant.out sim/savestate/build/tb_io_mux_mutant.v
 if vvp sim/savestate/build/io-mutant.out > sim/savestate/build/io-mutant.log 2>&1; then
  echo "FAIL: inverted-select negative control passed"; exit 1
 fi
 echo "PASS: inverted-select negative control was rejected"
 '
