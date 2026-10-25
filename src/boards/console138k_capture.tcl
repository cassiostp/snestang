# Keep the ordinary build's pin map and placement exactly when states are off.
proc snes_capture_cst {board_config variant} {
    set f [open $board_config r]
    set config [read $f]
    close $f
    set base "src/boards/console138k_sdram.cst"
    if {![regexp -line {^[ \t]*`define[ \t]+SNES_SAVESTATE([ \t]|$)} $config]} {
        return $base
    }
    set f [open $base r]
    set constraints [read $f]
    close $f
    # Shorten the DQ-to-capture routes without changing any sampling edge.
    set constraints [string map [list {C[172:181]} {C[178:181]}] $constraints]
    if {$variant eq "hz120"} {
        set constraints [string map [list {R[25:45]C[105:140]} {R[25:45]C[125:150]}] $constraints]
        # Exact LUT lookups avoid the deep-hierarchy GROUP matcher. Keep the
        # BSRAM byte-zero read mux from zigzagging across the device.
        append constraints {
INS_LOC "main/SNES/CPU/P65_DI_0_s71" R58C[128:132];
INS_LOC "main/SNES/CPU/P65_DI_0_s43" R58C[120:124];
INS_LOC "main/SNES/CPU/P65_DI_0_s20" R58C[116:119];
INS_LOC "main/SNES/CPU/P65_DI_0_s11" R71C[100:104];
INS_LOC "main/SNES/CPU/P65_DI_0_s2" R71C[96:99];
}
    }
    file mkdir impl
    set path "impl/console138k_capture.cst"
    set f [open $path w]
    puts -nonewline $f $constraints
    close $f
    return $path
}
