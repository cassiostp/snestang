proc snes_state_enabled {} {
    if {$::dev ne "console138k"} { return 0 }
    set f [open src/boards/console138k.v r]
    set config [read $f]
    close $f
    return [regexp -line {^[ \t]*`define[ \t]+SNES_SAVESTATE([ \t]|$)} $config]
}

proc snes_state_report_sdc {base} {
    if {![snes_state_enabled]} { return $base }
    set f [open $base r]
    set constraints [read $f]
    close $f
    append constraints {

# Keep the global minimum and enumerate every SDRAM DQ input for comparison.
report_timing -setup -max_paths 25 -max_common_paths 1
report_timing -setup -from [get_ports {IO_sdram_dq*}] -max_paths 100 -max_common_paths 20
}
    file mkdir impl
    set path "impl/console138k_ss_report.sdc"
    set f [open $path w]
    puts -nonewline $f $constraints
    close $f
    return $path
}
