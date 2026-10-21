#!/bin/sh
set -eu
DOCKER_RUN=${DOCKER_RUN:-$(command -v simrun >/dev/null 2>&1 && echo simrun || echo "docker run --rm")}
cd "$(dirname "$0")"
mkdir -p build
python3 - <<'PY'
from pathlib import Path
s=Path('../../src/snestang_top.v').read_text()
p=s.index('module gsu_ram_mask_from_rom (')
Path('build/metadata.v').write_text(s[p:])
PY
repo=$(cd ../.. && pwd)
$DOCKER_RUN --name "${SIM_PREFIX:-sim$$}_gsu_ram_mask" --user "$(id -u):$(id -g)" -v "$repo:/w" -w /w/sim/gsu_ram_mask tangcore-iv:1 sh -c 'iverilog -g2012 -s tb -o build/bench build/metadata.v ../../src/chip/GSU/GSUMap.v tb.v && vvp build/bench'
