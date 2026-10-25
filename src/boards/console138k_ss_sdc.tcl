proc snes_ss_enabled {} {
    if {$::dev ne "console138k"} { return 0 }
    set f [open src/boards/console138k.v r]
    set config [read $f]
    close $f
    return [regexp -line {^[ \t]*`define[ \t]+SNES_SAVESTATE([ \t]|$)} $config]
}

proc snes_ss_sdc {base} {
    if {![snes_ss_enabled]} { return $base }
    set f [open $base r]
    set constraints [read $f]
    close $f
    append constraints {

# The read forecast is launched at cycle[2] / cycle[5], one fclk before
# its mclk-domain override-select register. Undo the general 3/2 rule:
# these four control registers must meet the ordinary 15.5 ns window.
# The selects themselves are mclk registers with ordinary mclk timing.
set_multicycle_path 1 -setup -start -from [get_regs {sdram/ss_capture_early*}] -to [get_clocks {mclk}]
set_multicycle_path 0 -hold -start -from [get_regs {sdram/ss_capture_early*}] -to [get_clocks {mclk}]

# Include the global list as well as focused reports, so full pin and
# game-data margins can be compared without losing the global minimum.
report_timing -setup -max_paths 25 -max_common_paths 1
report_timing -setup -from [get_ports {IO_sdram_dq*}] -max_paths 100 -max_common_paths 20
report_timing -setup -from [get_regs {sdram/bsram_dout_reg*}] -max_paths 100 -max_common_paths 50
report_timing -setup -from [get_clocks {mclk}] -to [get_clocks {mclk}] -max_paths 25 -max_common_paths 1
}
    file mkdir impl
    set path "impl/console138k_ss.sdc"
    set f [open $path w]
    puts -nonewline $f $constraints
    close $f
    return $path
}
