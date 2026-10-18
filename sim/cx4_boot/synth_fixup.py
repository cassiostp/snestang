#!/usr/bin/env python3
"""Fix up GHDL `synth --out=verilog` output for CX4Map so iverilog/Verilator accept it.

1. Lowercase every identifier (GHDL keeps VHDL port case: CX4Map's formals
   are uppercase but snestang's main.v binds them lowercase). No string
   literals exist in the output, but strings/comments are still preserved.
2. Rename whole-word `do` to `DO` (main.v binds `.DO(CX4_DO)`).
3. Drop GHDL 5.0.1's duplicate `wire` declarations (data_rom_q,
   data_ram_q_a/b are emitted twice in module cx4): keeping the first
   declaration of an identical (name, width) wire is semantics-preserving.
"""
import re
import sys

src_path, dst_path = sys.argv[1], sys.argv[2]
src = open(src_path).read()

# Split into code vs strings/comments so only code is touched.
parts = []
i, n = 0, len(src)
cur = []
while i < n:
    if src.startswith('//', i):
        parts.append(('code', ''.join(cur)))
        cur = []
        j = src.find('\n', i)
        j = n if j < 0 else j
        parts.append(('other', src[i:j]))
        i = j
    elif src.startswith('/*', i):
        parts.append(('code', ''.join(cur)))
        cur = []
        j = src.find('*/', i)
        j = n if j + 2 < 0 else j + 2
        parts.append(('other', src[i:j]))
        i = j
    elif src[i] == '"':
        parts.append(('code', ''.join(cur)))
        cur = []
        j = i + 1
        while j < n and src[j] != '"':
            j += 2 if src[j] == '\\' else 1
        parts.append(('other', src[i:j + 1]))
        i = j + 1
    else:
        cur.append(src[i])
        i += 1
parts.append(('code', ''.join(cur)))

out = []
for kind, text in parts:
    if kind == 'code':
        text = text.lower()
        text = re.sub(r'(?<![A-Za-z0-9_\$])do(?![A-Za-z0-9_\$])', 'DO', text)
    out.append(text)
code = ''.join(out)

# Dedupe identical wire declarations per module, and drop GHDL 5.0.1's
# spurious self-assignments (`assign foo = foo;` for RAM-output signals):
# the RAM instance output already drives the net, so the extra driver is
# a combinational loop that simulates as X (and would contend in any
# simulator; Gowin never sees this file, it synthesizes the VHDL).
selfassign_re = re.compile(r'^\s*assign\s+(\S+)\s*=\s*(\S+)\s*;\s*(//.*)?$')
lines = code.splitlines(True)
result = []
mod_decls = None
mod_name = None
decl_re = re.compile(r'^(\s*(?:wire|reg|localparam)\b)(\s*(?:signed|unsigned)?\s*(?:\[[^\]]+\]\s*)?)(\S+?)(\s*(?:=.*)?;)\s*$')
for ln in lines:
    m = re.match(r'^\s*module\s+(\S+)', ln)
    if m:
        mod_name = m.group(1)
        mod_decls = {}
        result.append(ln)
        continue
    if mod_decls is not None and ln.strip().startswith('endmodule'):
        mod_name = None
        mod_decls = None
        result.append(ln)
        continue
    if mod_decls is not None:
        sm = selfassign_re.match(ln.rstrip('\n'))
        if sm and sm.group(1) == sm.group(2):
            print('drop self-assign in %s: %s' % (mod_name, ln.strip()))
            continue
    if mod_decls is not None:
        dm = decl_re.match(ln.rstrip('\n'))
        if dm and '=' not in (dm.group(4) or ''):
            key = (dm.group(3), re.sub(r'\s+', '', dm.group(2) or ''))
            if key in mod_decls:
                print('drop duplicate decl in %s: %s' % (mod_name, ln.strip()))
                continue
            mod_decls[key] = True
    result.append(ln)

open(dst_path, 'w').write(''.join(result).replace('module cx4map', 'module CX4Map', 1))
print('wrote %s' % dst_path)
