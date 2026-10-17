#!/usr/bin/env python3
# Builds the test ROM for tb_sa1.vhd: a 2 MB image with a small hand-
# assembled SA-1 program at offset 0 (SA-1/SNES $00:8000 with the reset
# Super MMC defaults), a known 16-byte pattern at offset $200 (DMA/VBP
# source; clear of the 321-byte program), and a marker byte at offset
# $100000 (seen from S-CPU $00:8000 when CXB=1, CBMAP=1: CXB is the 1 MB
# bank, ROM bits 22..20). Output: sa1test.hex, one hex byte per line.
import sys

rom = bytearray(2 << 20)

code = []
def emit(*bs): code.extend(bs)
def lda_i(v):  emit(0xA9, v)
def sta_a(a):  emit(0x8D, a & 0xFF, (a >> 8) & 0xFF)          # STA $xxxx (bank 0)
def lda_a(a):  emit(0xAD, a & 0xFF, (a >> 8) & 0xFF)          # LDA $xxxx
def sta_l(a):  emit(0x8F, a & 0xFF, (a >> 8) & 0xFF, (a >> 16) & 0xFF)  # STA $xxxxxx
def lda_l(a):  emit(0xAF, a & 0xFF, (a >> 8) & 0xFF, (a >> 16) & 0xFF)  # LDA $xxxxxx
def nops(n):   emit(*([0xEA] * n))

BW = 0x400000  # BW-RAM in SA-1 space

# CIWP=$FF (I-RAM writable), CBWE=$80 (BW-RAM writable). No stack use
# before CIWP: only immediate loads and absolute stores until here.
lda_i(0xFF); sta_a(0x222A)
lda_i(0x80); sta_a(0x2227)

# multiply: MA=-3, MB=7 -> MR = -21 = $FFFFFFEB at BW+$00..03
lda_i(0x00); sta_a(0x2250)          # MCNT: multiply
lda_i(0xFD); sta_a(0x2251)
lda_i(0xFF); sta_a(0x2252)
lda_i(0x07); sta_a(0x2253)
lda_i(0x00); sta_a(0x2254)          # trigger
nops(8)
for i in range(4):
    lda_a(0x2306 + i); sta_l(BW + i)

# divide: MA=1000, MB=7 -> Q=142, R=6 -> MR bytes 8E 00 06 00 at BW+$04..07
lda_i(0x01); sta_a(0x2250)          # MCNT: divide
lda_i(0xE8); sta_a(0x2251)
lda_i(0x03); sta_a(0x2252)
lda_i(0x07); sta_a(0x2253)
lda_i(0x00); sta_a(0x2254)
nops(12)
for i in range(4):
    lda_a(0x2306 + i); sta_l(BW + 4 + i)

# VBP preload from $00:8200; VDP (first word) -> BW+$08..09
lda_i(0x00); sta_a(0x2259)
lda_i(0x82); sta_a(0x225A)
lda_i(0x00); sta_a(0x225B)          # trigger preload
nops(16)
lda_a(0x230C); sta_l(BW + 8)
lda_a(0x230D); sta_l(BW + 9)

# BW-RAM seed at BW+$100 (TB wrote $41): +1 -> BW+$101
lda_l(BW + 0x100)
emit(0x18)                          # CLC
emit(0x69, 0x01)                    # ADC #$01
sta_l(BW + 0x101)

# I-RAM pattern $0010..13 = DE AD BE EF
for i, b in enumerate([0xDE, 0xAD, 0xBE, 0xEF]):
    lda_i(b); sta_a(0x0010 + i)

# normal DMA ROM $00:8200 -> I-RAM $0200, 16 bytes
lda_i(0x80); sta_a(0x2230)          # DCNT: DMAEN, src ROM, dst I-RAM
lda_i(0x10); sta_a(0x2238)          # DTC lo
lda_i(0x00); sta_a(0x2239)          # DTC hi
lda_i(0x00); sta_a(0x2232)          # SDA lo
lda_i(0x82); sta_a(0x2233)          # SDA mid
lda_i(0x00); sta_a(0x2234)          # SDA hi
lda_i(0x00); sta_a(0x2235)          # DDA lo
lda_i(0x02); sta_a(0x2236)          # DDA hi: triggers
# burn cycles executing from ROM while DMA runs
emit(0xA0, 0xFF)                    # LDY #$FF
loop = len(code)
emit(0x88)                          # DEY
emit(0xD0, (loop - (len(code) + 2)) & 0xFF)  # BNE loop
# checksum I-RAM $0200..0F -> BW+$102
emit(0xA2, 0x00)                    # LDX #$00
lda_i(0x00); sta_a(0x0000)
sumloop = len(code)
emit(0xBD, 0x00, 0x02)              # LDA $0200,X
emit(0x18)                          # CLC
emit(0x6D, 0x00, 0x00)              # ADC $0000
sta_a(0x0000)
emit(0xE8)                          # INX
emit(0xE0, 0x10)                    # CPX #$10
emit(0xD0, (sumloop - (len(code) + 2)) & 0xFF)  # BNE sumloop
lda_a(0x0000); sta_l(BW + 0x102)
# copy first 4 DMA bytes -> BW+$104..07
for i in range(4):
    lda_a(0x0200 + i); sta_l(BW + 0x104 + i)

# done: CMSG=$A + SNES IRQ flag, then spin
lda_i(0x8A); sta_a(0x2209)          # SCNT
emit(0x80, 0xFE)                    # BRA self

rom[0:len(code)] = bytes(code)
assert len(code) < 0x200, "program must stay clear of the $200 pattern"
for i in range(16):
    rom[0x200 + i] = (0xA0 + i * 7) & 0xFF
rom[0x100000] = 0x5C

with open(sys.argv[1], "w") as f:
    for b in rom:
        f.write(f"{b:02X}\n")
print(f"code {len(code)} bytes; pattern checksum {sum(rom[0x200:0x210]) & 0xFF:02X}")
