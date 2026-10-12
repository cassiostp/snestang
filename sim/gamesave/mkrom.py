#!/usr/bin/env python3
"""Build a test ROM for the SNES game-pattern sim: a battery game that does
what Super Mario World (LoROM, 2 KB SRAM) and A Link to the Past (LoROM, 8 KB
SRAM) do with their save RAM, at the real cartridge addresses. Its 65816 code
(emulation mode, 8-bit registers, long addressing):

  1. looks for a signature ($5A $A5) at the start of the SRAM;
  2. none (first boot): writes the signature, a pattern over the rest of the
     SRAM, a $11 marker at SRAM+$400, and a mirror write one SRAM size past the
     start (SRAM+size+$10), which lands on SRAM+$10;
     signature found (a restored save): writes only a $77 marker at SRAM+$400;
  3. loops forever, reading SRAM+0 each time round (a game that polls its
     save: reads the dump must not disturb), writing $EE at SRAM+$3F0 if it
     ever reads anything but the signature.

LoROM puts the SRAM at $70:0000, HiROM at $30:6000 (banks $30-$3F mirror it).

usage: mkrom.py <lorom|hirom> <sram_kb> <out.hex> [out.sfc]
The hex file is what iosys streams to the core: the 64-byte header, then the
whole ROM, one byte per line.
"""
import sys


class Asm:
    def __init__(self, org):
        self.org = org
        self.code = bytearray()
        self.labels = {}
        self.fix = []

    def pc(self):
        return self.org + len(self.code)

    def label(self, name):
        self.labels[name] = self.pc()

    def b(self, *bytes_):
        self.code.extend(bytes_)

    def long(self, op, addr):
        self.b(op, addr & 0xFF, (addr >> 8) & 0xFF, (addr >> 16) & 0xFF)

    def branch(self, op, name):
        self.b(op, 0)
        self.fix.append((len(self.code) - 1, name, 'rel'))

    def jmp(self, name):
        self.b(0x4C, 0, 0)
        self.fix.append((len(self.code) - 2, name, 'abs'))

    def done(self):
        for at, name, kind in self.fix:
            tgt = self.labels[name]
            if kind == 'rel':
                off = tgt - (self.org + at + 1)
                assert -128 <= off <= 127, (name, off)
                self.code[at] = off & 0xFF
            else:
                self.code[at] = tgt & 0xFF
                self.code[at + 1] = (tgt >> 8) & 0xFF
        return bytes(self.code)


def program(org, sram_base, size):
    a = Asm(org)
    a.label('reset')
    a.b(0x78)                       # SEI
    a.b(0xA2, 0xFF)                 # LDX #$FF
    a.b(0x9A)                       # TXS
    a.long(0xAF, sram_base)         # LDA long sram+0
    a.b(0xC9, 0x5A)                 # CMP #$5A
    a.branch(0xD0, 'init')          # BNE init
    a.long(0xAF, sram_base + 1)
    a.b(0xC9, 0xA5)
    a.branch(0xD0, 'init')
    a.b(0xA9, 0x77)                 # found: LDA #$77
    a.long(0x8F, sram_base + 0x400) # STA long sram+$400
    a.jmp('idle')
    a.label('init')
    a.b(0xA9, 0x5A)
    a.long(0x8F, sram_base)
    a.b(0xA9, 0xA5)
    a.long(0x8F, sram_base + 1)
    for page in range(size // 256):
        a.b(0xA2, 0x02 if page == 0 else 0x00)      # LDX #start
        a.label('p%d' % page)
        a.b(0x8A)                                   # TXA
        a.b(0x49, (0x3C ^ page) & 0xFF)             # EOR #(0x3C ^ page)
        a.long(0x9F, sram_base + page * 256)        # STA long sram+page*256,X
        a.b(0xE8)                                   # INX
        a.branch(0xD0, 'p%d' % page)                # BNE (X wraps at 256)
    a.b(0xA9, 0x11)
    a.long(0x8F, sram_base + 0x400)
    a.b(0xA9, 0x99)                                 # mirror: one SRAM size past the start
    mirror = sram_base + size + 0x10
    if sram_base == 0x306000:                       # HiROM: the next bank's window
        mirror = 0x316000 + 0x10 + (size - 0x2000 if size > 0x2000 else 0)
    a.long(0x8F, mirror)
    a.label('idle')
    a.long(0xAF, sram_base)                         # LDA long sram+0
    a.b(0xC9, 0x5A)
    a.branch(0xF0, 'idle')                          # BEQ idle (signature intact)
    a.b(0xA9, 0xEE)
    a.long(0x8F, sram_base + 0x3F0)                 # error flag
    a.jmp('idle')
    return a.done()


def build(kind, sram_kb):
    size = sram_kb * 1024
    rom = bytearray(b'\xFF' * 0x10000)              # 64 KB
    if kind == 'lorom':
        org, hdr_at, base, mapctl = 0x8000, 0x7FC0, 0x700000, 0x20
        code_at = 0x0000
        vec_at = 0x7FFC
    else:
        org, hdr_at, base, mapctl = 0x8000, 0xFFC0, 0x306000, 0x21
        code_at = 0x8000
        vec_at = 0xFFFC
    code = program(org, base, size)
    rom[code_at:code_at + len(code)] = code
    hdr = bytearray(64)
    hdr[0:21] = b'SRAM PATTERN TEST'.ljust(21, b' ')
    hdr[0x15] = mapctl
    hdr[0x16] = 0x02                                # ROM + RAM + battery
    hdr[0x17] = 6                                   # ROM size 64 KB (2^6 KB)
    hdr[0x18] = {2: 1, 8: 3, 32: 5}[sram_kb]        # SRAM size byte: 2^n KB
    hdr[0x19] = 0x01
    hdr[0x1A] = 0x33
    hdr[0x1C:0x1E] = b'\x00\x00'                    # checksum
    hdr[0x1E:0x20] = b'\xFF\xFF'                    # complement
    rom[hdr_at:hdr_at + 64] = hdr
    # vectors: native (0x7FE4..) and emulation (0x7FF4..) tables, all -> $8000
    base_vec = hdr_at + 0x20
    for off in range(0, 0x20, 2):
        rom[base_vec + off:base_vec + off + 2] = b'\x00\x80'
    rom[vec_at:vec_at + 2] = b'\x00\x80'            # RESET
    return bytes(rom[hdr_at:hdr_at + 64]), bytes(rom)


if __name__ == '__main__':
    kind, kb = sys.argv[1], int(sys.argv[2])
    hdr, rom = build(kind, kb)
    with open(sys.argv[3], 'w') as f:
        for b in hdr + rom:
            f.write('%02x\n' % b)
    if len(sys.argv) > 4:
        with open(sys.argv[4], 'wb') as f:
            f.write(rom)
    print('%d bytes' % (len(hdr) + len(rom)))
