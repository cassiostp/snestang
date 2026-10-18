#!/usr/bin/env python3
"""SNES ROM -> smoke-loader .hex (host-side, ROM-derived output stays local).

test_loader streams rom[0..63] (64-byte header block for smc_parser), skips
to 512, then streams the image. Layout:
  [0..64)   : SNES header (validated by checksum/complement, LoROM 0x7FC0
              or HiROM 0xFFC0 or ExHiROM 0x40FFC0)
  [64..512) : zeros (never streamed)
  [512..]    : raw image (copier header stripped)
SIZE = 512 + imagelen. Prints SIZE=<n> for build.sh.

Usage: make_rom.py <src.sfc|src.smc> <dst.hex>
"""
import struct
import sys

src, dst = sys.argv[1], sys.argv[2]
raw = open(src, "rb").read()
print("src bytes: %d" % len(raw))
if len(raw) % 1024 == 512:
    print("stripping 512-byte copier header")
    raw = raw[512:]
print("image bytes: %d" % len(raw))

hdr = None
for off in (0x7FC0, 0xFFC0, 0x40FFC0):
    if off + 64 > len(raw):
        continue
    h = raw[off:off + 64]
    cs, cc = struct.unpack("<HH", h[0x1C:0x20])
    ok = ((cs + cc) & 0xFFFF) == 0xFFFF
    print("header @%#x: title=%r map=%#04x type=%#04x cs=%04x cc=%04x ok=%s" %
          (off, bytes(h[:21]), h[0x15], h[0x16], cs, cc, ok))
    if ok and hdr is None:
        hdr = h
if hdr is None:
    print("no valid header; falling back to LoROM offset")
    hdr = raw[0x7FC0:0x8000]
img = bytearray(512 + len(raw))
img[0:64] = hdr
img[512:] = raw
with open(dst, "w") as f:
    for b in img:
        f.write("%02x\n" % b)
print("wrote %s entries=%d" % (dst, len(img)))
print("SIZE=%d" % len(img))
