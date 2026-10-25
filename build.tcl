if {$argc == 0} {
    puts "Usage: $argv0 <device> [<controller>]"
    puts "          device: nano20k, primer25k, mega60k, mega138k, console60k"
    puts "      controller: snes, ds2"
    puts "Note: nano20k supports both controllers simultaneously, so build with just: gw_sh build.tcl nano20k"
    exit 1
}

set dev [lindex $argv 0]
if {$argc >= 2} {
    set controller [lindex $argv 1]
} else {
    set controller ""
}

# TangCore build variant: standard (720p60), or hz120 (480p120) on
# console138k. CI passes it as TANGCORE_VARIANT; unset or empty is the
# standard build. The RTL reads it through src/variant/<variant>/variant.vh
# (set_option -include_path below).
if {[info exists ::env(TANGCORE_VARIANT)] && $::env(TANGCORE_VARIANT) ne ""} {
    set variant $::env(TANGCORE_VARIANT)
} else {
    set variant "standard"
}
if {$variant ne "standard" && $variant ne "hz120"} {
    error "Unknown TANGCORE_VARIANT $variant (want standard or hz120)"
}
puts "TangCore variant: $variant"

# process $dev and $controller
if {$dev eq "nano20k"} {
    set_device GW2AR-LV18QN88C8/I7 -device_version C
    add_file src/boards/nano20k.v
    add_file -type verilog "src/snes2hdmi_nano.v"
    add_file -type cst "src/boards/nano20k.cst"
    add_file -type verilog "src/pllr/gowin_pll_hdmi.v"
    add_file -type verilog "src/pllr/gowin_pll_snes.v"
    add_file -type verilog "src/sdram_nano.v"
    # nano20k supports both controllers simultaneously
    set_option -output_base_name snestang_${dev}
} elseif {$dev eq "primer25k"} {
    set_device GW5A-LV25MG121NC1/I0 -device_version A
    if {$controller eq "snes"} {
        add_file src/boards/primer25k_snescontroller.v
        add_file -type cst "src/boards/primer25k_snescontroller.cst"
    } elseif {$controller eq "ds2"} {
        add_file src/boards/primer25k.v
        add_file -type cst "src/boards/primer25k.cst"
    } else {
        error "Unknown controller $controller"
    }
    add_file -type verilog "src/snes2hdmi.v"
    add_file -type verilog "src/scanlines.v"
    add_file -type verilog "src/video_fx.v"
    add_file -type verilog "src/plla/gowin_pll_27.v"
    add_file -type verilog "src/plla/gowin_pll_hdmi.v"
    add_file -type verilog "src/plla/gowin_pll_snes.v"
    add_file -type verilog "src/sdram_cl2_3ch.v"
    add_file -type verilog "src/usb_hid_host.v"
    add_file -type verilog "src/plla/pll_12.v"
    set_option -output_base_name snestang_${dev}_${controller}
} elseif {$dev eq "mega60k"} {
    set_device GW5AT-LV60PG484AC1/I0 -device_version B
    if {$controller eq "snes"} {
        add_file src/boards/mega60k_snescontroller.v
        add_file -type cst "src/boards/mega60k_snescontroller.cst"
    } elseif {$controller eq "ds2"} {
        add_file src/boards/mega60k.v
        add_file -type cst "src/boards/mega60k.cst"
    } else {
        error "Unknown controller $controller"
    }
    add_file -type verilog "src/snes2hdmi.v"
    add_file -type verilog "src/scanlines.v"
    add_file -type verilog "src/video_fx.v"
    add_file -type verilog "src/plla/gowin_pll_27.v"
    add_file -type verilog "src/plla/gowin_pll_hdmi.v"
    add_file -type verilog "src/plla/gowin_pll_snes.v"
    add_file -type verilog "src/sdram_cl2_3ch.v"
    set_option -output_base_name snestang_${dev}_${controller}
} elseif {$dev eq "mega138k"} {
    set_device GW5AST-LV138FPG676AES -device_version B
    if {$controller eq "snes"} {
        add_file src/boards/mega138k_snescontroller.v
        add_file -type cst "src/boards/mega138k_snescontroller.cst"
    } elseif {$controller eq "ds2"} {
        add_file src/boards/mega138k.v
        add_file -type cst "src/boards/mega138k.cst"
    } else {
        error "Unknown controller $controller"
    }
    add_file -type verilog "src/snes2hdmi.v"
    add_file -type verilog "src/scanlines.v"
    add_file -type verilog "src/video_fx.v"
    add_file -type verilog "src/pll/gowin_pll_27.v"
    add_file -type verilog "src/pll/gowin_pll_hdmi.v"
    add_file -type verilog "src/pll/gowin_pll_snes.v"
    add_file -type verilog "src/sdram_cl2_2ch.v"
    add_file -type verilog "src/vram.v"
    add_file -type verilog "src/vram_spb.v"
    set_option -output_base_name snestang_${dev}_${controller}
} elseif {$dev eq "console60k"} {
    set_device GW5AT-LV60PG484AC1/I0 -device_version B
    # CI passes no controller; the Tang Console's own board is the ds2 one
    if {$controller eq ""} {
        set controller "ds2"
    }
    if {$controller eq "snes"} {
        add_file src/boards/console60k_snescontroller.v
        add_file -type cst "src/boards/console60k_snescontroller.cst"
    } elseif {$controller eq "ds2"} {
        add_file src/boards/console60k.v
        add_file -type cst "src/boards/console.cst"
    } else {
        error "Unknown controller $controller"
    }
    add_file -type verilog "src/snes2hdmi.v"
    add_file -type verilog "src/scanlines.v"
    add_file -type verilog "src/video_fx.v"
    add_file -type verilog "src/plla/gowin_pll_27.v"
    add_file -type verilog "src/plla/gowin_pll_hdmi.v"
    add_file -type verilog "src/plla/gowin_pll_snes.v"
    add_file -type verilog "src/sdram_cl2_3ch.v"
    add_file -type verilog "src/usb_hid_host.v"
    add_file -type verilog "src/plla/pll_12.v"
    set_option -output_base_name snestang_${dev}_${controller}
} elseif {$dev eq "console138k"} {
    set_device GW5AST-LV138PG484AC1/I0 -device_version B
    # CX4 (Mega Man X2/X3): srg320's VHDL from SNES_MiSTer, with a few framework shims
    add_file -type vhdl "src/chip/CX4/CEGen.vhd"
    add_file -type vhdl "src/chip/CX4/cx4_drom_pkg.vhd"
    add_file -type vhdl "src/chip/CX4/spram.vhd"
    add_file -type vhdl "src/chip/CX4/dpram_difclk.vhd"
    add_file -type vhdl "src/chip/CX4/cx4cache.vhd"
    add_file -type vhdl "src/chip/CX4/CX4.vhd"
    add_file -type vhdl "src/chip/CX4/CX4Map.vhd"
    set_option -vhdl_std vhd2008
    add_file src/boards/console138k.v
    add_file -type cst "src/boards/console138k_sdram.cst"
    add_file -type verilog "src/snes2hdmi.v"
    add_file -type verilog "src/scanlines.v"
    add_file -type verilog "src/video_fx.v"
    add_file -type verilog "src/pll/gowin_pll_27.v"
    add_file -type verilog "src/pll/gowin_pll_hdmi.v"
    add_file -type verilog "src/pll/gowin_pll_snes.v"
    add_file -type verilog "src/sdram_cl2_2ch.v"
    add_file -type verilog "src/vram.v"
    add_file -type verilog "src/vram_spb.v"
    add_file -type verilog "src/usb_hid_host.v"
    add_file -type verilog "src/pll/pll_12.v"
    add_file -type verilog "src/chip/GSU/GSU_PKG.v"
    add_file -type verilog "src/chip/GSU/GSU.v"
    add_file -type verilog "src/chip/GSU/GSUMap.v"
    add_file -type vhdl "src/chip/SA1/P65816_pkg.vhd"
    add_file -type vhdl "src/chip/SA1/BCDAdder.vhd"
    add_file -type vhdl "src/chip/SA1/AddSubBCD.vhd"
    add_file -type vhdl "src/chip/SA1/ALU.vhd"
    add_file -type vhdl "src/chip/SA1/AddrGen.vhd"
    add_file -type vhdl "src/chip/SA1/MCode.vhd"
    add_file -type vhdl "src/chip/SA1/P65C816.vhd"
    add_file -type vhdl "src/chip/SA1/spram.vhd"
    add_file -type vhdl "src/chip/SA1/SA1MULT.vhd"
    add_file -type vhdl "src/chip/SA1/SA1DIV.vhd"
    add_file -type vhdl "src/chip/SA1/SA1.vhd"
    add_file -type vhdl "src/chip/SA1/SA1Map.vhd"
    add_file -type verilog "src/sa1_rom_cache.v"
    add_file -type verilog "src/bwram_256k.v"
    set_option -output_base_name snestang_${dev}_${controller}
} else {
    error "Unknown device $dev"
}
if {$variant eq "hz120" && $dev ne "console138k"} {
    error "TANGCORE_VARIANT hz120 needs console138k (got $dev)"
}

add_file -type verilog "src/iosys/iosys_bl616.v"
add_file -type verilog "src/iosys/uart_fractional.v"
add_file -type verilog "src/iosys/textdisp.v"
add_file -type verilog "src/iosys/uart_fixed.v"
add_file -type verilog "src/iosys/crc16.v"

add_file -type verilog "src/65C816/ALU.v"
add_file -type verilog "src/65C816/AddSubBCD.v"
add_file -type verilog "src/65C816/AddrGen.v"
add_file -type verilog "src/65C816/BCDAdder.v"
add_file -type verilog "src/65C816/P65C816.v"
add_file -type verilog "src/65C816/adder4.v"
add_file -type verilog "src/65C816/bit_adder.v"
add_file -type verilog "src/65C816/common.sv"
add_file -type verilog "src/65C816/mcode.sv"
add_file -type verilog "src/CEGen.v"
add_file -type verilog "src/chip/DSP/DSP_LHRomMap.v"
add_file -type verilog "src/chip/DSP/DSPn.v"
add_file -type verilog "src/chip/DSP/OBC1.v"
add_file -type verilog "src/chip/DSP/SRTC.v"
add_file -type verilog "src/chip/DSP/srtc_time_pack.v"
add_file -type verilog "src/chip/DSP/dsp_data_ram.v"
add_file -type verilog "src/cpu.v"
add_file -type verilog "src/dsp.v"
add_file -type verilog "src/dual_clk_fifo.v"
add_file -type verilog "src/dualshock_controller.v"
add_file -type verilog "src/gowin_dpb_cgram.v"
add_file -type verilog "src/gowin_dpb_hoam.v"
add_file -type verilog "src/gowin_dpb_oam.v"
add_file -type verilog "src/hdmi2/audio_clock_regeneration_packet.sv"
add_file -type verilog "src/hdmi2/audio_info_frame.sv"
add_file -type verilog "src/hdmi2/audio_sample_packet.sv"
add_file -type verilog "src/hdmi2/auxiliary_video_information_info_frame.sv"
add_file -type verilog "src/hdmi2/hdmi.sv"
add_file -type verilog "src/hdmi2/packet_assembler.sv"
add_file -type verilog "src/hdmi2/packet_picker.sv"
add_file -type verilog "src/hdmi2/serializer.sv"
add_file -type verilog "src/hdmi2/source_product_description_info_frame.sv"
add_file -type verilog "src/hdmi2/tmds_channel.sv"
add_file -type verilog "src/iosys/gowin_dpb_menu.v"
add_file -type verilog "src/main.v"
add_file -type verilog "src/ppu.v"
add_file -type verilog "src/ppucgram.v"
add_file -type verilog "src/ppuhoam.v"
add_file -type verilog "src/ppuoam.v"
add_file -type verilog "src/smc_parser.v"
add_file -type verilog "src/smp.v"
add_file -type verilog "src/SNES.v"
add_file -type verilog "src/controller_adapter.sv"
add_file -type verilog "src/controller_ds2.sv"
add_file -type verilog "src/controller_snes.v"
add_file -type verilog "src/snestang_top.v"
if {$dev eq "console138k"} {
    add_file -type verilog "src/savestate.v"
}
add_file -type verilog "src/spc700/_spc700_package.v"
add_file -type verilog "src/spc700/addrgen.v"
add_file -type verilog "src/spc700/addsub.v"
add_file -type verilog "src/spc700/alu.v"
add_file -type verilog "src/spc700/bcdadj.v"
add_file -type verilog "src/spc700/mcode.v"
add_file -type verilog "src/spc700/muldiv.v"
add_file -type verilog "src/spc700/spc700.v"
add_file -type verilog "src/swram.v"
add_file -type verilog "src/uart_tx_V2.v"
# console138k/mega138k run the snes PLL at 3:1, the other boards at 4:1;
# Gowin reads only one SDC per project.
if {$dev eq "console138k" || $dev eq "mega138k"} {
if {$variant eq "hz120"} {
add_file -type sdc "src/boards/console138k_hz120.sdc"
} else {
add_file -type sdc "src/boards/console138k.sdc"
}
} else {
add_file -type sdc "src/snestang.sdc"
}
add_file -type gao -disable "src/mega138k/snestang.gao"

set_option -synthesis_tool gowinsynthesis
set_option -top_module snestang_top
set_option -verilog_std sysv2017
set_option -include_path src/variant/$variant
set_option -rw_check_on_ram 1
set_option -route_option 2
# hz120 place 3 leaves the SDRAM DQ capture short of the pin. Place 1 is the
# measured alternative (tangcore#66); standard stays on place 3.
if {$variant eq "hz120"} {
set_option -place_option 1
} else {
set_option -place_option 3
}
# GW5A-138 leaves I/O registers in the fabric unless asked (SUG100).
# mdtang, smstang and gbatang set these. Without them the SDRAM command
# flop sits ~5 ns of route away from its pin and misses tCMS.
set_option -ireg_in_iob 1
set_option -oreg_in_iob 1
set_option -ioreg_in_iob 1
set_option -use_mspi_as_gpio 1
set_option -use_sspi_as_gpio 1
set_option -use_ready_as_gpio 1
set_option -use_done_as_gpio 1
set_option -use_i2c_as_gpio 1
set_option -use_cpu_as_gpio 1
set_option -multi_boot 1

run all
