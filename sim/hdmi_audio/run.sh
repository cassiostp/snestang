#!/bin/sh
set -eu
cd "$(dirname "$0")"
variant=${1:-standard}
ref=${2:-current}
if [ "$variant" = both ]; then
    sh ./run.sh standard "$ref"
    sh ./run.sh hz120 "$ref"
    exit
fi
if [ "${HDMI_AUDIO_IN_CONTAINER:-0}" != 1 ]; then
    root=$(CDPATH= cd ../.. && pwd)
    runner=${DOCKER_RUN:-$(command -v simrun >/dev/null 2>&1 && echo simrun || echo docker run --rm)}
    $runner --name "${SIM_PREFIX:-hdmiaudio$$}_$variant" \
        --user "$(id -u):$(id -g)" -e HDMI_AUDIO_IN_CONTAINER=1 \
        -v "$root:/w" -w /w/sim/hdmi_audio --entrypoint sh \
        verilator/verilator:latest run.sh "$variant" "$ref"
    rtl=../../src
    [ "$ref" = current ] || rtl="build/$ref/src"
    rate=$(sed -n 's/.*localparam AUDIO_OUT_RATE = \([0-9]*\);/\1/p' "$rtl/snes2hdmi.v")
    tone=
    if grep -q 'diagnostic_audio_word' "$rtl/snes2hdmi.v"; then tone=--tone; fi
    historical=
    if ! grep -q 'input std_timing' "$rtl/snes2hdmi.v"; then historical=--historical; fi
    python3 decode.py "build/$ref-$variant.bin" --rate "$rate" $tone $historical
    exit
fi
mkdir -p build
rtl=../../src
flags=
if [ "$ref" != current ]; then
    mkdir -p "build/$ref"
    git -C ../.. archive "$ref" src | tar -x -C "build/$ref"
    rtl="build/$ref/src"
    if ! grep -q 'input std_timing' "$rtl/snes2hdmi.v"; then
        # The historical blocking toggle races both pixel-domain edge detectors.
        # Match the falling-edge hardware intent explicitly, as f234c65 does.
        sed -i -e 's/clk_audio = ~clk_audio/clk_audio <= ~clk_audio/' \
            -e 's/!clk_audio/clk_audio/g' "$rtl/snes2hdmi.v"
        flags=-DLEGACY
    fi
fi
case "$variant" in
    standard) flags="$flags -I../../src/variant/standard" ;;
    hz120) flags="$flags -DHZ120" ;;
    *) exit 2 ;;
esac
extra=
[ ! -f "$rtl/smooth.v" ] || extra="$rtl/smooth.v"
name="$ref-$variant"
# Verilator 5.052 rejects the nested real/int constant casts. Substitute
# their evaluated values for these two 32 kHz modes; packet logic is intact.
case "$variant" in standard) ideal=74250; width=17 ;; hz120) ideal=54000; width=16 ;; esac
sed -e "s/^localparam bit \[19:0\] CYCLE_TIME_STAMP_COUNTER_IDEAL =.*/localparam bit [19:0] CYCLE_TIME_STAMP_COUNTER_IDEAL = $ideal;/" \
    -e "s/^localparam int CYCLE_TIME_STAMP_COUNTER_WIDTH =.*/localparam int CYCLE_TIME_STAMP_COUNTER_WIDTH = $width;/" \
    "$rtl/hdmi2/audio_clock_regeneration_packet.sv" > "build/$name-acr.sv"
hdmi_sources=
for f in "$rtl/hdmi2/"*.sv; do
    case "$f" in */audio_clock_regeneration_packet.sv) ;; *) hdmi_sources="$hdmi_sources $f" ;; esac
done
verilator --binary --timing -j 20 --top-module tb_hdmi_audio \
    -Mdir "build/$name" -Wno-fatal -DMODEL_TECH $flags \
    tb_hdmi_audio.sv "$rtl/snes2hdmi.v" "$rtl/scanlines.v" \
    "$rtl/video_fx.v" "$rtl/dual_clk_fifo.v" $hdmi_sources "build/$name-acr.sv" \
    $extra > "build/$name-compile.log" 2>&1
"build/$name/Vtb_hdmi_audio" "+stream=build/$name.bin"
