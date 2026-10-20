; hires_test.asm - SNES hi-res homebrew for tangcore#23.
; LoROM 32KB. Shows a mode-5 screen (BGMODE 5, stripes + HIRES MODE5 text)
; 120 frames, then pseudo-hi-res (BGMODE 1 + SETINI bit3, same tiles, sub =
; backdrop) 120 frames, loops. Palette: CGRAM[0] blue, CGRAM[1] red, so the
; stripe tile (alternating 0/1 pixels) is single-pixel blue/red columns.
; The NMI handler counts frames and flips BGMODE/SETINI/TM/TS at 120/240.
;
; Assembled by build.py (subset: SEI CLC XCE SEP LDX LDY LDA STA STZ INC CMP
; BNE BEQ BRA JSR RTS RTI WAI PHA PHP PLA PLP TXS DEX DEY + LDA abs,X).
; Code runs at $8000. VRAM map at word $0000, tiles at word $1000.

Reset:
  sei
  clc
  xce
  sep #$30
  ldx #$FF
  txs
  lda #$00
  pha
  plb
  stz $4200
  stz $420B
  stz $420C
  lda #$8F
  sta $2100

  ; VMAIN: increment after high, step 1
  lda #$80
  sta $2115

  ; clear VRAM map 1024 words at $0000 to tile 0 (blank)
  lda #$00
  sta $2116
  sta $2117
  ldy #$04
ClearMap:
  ldx #$00
ClearMapInner:
  stz $2118
  stz $2119
  dex
  bne ClearMapInner
  dey
  bne ClearMap

  ; write row 0: 32x stripe tile 1 (entries $2001)
  lda #$00
  sta $2116
  sta $2117
  ldx #$20
Row0:
  lda #$01
  sta $2118
  lda #$20
  sta $2119
  dex
  bne Row0

  ; write row 1 text from table TextRow (32 entries, low/high)
  ; VMADDR = $0020 (row 1: 32 words in)
  lda #$20
  sta $2116
  lda #$00
  sta $2117
  ldx #$00
Row1:
  lda TextRow,X
  sta $2118
  inx
  lda TextRow,X
  sta $2119
  inx
  cpx #$40
  bne Row1

  ; tiles 11x32 bytes at word $1000 from table Tiles
  lda #$00
  sta $2116
  lda #$10
  sta $2117
  ldx #$00
TilesLo:
  lda Tiles,X
  sta $2118
  inx
  lda Tiles,X
  sta $2119
  inx
  cpx #$00
  bne TilesLo
  ; X wrapped: 256 bytes done (128 words), do the rest (352-256=96 bytes = 48 words)
  ldy #$00
TilesHi:
  lda Tiles+256,Y
  sta $2118
  iny
  lda Tiles+256,Y
  sta $2119
  iny
  cpy #$60
  bne TilesHi

  ; CGRAM: [0] blue, [1] red
  stz $2121
  lda #$00
  sta $2122
  lda #$7C
  sta $2122
  lda #$1F
  sta $2122
  lda #$00
  sta $2122

  ; mode 5 regs
  lda #$05
  sta $2105
  stz $2107
  lda #$01
  sta $210B
  lda #$01
  sta $212C
  sta $212D
  stz $2133
  stz $212E
  stz $212F
  stz $2130
  stz $2131

  ; frame counter + NMI
  stz $0000
  lda #$81
  sta $4200
  lda #$0F
  sta $2100

Loop:
  wai
  bra Loop

NMI:
  pha
  php
  lda $4210
  inc $0000
  lda $0000
  cmp #$78
  bne NMI240
  ; 120: pseudo-hi-res (mode 1 + SETINI bit3, sub = backdrop)
  lda #$01
  sta $2105
  lda #$08
  sta $2133
  lda #$01
  sta $212C
  stz $212D
  bra NMIDone
NMI240:
  cmp #$F0
  bne NMIDone
  ; 240: back to mode 5
  lda #$05
  sta $2105
  stz $2133
  lda #$01
  sta $212C
  sta $212D
NMIDone:
  plp
  pla
  rti

; Tables (build.py appends bytes; labels mark ROM offsets):
TextRow:
  ; 32 entries x 2 bytes: "HIRES MODE5" then blanks (tile 0, prio $20)
  ; H=2 I=3 R=4 E=5 S=6 space=0 M=7 O=8 D=9 E=5 5=10
Tiles:
  ; 11 tiles x 32 bytes (4bpp, planes 2/3 zero)
