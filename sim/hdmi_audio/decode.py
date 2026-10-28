#!/usr/bin/env python3
"""Decode data islands from parallel TMDS symbols, without internal mode tags."""
import argparse
from array import array
from collections import Counter
import json
from pathlib import Path
import sys

TERC4 = [0b1010011100, 0b1001100011, 0b1011100100, 0b1011100010,
         0b0101110001, 0b0100011110, 0b0110001110, 0b0100111100,
         0b1011001100, 0b0100111001, 0b0110011100, 0b1011000110,
         0b1010001110, 0b1001110001, 0b0101100011, 0b1011000011]
DECODE = {v: k for k, v in enumerate(TERC4)}
PREAMBLE = 0b0010101011
GUARD = 0b0100110011


def ecc(value, bits):
    crc = 0
    for i in range(bits):
        crc = (crc >> 1) ^ (0x83 if ((crc ^ (value >> i)) & 1) else 0)
    return crc


def decode(path, rate, tone, historical):
    words = array('I')
    with path.open('rb') as f:
        words.fromfile(f, path.stat().st_size // 4)
    if sys.byteorder != 'little':
        words.byteswap()
    counts, errors = Counter(), Counter()
    cts, info, channels, values = [], {}, [], []
    island_lengths = Counter()
    previous = None
    discontinuities = Counter()
    steady_discontinuities = Counter()
    warmup = 4*855*525 if 'hz120' in path.name else 2*1647*750
    pre = guards = 0
    island = []
    in_island = False
    status = [[], []]
    b_seen = False

    def packet(data, cycle):
        nonlocal previous, status, b_seen
        header = sum(((d[0] >> 2) & 1) << i for i, d in enumerate(data))
        subs = [sum((((d[1] >> k) & 1) | (((d[2] >> k) & 1) << 1)) << (2*i)
                    for i, d in enumerate(data)) for k in range(4)]
        kind = header & 255
        counts[f'{kind:02x}'] += 1
        if ecc(header & 0xffffff, 24) != (header >> 24):
            errors['header_bch'] += 1
        for sub in subs:
            if ecc(sub & ((1 << 56)-1), 56) != (sub >> 56):
                errors['sub_bch'] += 1
        hb = [(header >> (8*i)) & 255 for i in range(3)]
        pb = [(s >> (8*i)) & 255 for s in subs for i in range(7)]
        if kind == 1:
            if len(set(s & ((1 << 56)-1) for s in subs)) != 1:
                errors['acr_copies'] += 1
            stamp = (pb[1] << 16) | (pb[2] << 8) | pb[3]
            n = (pb[4] << 16) | (pb[5] << 8) | pb[6]
            cts.append((cycle, n, stamp))
        elif kind & 0x80:
            if sum(hb + pb[:hb[2]+1]) & 255:
                errors['info_checksum'] += 1
            info.setdefault(f'{kind:02x}', set()).add(bytes(hb + pb[:hb[2]+1]).hex())
        elif kind == 2:
            if hb[1] != 0x0f or (hb[2] & 15):
                errors['sample_present_layout_flat'] += 1
            for k, sub in enumerate(subs):
                sub &= (1 << 56)-1
                lr = [sub & 0xffffff, (sub >> 24) & 0xffffff]
                flags = sub >> 48
                if flags & 0x33:
                    errors['sample_validity_user'] += 1
                for ch in range(2):
                    if (lr[ch].bit_count() + ((flags >> (4*ch)) & 15).bit_count()) & 1:
                        errors['sample_parity'] += 1
                b = bool(hb[2] & (1 << (4+k)))
                if b:
                    if b_seen and len(status[0]) != 192:
                        errors['iec_block_length'] += 1
                    if len(status[0]) == 192:
                        channels.append([sum(v << i for i, v in enumerate(x)) for x in status])
                    status = [[], []]
                    b_seen = True
                if b_seen:
                    for ch in range(2):
                        status[ch].append((flags >> (4*ch+2)) & 1)
                l, r = lr[0] >> 8, lr[1] >> 8
                if l:
                    if tone and (r != l or l not in (0x1000, 0xf000)):
                        errors['tone_payload'] += 1
                    elif not tone and r != ((~l) & 65535):
                        errors['stereo_payload'] += 1
                    if previous is not None and l != ((previous+1) & 65535):
                        discontinuities['repeat' if l == previous else 'jump'] += 1
                        if cycle >= warmup and not tone:
                            steady_discontinuities['repeat' if l == previous else 'jump'] += 1
                    previous = l
                    values.append(l)

    for cycle, word in enumerate(words):
        c0, c1, c2 = word & 1023, (word >> 10) & 1023, (word >> 20) & 1023
        if in_island:
            if c1 == GUARD and c2 == GUARD:
                counts['islands'] += 1
                island_lengths[len(island)] += 1
                if len(island) % 32:
                    errors['island_length'] += 1
                for i in range(0, len(island)-31, 32):
                    packet(island[i:i+32], cycle-len(island)+i)
                in_island = False
                island = []
                pre = guards = 0
            else:
                try:
                    island.append((DECODE[c0], DECODE[c1], DECODE[c2]))
                except KeyError:
                    errors['terc4'] += 1
                    in_island = False
                    island = []
            continue
        if c1 == PREAMBLE and c2 == PREAMBLE:
            pre += 1
            guards = 0
        elif pre >= 8 and c1 == GUARD and c2 == GUARD:
            guards += 1
            if guards == 2:
                in_island = True
        else:
            pre = guards = 0
    stamps = [x[2] for x in cts[1:] if x[2]]
    expected_n = rate * 128 // 1000
    expected_status = [(0x203 if rate == 32000 else 0x202) << 24 | ch << 16 | 4
                       for ch in (0x10, 0x20)]
    if set(x[1] for x in cts) != {expected_n}:
        errors['acr_n'] += 1
    if len(cts) < 20 or not stamps or min(stamps) < 53900 or max(stamps) > 74400:
        errors['acr_coverage_range'] += 1
    if len(values) < 1000 or len(channels) < 5:
        errors['audio_coverage'] += 1
    if any(x != expected_status for x in channels):
        errors['iec_channel_status'] += 1
    if info.get('84') != {'84010a7001000000000000000000'}:
        errors['audio_infoframe'] += 1
    if steady_discontinuities and not historical:
        errors['steady_sample_continuity'] += 1
    result = dict(stream=str(path), pixel_clocks=len(words), counts=dict(counts),
                  errors=dict(errors), acr_n=sorted(set(x[1] for x in cts)),
                  cts_min=min(stamps, default=0), cts_max=max(stamps, default=0),
                  cts_values=sorted(set(stamps)),
                  info={k: sorted(v) for k, v in info.items()},
                  iec_blocks=len(channels),
                  island_lengths=dict(island_lengths),
                  iec_status=sorted(set(tuple(f'{v:048x}' for v in x) for x in channels)),
                  nonzero_samples=len(values), first_samples=values[:12],
                  last_samples=values[-12:], discontinuities=dict(discontinuities),
                  steady_discontinuities=dict(steady_discontinuities))
    print(json.dumps(result, indent=2))
    return bool(errors)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('stream', type=Path)
    parser.add_argument('--rate', type=int, choices=(32000, 48000), default=32000)
    parser.add_argument('--tone', action='store_true')
    parser.add_argument('--historical', action='store_true',
                        help='report historical transport repeats without requiring continuity')
    args = parser.parse_args()
    sys.exit(decode(args.stream, args.rate, args.tone, args.historical))
