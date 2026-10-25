#!/bin/sh
# Host wrapper; the reference is prepared outside the minimal Icarus image.
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
mkdir -p sim/savestate/build
git show 292d641:src/sdram_cl2_2ch.v > sim/savestate/build/reference-source.v
sed 's/module sdram_snes/module sdram_ss_reference/' sim/savestate/build/reference-source.v > sim/savestate/build/sdram_ss_reference.v
${DOCKER_RUN:-simrun} --name "${SIM_PREFIX:-r6i66}_capture_restore" --user "$(id -u):$(id -g)" \
 -v "$root:/w" -w /w --entrypoint sh tangcore-iv:1 -c \
 'iverilog -g2012 -DSNES_SAVESTATE -s tb_capture_restore -o sim/savestate/build/capture.out sim/savestate/tb_capture_restore.v src/sdram_cl2_2ch.v sim/savestate/build/sdram_ss_reference.v && vvp sim/savestate/build/capture.out'
