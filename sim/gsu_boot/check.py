#!/usr/bin/env python3
# Check the GSU work RAM dumped by tb_gsu_boot (bsram.bin) against the
# demo ROM: the scan-table copy at byte 12288 must equal the ROM bytes
# the GSU copied (found by searching the ROM for the copy's first 64
# bytes), and the plotted diamond decoded from the 192-line 2bpp char
# layout (srg320 GetCharOffset, ht=2) must match the span tables
# pixel-for-pixel. Usage: check.py <demo.sfc> <bsram.bin>
import struct
import sys

rom = open(sys.argv[1], "rb").read()
bs = open(sys.argv[2], "rb").read()
copy = bs[12288:12288 + 1536]
off = rom.find(copy[:64])
assert off >= 0, "scan-table copy not found in ROM"
bad = sum(1 for a, b in zip(copy, rom[off:off + 1536]) if a != b)
print(f"copy: {bad} mismatched bytes / 1536 (rom offset {off:#x})")
assert bad == 0


def charoff(offs, ht=2, md=0, bpp=0, scbr=0):
    cy, cx = (offs >> 8) & 0x1F, offs & 0x1F
    temp = (cx << 4) + (cx << 3) + cy if ht == 2 else (cx << 4) + cy
    t2 = temp << (4 if md == 0 else 5)
    return (t2 + ((scbr & 0x7F) << 10) | (((bpp >> 1) & 3) << 4)
            | (((offs >> 5) & 7) << 1) | (bpp & 1)) & 0x1FFFF


words = struct.unpack("<768H", copy)
exp = [[0] * 256 for _ in range(192)]
for i in range(63):
    for x in range(words[64 + i], words[256 + i] + 1):
        exp[64 + i][x] = 1
miss = extra = 0
for y in range(192):
    for x in range(256):
        a = charoff((y << 5) | (x >> 3))
        got = (bs[a] >> (7 - (x & 7))) & 1 if a < 12288 else 0
        if exp[y][x] and not got:
            miss += 1
        if got and not exp[y][x]:
            extra += 1
print(f"picture: missing={miss} extra={extra} of 49152 pixels")
assert miss == 0 and extra == 0
print("check.py: PASS")
