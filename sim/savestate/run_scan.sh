#!/bin/sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
mkdir -p sim/savestate/build
python3 - <<'PY'
import json
from pathlib import Path
nodes=json.load(open('src/ss_scan_map.json'))
counts=[sum(n['module']==m for n in nodes) for m in ['ppu.v','dsp.v','cpu.v']]
Path('sim/savestate/build/scan_sizes.vh').write_text('localparam SCAN_COUNT=%d, PPU_END=%d, DSP_END=%d;\n'%(len(nodes),counts[0]-1,counts[0]+counts[1]-1))
lines=['integer fixture_i;','initial begin',' for(fixture_i=0;fixture_i<8192;fixture_i=fixture_i+1)index_of[fixture_i]=-1;']
for i,n in enumerate(nodes):lines.append(" index_of[13'h%04x]=%d;"%(n['address'],i))
lines+=['end','']
Path('sim/savestate/build/scan_fixture.vh').write_text('\n'.join(lines))
PY
${DOCKER_RUN:-simrun} --name "${SIM_PREFIX:-r6i66_r3}_scan" --user "$(id -u):$(id -g)" \
 -v "$root:/w" -w /w --entrypoint sh tangcore-iv:1 -c \
 'iverilog -g2012 -I src -I sim/savestate/build -s tb_scan -o sim/savestate/build/scan.out sim/savestate/tb_scan.v src/savestate.v && vvp sim/savestate/build/scan.out'
