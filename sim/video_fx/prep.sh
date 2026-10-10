#!/bin/sh
# Host-side preparation for run.sh: needs python3 and git.
#   vec_*.hex           test vectors from the golden model (model.py gen)
#   build/*_base.*      the scaler before video_fx, from git history ($BASE), with the module
#                       names suffixed _base so that both can be in one simulation
set -e
cd "$(dirname "$0")"
BASE=${BASE:-0669902}       # the last commit without video_fx
python3 -I model.py selfcheck
python3 -I model.py gen
mkdir -p build
git show $BASE:src/snes2hdmi.v | sed \
    -e 's/^module snes2hdmi (/module snes2hdmi_base (/' \
    -e 's/^\( *\)sl_rows sl (/\1sl_rows_base sl (/' \
    -e 's/^\( *\)sl_dim dim (/\1sl_dim_base dim (/' > build/snes2hdmi_base.v
git show $BASE:src/scanlines.v | sed \
    -e 's/^module sl_rows (/module sl_rows_base (/' \
    -e 's/^module sl_dim (/module sl_dim_base (/' > build/scanlines_base.v
grep -q '^module snes2hdmi_base (' build/snes2hdmi_base.v
grep -q '^ *sl_rows_base sl (' build/snes2hdmi_base.v
grep -q '^ *sl_dim_base dim (' build/snes2hdmi_base.v
grep -q '^module sl_rows_base (' build/scanlines_base.v
grep -q '^module sl_dim_base (' build/scanlines_base.v
echo "prep: vectors and baseline from $BASE ready"
