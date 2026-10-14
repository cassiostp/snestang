#!/usr/bin/env python3
"""Turn srg320's drom.mif (the CX4 data ROM) into the VHDL package that spram.vhd initialises from.

    python3 tools/mif2vhdl.py src/chip/CX4/drom.mif > src/chip/CX4/cx4_drom_pkg.vhd

GowinSynthesis has no way to initialise a VHDL RAM from a file, so the .mif ships as the
source and this constant array is what gets built. sim/cx4 checks the two are identical.
"""
import re
import sys

text = open(sys.argv[1]).read().replace("\r", "")
width = int(re.search(r"WIDTH\s*=\s*(\d+)", text).group(1))
depth = int(re.search(r"DEPTH\s*=\s*(\d+)", text).group(1))
words = dict((int(a, 16), v.upper()) for a, v in re.findall(r"^\s*([0-9A-Fa-f]+)\s*:\s*([0-9A-Fa-f]+)\s*;", text, re.M))
assert sorted(words) == list(range(depth)), "mif must give every address once"
assert all(len(v) * 4 == width for v in words.values()), "word width"

print("-- Generated from drom.mif by tools/mif2vhdl.py; do not edit.")
print("library ieee;")
print("use ieee.std_logic_1164.all;")
print()
print("package cx4_drom_pkg is")
print("\ttype cx4_drom_t is array (0 to %d) of std_logic_vector(%d downto 0);" % (depth - 1, width - 1))
print("\tconstant CX4_DROM : cx4_drom_t := (")
for i in range(depth):
    print('\t\tx"%s"%s' % (words[i], "," if i < depth - 1 else ""))
print("\t);")
print("end package;")
