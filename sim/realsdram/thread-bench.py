#!/usr/bin/env python3
"""Benchmark real-SDRAM model threads and compare every local capture byte."""
import argparse
import filecmp
import json
import os
import re
from pathlib import Path
import shlex
import shutil
import subprocess
import time

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('rom', type=Path)
p.add_argument('output', type=Path)
p.add_argument('--frames', type=int, default=600)
a = p.parse_args()
rom, out = a.rom.resolve(), a.output.resolve()
if not rom.is_file() or a.frames < 60:
    p.error('supply a local ROM and at least 60 frames')
here = Path(__file__).resolve().parent
root = here.parent.parent
out.mkdir(parents=True, exist_ok=False)
image = subprocess.check_output(['docker', 'image', 'inspect', '--format', '{{.Id}}', 'verilator/verilator:latest'], text=True).strip()
(out / 'image.txt').write_text(image + '\n')
runner = shlex.split(os.environ.get('DOCKER_RUN', 'simrun' if shutil.which('simrun') else 'docker run --rm'))
cache = [] if any('simrun' in x for x in runner) else ['-e', 'CCACHE_DISABLE=1']
rows = []
files1 = None
for threads in (1, 2, 4, 8):
    env = os.environ.copy()
    env['VERILATOR_THREADS'] = str(threads)
    env['DUMP_ALL_FRAMES'] = '1'
    build_dir = out / 'models' / f'threads{threads}'
    env['REALSDRAM_BUILD'] = str(build_dir)
    prefix = env.get('SIM_PREFIX', 'sim' + str(os.getpid()))
    start = time.monotonic()
    with (out / f'threads{threads}-build.log').open('w') as log:
        subprocess.run(runner + cache + ['--name', prefix + '_realsdram_threads' + str(threads), '--user', f'{os.getuid()}:{os.getgid()}',
                                '-v', str(root) + ':' + str(root) + ':ro', '-v', str(out) + ':' + str(out),
                                '-w', str(here), '-e', 'REALSDRAM_BUILD=' + str(build_dir), '-e', 'VERILATOR_THREADS=' + str(threads),
                                '--entrypoint', 'sh', image, 'run.sh', 'build'],
                       env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
    compiled = [int(m.group(1)) for f in (build_dir / 'obj/obj').glob('*.cpp')
                for m in re.finditer(r'::threads\(\) const \{ return (\d+);', f.read_text())]
    if compiled != [threads]:
        raise RuntimeError(f'generated model thread count {compiled}, expected {threads}')
    build = time.monotonic() - start
    captures = out / f'threads{threads}'
    start = time.monotonic()
    with (out / f'threads{threads}-run.log').open('w') as log:
        subprocess.run(['sh', str(here / 'run.sh'), 'run', 'game', str(rom), str(a.frames), str(captures)],
                       env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
    elapsed = time.monotonic() - start
    runtime = re.search(r'model threads: (\d+)', (captures / 'game.stderr').read_text())
    if not runtime or int(runtime.group(1)) != threads:
        raise RuntimeError('runtime thread pool does not match compiled model')
    files = sorted(x.name for x in captures.glob('game*') if x.suffix in ('.ppm', '.aud', '.bin', '.log'))
    if not any(x.endswith('.ppm') for x in files) or not any(x.endswith('.aud') for x in files):
        raise RuntimeError('missing frame/audio captures')
    if not all((captures / ('game_' + name + '.bin')).is_file() for name in ('bsram', 'aram')):
        raise RuntimeError('missing BSRAM/ARAM captures')
    if threads == 1:
        files1 = files
        identical = True
    else:
        identical = files == files1 and all(filecmp.cmp(out / 'threads1' / f, captures / f, shallow=False) for f in files)
    row = dict(threads=threads, build_seconds=round(build, 2), run_seconds=round(elapsed, 2),
               identical=identical, captured_files=len(files), frames=sum(f.endswith('.ppm') for f in files),
               ram=sum(f.endswith('.bin') for f in files), audio=sum(f.endswith('.aud') for f in files), speedup=round(rows[0]['run_seconds'] / elapsed, 3) if rows else 1.0)
    rows.append(row)
    (out / 'measurements.json').write_text(json.dumps(rows, indent=2) + '\n')
    print(json.dumps(row), flush=True)
if any(not row['identical'] for row in rows):
    raise RuntimeError('capture bytes changed; leave model threading disabled')
