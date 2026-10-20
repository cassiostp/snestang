# GSU multiplication

Run inside `verilator/verilator` with `sh run.sh`. The bench checks the actual
GSU combinational ALU, including result, sign, zero and long-multiply carry.
It exhausts every 8-bit operand pair for signed MULT and unsigned UMULT, then
checks signed FMULT/LMULT boundaries and 4096 deterministic operand pairs each.

MULT uses signed 8-bit operands; UMULT uses unsigned 8-bit operands.
FMULT and LMULT both use signed 16-bit operands; LMULT also retains the low word.
This agrees with bsnes `processor/gsu/instructions.cpp`,
`instructionMULT_UMULT` and `instructionFMULT_LMULT`.
